import 'dart:io';
import 'package:chameleonultragui/gui/menu/tools/cpu_filesystem.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';
import 'package:flutter_test/flutter_test.dart';

class _Device {
  Uint8List? image;
  final calls = <Uint8List>[];
  final staging = BytesBuilder();
  bool failChunk = false, failCommit = false, shortRead = false;
  Future<Uint8List> exchange(Uint8List data) async {
    calls.add(Uint8List.fromList(data));
    switch (data.first) {
      case 0:
        final length = image?.length ?? 0;
        return Uint8List.fromList([1,image == null ? 0 : 1,0x0C,0xB4,length >> 8,length & 255]);
      case 1:
        final offset = data[1] << 8 | data[2], count = data[3];
        return Uint8List.fromList(image!.sublist(offset,offset+count-(shortRead ? 1 : 0)));
      case 2: staging.clear(); break;
      case 3:
        if (failChunk) throw StateError('chunk failure');
        expect(data.length, inInclusiveRange(4,203));
        expect(data[1] << 8 | data[2], staging.length);
        staging.add(data.sublist(3)); break;
      case 4:
        if (failCommit) throw StateError('commit failure');
        image = staging.takeBytes(); break;
      case 5: staging.clear(); break;
      default: fail('Unexpected filesystem opcode');
    }
    return Uint8List(0);
  }
}

