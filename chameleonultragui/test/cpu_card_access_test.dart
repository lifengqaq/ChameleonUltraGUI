import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_directory_view.dart';
import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:chameleonultragui/helpers/cpu_directory.dart';
import 'package:chameleonultragui/helpers/cpu_directory_record.dart';
import 'package:chameleonultragui/helpers/cpu_type4.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CardScript {
  final List<(String, String)> script;
  int _position = 0;
  _CardScript(this.script);

  Future<Uint8List> transmit(Uint8List apdu) async {
    expect(_position, lessThan(script.length), reason: 'Unexpected extra APDU');
    final (command, reply) = script[_position++];
    expect(apdu, cpuHex(command));
    return cpuHex(reply);
  }

  void done() => expect(_position, script.length);
}

void main() {
  test(
    'FMCOS record creation places count, length and both ACL bytes separately',
    () async {
      final script = _CardScript([
        ('80E00008072A031401F2FFFF', '9000'),
        ('00A40000020008', '9000'),
      ]);
      final card = CpuCardAccess(script.transmit, useFmcosMaster: true);
      final parent = CpuLiveFile.fromSelect(
        cpuHex('6F0984055445535431A500'),
        directory: true,
        typedSelection: false,
        fid: 0x1100,
      );
      final ef = CpuFmcosEf.fixedRecords(
        recordLength: 20,
        recordCount: 3,
        readAccess: 0x01,
        writeAccess: 0xF2,
      );
      await card.createFmcosEf(0x0008, parent: parent, ef: ef);
      final selected = await card.selectFile(0x0008, directory: false);
      final file = selected.withCreatedFmcosEf(ef);
      expect(file.fixedRecordLength, isTrue);
      expect(file.recordLength, 20);
      expect(file.recordCount, 3);
      script.done();
    },
  );

  test(
    'binary writes advance by confirmed blocks and report a stopped transfer',
    () async {
      final first = List.filled(255, 'AA').join();
      final tail = List.filled(45, 'BB').join();
      final script = _CardScript([
        ('00D60005FF$first', '9000'),
        ('00D601042D$tail', '6982'),
        ('00D601042D$tail', '6581'),
      ]);
      final card = CpuCardAccess(script.transmit);
      var requests = 0;
      await expectLater(
        card.updateBinaryRange(
          5,
          cpuHex('$first$tail', max: 300),
          write: (offset, data) => runCpuFileOperation(
            () => card.updateBinary(offset, data),
            authorize: () async {
              requests++;
              return true;
            },
          ),
        ),
        throwsA(
          isA<CpuPartialWrite>()
              .having((failure) => failure.confirmedBytes, 'confirmed', 255)
              .having(
                (failure) => (failure.cause as CpuFileStatus).word,
                'status',
                0x6581,
              ),
        ),
      );
      expect(requests, 1);
      script.done();
    },
  );

  test('decodes ISO directory paths and Type 4 CC and NDEF without guessing by bytes', () {
    final dir = inspectCpuDirectoryRecord(
      cpuHex('610F4F05F01020304051063F0050151001'),
      format: CpuDirectoryFormat.efDir,
    );
    expect(dir.issues, isEmpty);
    expect(dir.fields.last.value, cpuHex('3F0050151001'));
    final cc = parseCpuType4Capability(
      cpuHex('001930003B00340406E111040000FF0608E1120001020300FF'),
    );
    expect(cc.header.maxRead, 0x3B);
    expect(cc.files.first.writeAccess, 255);
    expect(cc.files.last.lengthBytes, 4);
    final message = cpuHex(
      '9101055402656E486951010C55046578616D706C652E636F6D',
    );
    final records = parseCpuNdefMessage(message);
    expect(records.first.text, 'Hi');
    expect(records.first.language, 'en');
    expect(records.last.uri, 'https://example.com');
    expect(
      () => parseCpuNdefMessage(message.sublist(0, message.length - 1)),
      throwsFormatException,
    );
  });

  test('explicit AID selection can omit Le but never changes the name or bypasses a security status', () async {
    final script = _CardScript([
      ('00A4040009A0000000038698079100', '6A82'),
      ('00A4040009A00000000386980791', '6F0B8409A000000003869807919000'),
      ('00A4040009A0000000038698079100', '6982'),
    ]);
    final card = CpuCardAccess(script.transmit);
    final aid = cpuHex('A00000000386980791');
    expect((await card.selectAidForAccess(aid)).aid, aid);
    await expectLater(
      card.selectAidForAccess(aid),
      throwsA(isA<CpuFileStatus>().having((e) => e.word, 'status', 0x6982)),
    );
    script.done();
  });
  testWidgets('expanded directory opens the file at its exact path', (
    tester,
  ) async {
    final tree = CpuDirectoryTree()
      ..add(
        CpuDirectoryEntry(
          CpuFileAddress([0x5015, 0x1000, 0x1001]),
          kind: CpuLiveFileKind.binary,
          label: 'Test file',
        ),
      );
    CpuFileAddress? opened;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CpuDirectoryView(
            tree: tree,
            onOpen: (entry) => opened = entry.address,
          ),
        ),
      ),
    );
    expect(find.text('Test file'), findsNothing);
    await tester.tap(find.byTooltip('Expand folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test file'));
    expect(opened?.display, '3F00/5015/1000/1001');
  });

  test(
    'selects a file and reads or changes only the requested bytes',
    () async {
      final script = _CardScript([
        ('00A40000023F0000', '62088202382183023F009000'),
        ('00A4020002100100', '620C8202012183021001800200209000'),
        ('00B0000004', '6C03'),
        ('00B0000003', '0102036282'),
        ('00D6000102AA55', '9000'),
      ]);
      final card = CpuCardAccess(script.transmit);
      expect((await card.selectMaster()).isDirectory, isTrue);
      final file = await card.selectFile(0x1001, directory: false);
      expect(file.kind, CpuLiveFileKind.binary);
      expect(file.size, 32);
      final read = await card.readBinary(0, 4);
      expect(read.status, 0x6282);
      expect(read.data, [1, 2, 3]);
      await card.updateBinary(1, cpuHex('AA55'));
      script.done();
    },
  );

  test(
    'directory maintenance reports card denial without another attempt',
    () async {
      final script = _CardScript([
        ('00E000000A62088202382183021000', '9000'),
        ('00E0000011620F820502210003028302100180020006', '9000'),
        ('00DC020403112233', '6C02'),
        ('00E40000021000', '6982'),
      ]);
      final card = CpuCardAccess(script.transmit);
      await card.createFile(0x1000, CpuLiveFileKind.directory);
      await card.createFile(
        0x1001,
        CpuLiveFileKind.record,
        recordLength: 3,
        recordCount: 2,
      );
      await expectLater(
        card.updateRecord(2, cpuHex('112233')),
        throwsA(
          isA<CpuFileStatus>().having((error) => error.word, 'SW', 0x6C02),
        ),
      );
      await expectLater(
        card.deleteFile(0x1000),
        throwsA(
          isA<CpuFileStatus>().having((error) => error.word, 'SW', 0x6982),
        ),
      );
      script.done();
    },
  );

  test(
    'reads published applications from EF.DIR and handles the end of records',
    () async {
      final script = _CardScript([
        ('00A40000023F0000', '9000'),
        ('00A40200022F0000', '620782010283022F009000'),
        ('00B2010400', '610C4F05F01020304050034170709000'),
        ('00B2020400', '610F4F05F01020304051063F00501510019000'),
        ('00B2030400', '6A83'),
      ]);
      final card = CpuCardAccess(script.transmit);
      await card.selectMaster();
      final file = await card.selectFile(0x2F00, directory: false);
      final applications = await card.readApplicationEntries(file);
      expect(applications.single.aid, cpuHex('F010203040'));
      expect(applications.single.label, 'App');
      expect(applications.single.path, [0x5015, 0x1001]);
      script.done();
    },
  );

  test(
    'directory discovery uses published paths and Type 4 file IDs',
    () async {
      final script = _CardScript([
        ('00A40000023F0000', '9000'),
        ('00A40200022F0000', '620782010283022F009000'),
        ('00B2010400', '61144F05F010203040500341707051063F00501510019000'),
        ('00B2020400', '6A83'),
        ('00A404000E315041592E5359532E444446303100', '6A82'),
        (
          '00A404000E325041592E5359532E444446303100',
          '6F0EA50CBF0C0961074F05F0102030409000',
        ),
        ('00A4040007D276000085010100', '9000'),
        ('00A4000C02E103', '9000'),
        ('00B000000F', '001930003B00340406E111040000FF9000'),
        ('00B0000F0A', '0608E1120001020300FF9000'),
        ('00A40000023F0000', '9000'),
        ('00A4040007D276000085010100', '9000'),
        ('00A4000C02E112', '9000'),
      ]);
      final card = CpuCardAccess(script.transmit);
      final scan = await discoverCpuDirectory(card);
      expect(scan.master?.fid, 0x3F00);
      expect(scan.cardStatuses, isEmpty);
      final root = scan.tree.childrenOf(null);
      expect(root.map((entry) => entry.address.display), [
        '3F00',
        'AID 325041592E5359532E4444463031',
        'AID D2760000850101',
      ]);
      final app = scan.tree.childrenOf(CpuFileAddress([0x5015])).single;
      expect(app.address.display, '3F00/5015/1001');
      expect(app.label, 'App');
      final ndef = scan.tree.childrenOf(root.last.address);
      expect(ndef.map((entry) => entry.address.fid), [0xE103, 0xE111, 0xE112]);
      expect(ndef.last.capacity, 0x010203);
      final opened = await ndef.last.address.open(
        card,
        directory: false,
        type4: true,
        selectedDirectory: const CpuFileAddress.master(),
      );
      expect(opened.fid, 0xE112);
      expect(opened.canChange, isFalse);
      script.done();
    },
  );

  test(
    'directory reports protected EF.DIR and still lists public applications',
    () async {
      final script = _CardScript([
        ('00A40000023F0000', '9000'),
        ('00A40200022F0000', '620782010183022F009000'),
        ('00B0000000', '6982'),
        ('00A404000E315041592E5359532E444446303100', '6A82'),
        (
          '00A404000E325041592E5359532E444446303100',
          '6F0EA50CBF0C0961074F05F0102030409000',
        ),
        ('00A4040007D276000085010100', '6A82'),
        ('00A40000023F0000', '9000'),
      ]);
      final scan = await discoverCpuDirectory(CpuCardAccess(script.transmit));
      expect(scan.cardStatuses, {'EF.DIR': 0x6982});
      expect(
        scan.tree
            .childrenOf(CpuFileAddress([], aid: cpuPpseName.codeUnits))
            .single
            .address
            .aid,
        cpuHex('F010203040'),
      );
      expect(scan.tree.at(CpuFileAddress([0x2F00]))?.label, 'EF.DIR');
      script.done();
    },
  );

  test('screenshot PSE FCI leads to SFI records and a nested DDF', () async {
    const response = '6F15840E315041592E5359532E4444463031A5038801019000';
    final script = _CardScript([
      ('00A40000023F0000', response),
      ('00B2010C00', '700961079D05F0010203049000'),
      ('00B2020C00', '6A83'),
      ('00A4040005F00102030400', '6F0C8405F001020304A5038801029000'),
      ('00B2011400', '700E610C4F05F01234567850034170709000'),
      (
        '00B2021400',
        '700961079D05F0010203049000',
      ), // cycle: this DDF already visited
      ('00B2031400', '6A83'),
      ('00A404000E325041592E5359532E444446303100', '6A82'),
      ('00A4040007D276000085010100', '6A82'),
      ('00A40000023F0000', response),
    ]);
    final scan = await discoverCpuDirectory(CpuCardAccess(script.transmit));
    expect(scan.master?.fid, isNull);
    expect(scan.master?.canChange, isFalse);
    final root = scan.tree.childrenOf(null).single;
    expect(root.label, 'PSE');
    final children = scan.tree.childrenOf(root.address);
    expect(children.last.address.sfi, 1);
    expect(children.last.address.fid, isNull);
    final nested = scan.tree.childrenOf(children.first.address);
    expect(nested.first.label, 'App');
    expect(nested.last.address.sfi, 2);
    expect(scan.selectedAddress?.display, root.address.display);
    script.done();
  });

  test(
    'credential choice follows a denied operation and retries only once',
    () async {
      final script = _CardScript([
        ('00B0000001', '6982'),
        ('00B0000001', '6982'),
        ('00B0000001', '6982'),
        ('00D600000101', '6100'),
        ('00C0000000', '6982'),
        ('00B0000001', '019000'),
      ]);
      final card = CpuCardAccess(script.transmit);
      var offered = 0;
      Future<CpuFileReply> run(
        Future<CpuFileReply> Function() send,
        bool useKey,
      ) => runCpuFileOperation(
        send,
        authorize: () async {
          offered++;
          return useKey;
        },
      );
      await expectLater(
        run(() => card.readBinary(0, 1), false),
        throwsA(isA<CpuFileStatus>()),
      );
      expect(offered, 1);
      await expectLater(
        run(() => card.readBinary(0, 1), true),
        throwsA(isA<CpuFileStatus>()),
      );
      expect(offered, 2);
      await expectLater(
        run(() => card.updateBinary(0, Uint8List.fromList([1])), true),
        throwsA(
          isA<CpuFileStatus>().having(
            (e) => e.originalRejected,
            'write rejected',
            false,
          ),
        ),
      );
      expect((await run(() => card.readBinary(0, 1), true)).data, [1]);
      expect(offered, 2);
      script.done();
    },
  );

  test('ISO PIN change sends the specified reference and never retries on rejection', () async {
    final script = _CardScript([('00240081083132333435363738', '63C1')]);
    final card = CpuCardAccess(script.transmit);
    await expectLater(
      card.changePin(0x81, CpuPinEncoding.ascii, '1234', '56789'),
      throwsFormatException,
    );
    await expectLater(
      card.changePin(0x81, CpuPinEncoding.ascii, '1234', '5678'),
      throwsA(
        isA<CpuFileStatus>().having(
          (e) => e.word,
          'remaining attempts status',
          0x63C1,
        ),
      ),
    );
    script.done();
  });

  test(
    'rejects a different FID and keeps generic untyped selection read-only',
    () async {
      final script = _CardScript([
        ('00A4020002100100', '6207830210028201019000'),
        ('00A4020002100100', '6A86'),
        ('00A4000002100100', '9000'),
      ]);
      final card = CpuCardAccess(script.transmit);
      await expectLater(
        card.selectFile(0x1001, directory: false),
        throwsFormatException,
      );
      final file = await card.selectFile(0x1001, directory: false);
      expect(file.supportsBinary, isTrue);
      expect(file.canChange, isFalse);
      script.done();
    },
  );
}
