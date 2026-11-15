import 'dart:typed_data';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_dump.dart';
import 'package:chameleonultragui/gui/menu/pages/cpu_data_editor.dart';
import 'package:chameleonultragui/helpers/cpu_dump.dart';
import 'package:chameleonultragui/helpers/cpu_security.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/hf14a4_slot.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CpuFileSystem _protected() => CpuFileSystem([
  CpuFileNode(parent:255,type:0,fid:0x3F00),
  CpuFileNode(parent:0,type:1,fid:0x1001,access:39,data:[65,66,67,68]),
],security:CpuSecurity(pin:'000000',key:cpuHex('133457799BBCDFF1')));
void main() {
  test('CFS v2 shares the exact firmware security fixture and preserves remaining tries', () {
    final image=_protected().encode();
    expect(image.length,82);expect(image[4],2);expect(image[46],3);expect(image[47],3);
    expect(String.fromCharCodes(image.sublist(38,42)),'SEC1');
    image[46]=1;
    final decoded=CpuFileSystem.decode(image);
    expect(decoded.security!.pinRemaining,1);expect(decoded.nodes[1].access,39);
    expect(decoded.encode(),image);
    final json=decoded.toJson();expect(CpuFileSystem.fromJson(json).encode(),image);
    for(var i=0;i<image.length;i++) {
      expect(()=>CpuFileSystem.decode(Uint8List.fromList(image.take(i).toList())),throwsFormatException);
    }
  });
  test('security settings reject malformed credentials and permissions', () {
    expect(()=>CpuSecurity(pin:'abc').encode(),throwsFormatException);
    expect(()=>CpuSecurity(pin:'',key:[1]).encode(),throwsFormatException);
    expect(()=>CpuSecurity(pinTries:16).encode(),throwsFormatException);
    expect(()=>CpuFileSystem([CpuFileNode(parent:255,type:0,fid:0x3F00),
      CpuFileNode(parent:0,type:1,fid:0x1001,access:5)]).encode(),throwsFormatException);
    expect(()=>CpuFileSystem.fromJson({'nodes':_protected().toJson()['nodes'],'security':[]}),throwsFormatException);
  });
  test('old firmware rejects authentication before staging any data', () async {
    final calls=<Uint8List>[];
    await expectLater(writeCpuFilesystem(_protected().encode(),(data) async {
      calls.add(data);throw StateError('Unsupported opcode');
    }),throwsStateError);
    expect(calls,[Uint8List.fromList([7])]);
  });
  test('an archive-only card cannot silently upload as UID-only', () {
    final card=CardSave(uid:'01020304',name:'Archive',tag:TagType.hf14a4,
      extraData:CardSaveExtra(cpuApplication:'emv',cpuDump:{'archiveOnly':true,'universalComplete':false}));
    expect(()=>validateCpuCardForDevice(card),throwsStateError);
    final restored=CardSave.fromJson(card.toJson());
    expect(restored.extraData.cpuApplication,'emv');expect(restored.extraData.cpuDump['archiveOnly'],isTrue);
  });
  test('free files read without authentication and protected files authenticate only after 6982', () async {
    for(final protected in [false,true]) {
      var authenticated=false,requests=0,authCalls=0;
      final commands=<Uint8List>[];
      final reader=CpuDumpReader(exchange:(command) async {
        commands.add(command);
        if(command[1]==0xA4)return cpuHex('6207820101800200049000');
        expect(command[1],0xB0);requests++;
        if(protected && !authenticated)return cpuHex('6982');
        return cpuHex('414243449000');
      },authenticate:() async {authCalls++;authenticated=true;return true;});
      final result=await reader.read(parseCpuDumpPaths('1001'));
      expect(authCalls,protected?1:0);expect(requests,protected?2:1);
      expect(result.files.single.data,[65,66,67,68]);expect(result.completeForPlan,isTrue);
      expect(result.toJson()['universalComplete'],isFalse);
      expect(result.deviceFilesystem()!.nodes.last.access,protected?0:1);
      expect(commands.any((c)=>c.length>=4 && c[1]==0xCA && c[2]==0x9F && c[3]==0x17),isFalse);
    }
  });
  test('cancelled authentication never retries the protected read', () async {
    var reads=0;
    final reader=CpuDumpReader(exchange:(command) async {
      if(command[1]==0xA4)return cpuHex('6207820101800200049000');
      reads++;return cpuHex('6982');
    },authenticate:() async=>false);
    final result=await reader.read(parseCpuDumpPaths('1001'));
    expect(reads,1);expect(result.cancelled,isTrue);expect(result.files,isEmpty);
  });
  test('read limits produce partial archives rather than fake complete files', () async {
    final reader=CpuDumpReader(maxBytes:2,exchange:(command) async {
      if(command[1]==0xA4)return cpuHex('6207820101800200049000');
      return Uint8List.fromList([...List.generate(command.last,(i)=>65+i),0x90,0]);
    },authenticate:() async=>throw StateError('Unexpected auth'));
    final result=await reader.read(parseCpuDumpPaths('1001'));
    expect(result.files.single.data,[65,66]);expect(result.completeForPlan,isFalse);
    expect(result.deviceFilesystem(),isNull);
  });
  test('EMV AFL uses real SFI and record numbers and does not invent original FIDs', () async {
    final capture=[CpuApduPair(cpuHex('00A4040007A000000003101000'),cpuHex('9000')),
      CpuApduPair(cpuHex('80A8000002830000'),cpuHex('77069404080304009000'))];
    final targets=cpuEmvReadTargets(capture);
    expect(targets.single.sfi,1);expect(targets.single.firstRecord,3);expect(targets.single.lastRecord,4);
    final records=<int>[];
    final reader=CpuDumpReader(exchange:(command) async {
      if(command[1]==0xA4)return cpuHex('9000');
      expect(command[1],0xB2);expect(command[3],0x0C);records.add(command[2]);
      return cpuHex('010203049000');
    },authenticate:() async=>throw StateError('Unexpected auth'));
    final result=await reader.read(targets);
    expect(records,[3,4]);expect(result.files.single.toJson()['fileIdKnown'],isFalse);
    expect(result.deviceFilesystem(),isNull);
  });
  testWidgets('UID-only saving needs no connector, no authentication and no data editor', (tester) async {
    CardSave? result;
    await tester.pumpWidget(MaterialApp(locale:const Locale('en'),
      localizationsDelegates:AppLocalizations.localizationsDelegates,
      supportedLocales:AppLocalizations.supportedLocales,
      home:Scaffold(body:Builder(builder:(context)=>TextButton(onPressed:() async {
        result=await showCpuDumpDialog(context,CardData(uid:cpuHex('01020304'),
          sak:0x20,atqa:cpuHex('0400'),ats:cpuHex('0208')),name:'Identity only');
      },child:const Text('Open'))))));
    await tester.tap(find.text('Open'));await tester.pumpAndSettle();
    expect(find.text('UID / RF identity only'),findsOneWidget);
    expect(find.text('Authentication required'),findsNothing);
    await tester.tap(find.widgetWithText(FilledButton,'Save'));await tester.pumpAndSettle();
    expect(result!.uid,'01 02 03 04');expect(result!.tag,TagType.hf14a4);
    expect(result!.data,isEmpty);expect(result!.extraData.cpuDump,isEmpty);
    expect(tester.takeException(),isNull);
  });

  test('EOF before the advertised file length stays incomplete', () async {
    final reader=CpuDumpReader(exchange:(command) async {
      if(command[1]==0xA4)return cpuHex('6207820101800200049000');
      return cpuHex('41426282');
    },authenticate:() async=>throw StateError('Unexpected auth'));
    final result=await reader.read(parseCpuDumpPaths('1001'));
    expect(result.files.single.data,[65,66]);
    expect(result.files.single.complete,isFalse);
    expect(result.completeForPlan,isFalse);
    expect(result.deviceFilesystem(),isNull);
  });
  test('an advertised EMV record missing before the end is incomplete', () async {
    final reader=CpuDumpReader(exchange:(command) async {
      if(command[1]==0xA4)return cpuHex('9000');
      return command[2]==1 ? cpuHex('010203049000') : cpuHex('6A83');
    },authenticate:() async=>throw StateError('Unexpected auth'));
    final result=await reader.read([CpuDumpTarget([],aid:cpuHex('A0000000031010'),
      type:2,sfi:1,firstRecord:1,lastRecord:2)]);
    expect(result.files.single.complete,isFalse);
    expect(result.completeForPlan,isFalse);
  });
  testWidgets('native data JSON edits preserve identity, card ID, folder and classification', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500,1000));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    final original=CardSave(id:'existing-id',uid:'01 02 03 04',name:'Original',
      tag:TagType.hf14a4,sak:0x20,atqa:cpuHex('0400'),ats:cpuHex('0208'),
      folderId:'existing-folder',color:Colors.blue,
      extraData:CardSaveExtra(cpuApplication:'ndef'),data:[CpuFileSystem.example().encode()]);
    CardSave? result;
    await tester.pumpWidget(MaterialApp(locale:const Locale('en'),
      localizationsDelegates:AppLocalizations.localizationsDelegates,
      supportedLocales:AppLocalizations.supportedLocales,
      home:Builder(builder:(context)=>Scaffold(body:TextButton(child:const Text('Open'),
        onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>
          CpuDataEditor(card:original,onSave:(value)=>result=value))))))));
    await tester.tap(find.text('Open'));await tester.pumpAndSettle();
    final title=find.text(AppLocalizations.of(tester.element(find.byType(CpuDataEditor)))!.cpu_profile_json);
    await tester.scrollUntilVisible(title,200,scrollable:find.descendant(
      of:find.byKey(const PageStorageKey('cpu-native-data-scroll')),matching:find.byType(Scrollable)).first);
    await tester.ensureVisible(title);await tester.tap(title);await tester.pumpAndSettle();
    final editor=find.byKey(const PageStorageKey('cpu-native-json-scroll'));
    await tester.ensureVisible(editor);
    final changed=CpuFileSystem([CpuFileNode(parent:255,type:0,fid:0x3F00),
      CpuFileNode(parent:0,type:1,fid:0x1001,access:1,data:[9,8,7])]);
    await tester.enterText(editor,cpuProfileJson(CardData(uid:cpuHex('AABBCCDD'),
      sak:0x20,atqa:cpuHex('0000'),ats:cpuHex('0208')),[],name:'Replacement',filesystem:changed));
    FocusManager.instance.primaryFocus?.unfocus();await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton,'Save'));await tester.pumpAndSettle();
    expect(result,isNotNull);expect(result!.id,original.id);expect(result!.uid,original.uid);
    expect(result!.name,original.name);expect(result!.sak,original.sak);
    expect(result!.atqa,original.atqa);expect(result!.ats,original.ats);
    expect(result!.folderId,original.folderId);expect(result!.color.toARGB32(),original.color.toARGB32());
    expect(result!.extraData.cpuApplication,'ndef');
    expect(CpuFileSystem.decode(result!.data.single).nodes.last.data,[9,8,7]);
    expect(tester.takeException(),isNull);
  });
}