void main() {
  test('CFS1 JSON and binary round trip preserves hierarchy, access and records', () {
    final fs = CpuFileSystem.example();
    final image = fs.encode();
    expect(image.take(6), [0x43,0x46,0x53,0x31,1,4]);
    expect(image[6] << 8 | image[7], image.length);
    final decoded = CpuFileSystem.decode(image);
    expect(decoded.nodes[1].aid, [0xF0,1,2,3,4,5,6]);
    expect(decoded.nodes[2].data, [0,4,0x41,0x42,0x43,0x44]);
    expect(decoded.nodes[3].recordLength, 4);
    expect(decoded.nodes[3].access, 3);
    expect(CpuFileSystem.fromJson(jsonDecode(jsonEncode(decoded.toJson())) as Map<String,dynamic>).encode(), image);
  });

  test('all truncated image prefixes fail with FormatException', () {
    final image = CpuFileSystem.example().encode();
    for (var length = 0; length < image.length; length++) {
      expect(() => CpuFileSystem.decode(Uint8List.fromList(image.take(length).toList())), throwsFormatException);
    }
    for (final offset in [0,4,5,6,7,8,9,10]) {
      final broken = Uint8List.fromList(image); broken[offset] ^= 0x80;
      expect(() => CpuFileSystem.decode(broken), throwsFormatException);
    }
  });

  test('invalid parents, duplicate siblings and malformed records are rejected', () {
    final root = CpuFileNode(parent:255,type:0,fid:0x3F00);
    for (final node in [
      CpuFileNode(parent:1,type:1,fid:0x1001),
      CpuFileNode(parent:0,type:2,fid:0x1001,recordLength:0),
      CpuFileNode(parent:0,type:2,fid:0x1001,recordLength:4,data:[1]),
      CpuFileNode(parent:0,type:1,fid:0x1001,aid:[1,2,3,4,5]),
      CpuFileNode(parent:0,type:1,fid:0x1001,sfi:31),
    ]) {
      expect(() => CpuFileSystem([root,node]).encode(), throwsFormatException);
    }
    expect(() => CpuFileSystem([root,CpuFileNode(parent:0,type:1,fid:0x1001),CpuFileNode(parent:0,type:1,fid:0x1001)]).encode(), throwsFormatException);
    expect(() => CpuFileSystem([root,CpuFileNode(parent:0,type:1,fid:0x1001,sfi:1),CpuFileNode(parent:0,type:1,fid:0x1002,sfi:1)]).encode(), throwsFormatException);
    expect(() => CpuFileSystem([root,CpuFileNode(parent:0,type:1,fid:0x1001,data:List.filled(3252,0))]).encode(), throwsFormatException);
  });

  test('profile v2 survives saved-card serialization and legacy v1 remains supported', () {
    final identity = CardData(uid:cpuHex('04010203040506'),atqa:cpuHex('0400'),sak:0x20,ats:cpuHex('0208'));
    final source = cpuProfileJson(identity,[],name:'Files',filesystem:CpuFileSystem.example());
    expect(jsonDecode(source)['version'],2);
    final card = cpuProfileFromJson(source);
    expect(cpuFilesystemFromData(card.data), CpuFileSystem.example().encode());
    expect(cpuSavedProfileJson(card),source);
    final legacy = cpuProfileFromJson(cpuProfileJson(identity,[CpuApduPair(cpuHex('00B0'),cpuHex('9000'))]));
    expect(cpuFilesystemFromData(legacy.data),isNull);
    expect(cpuRulesFromData(legacy.data).length,1);
    final mixed = jsonDecode(source) as Map<String,dynamic>; mixed['responses'] = [];
    expect(() => cpuProfileFromJson(jsonEncode(mixed)),throwsFormatException);
  });

  test('upload chunks are contiguous, bounded, committed and read back byte-for-byte', () async {
    final image = CpuFileSystem([CpuFileNode(parent:255,type:0,fid:0x3F00),
      CpuFileNode(parent:0,type:1,fid:0x1001,access:3,data:List.generate(601,(i)=>i&255))]).encode();
    final device = _Device();
    await writeCpuFilesystem(image, device.exchange);
    expect(device.image,image);
    expect(device.calls.where((c)=>c.first == 3).length,4);
    expect(device.calls.where((c)=>c.first == 4).length,1);
    expect(device.calls.where((c)=>c.first == 5),isEmpty);
    expect(await readCpuFilesystem(device.exchange),image);
  });

  test('transfer and commit failures cancel staging and preserve previous image', () async {
    for (final failCommit in [false,true]) {
      final old = CpuFileSystem([CpuFileNode(parent:255,type:0,fid:0x3F00)]).encode();
      final device = _Device()..image=old..failChunk=!failCommit..failCommit=failCommit;
      await expectLater(writeCpuFilesystem(CpuFileSystem.example().encode(),device.exchange),throwsStateError);
      expect(device.image,old);
      expect(device.calls.last,[5]);
      expect(device.calls.where((c)=>c.first == 4).length, failCommit ? 1 : 0);
    }
  });

  test('invalid image never starts upload; truncated read is rejected', () async {
    final device = _Device();
    await expectLater(writeCpuFilesystem(Uint8List(8),device.exchange),throwsFormatException);
    expect(device.calls,isEmpty);
    expect(await readCpuFilesystem(device.exchange),isNull);
    device.image=CpuFileSystem.example().encode(); device.shortRead=true;
    await expectLater(readCpuFilesystem(device.exchange),throwsFormatException);
  });

  testWidgets('file editor adds a binary file on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320,760));
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    CpuFileSystem? result;
    await tester.pumpWidget(MaterialApp(locale:const Locale('en'),
      localizationsDelegates:AppLocalizations.localizationsDelegates,
      supportedLocales:AppLocalizations.supportedLocales,
      home:Scaffold(body:SingleChildScrollView(padding:const EdgeInsets.all(16),
        child:CpuFilesystemEditor(filesystem:CpuFileSystem([CpuFileNode(parent:255,type:0,fid:0x3F00)]),
          onChanged:(value)=>result=value)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add binary file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byWidgetPredicate((w)=>w is TextField && w.decoration?.labelText == 'File contents (hex)'), '01020304');
    await tester.tap(find.widgetWithText(FilledButton,'OK'));
    await tester.pumpAndSettle();
    expect(result?.nodes.length,2);
    expect(result?.nodes.last.data,[1,2,3,4]);
    expect(tester.takeException(),isNull);
  });

  test('delivered JSON examples load through the real profile codec', () {
    for(final name in ['CPU文件系统示例.json','CPU-NDEF文件系统示例.json']) {
      final card=cpuProfileFromJson(File('../examples/$name').readAsStringSync());
      final image=cpuFilesystemFromData(card.data)!;
      expect(CpuFileSystem.decode(image).nodes.length,4);
      expect(cpuProfileFromJson(cpuSavedProfileJson(card)).data.single,image);
    }
  });

}
