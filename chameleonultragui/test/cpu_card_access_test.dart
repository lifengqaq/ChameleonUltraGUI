import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_directory_view.dart';
import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_directory.dart';
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
        (
          '00A404000E325041592E5359532E444446303100',
          '6F0EA50CBF0C0961074F05F0102030409000',
        ),
        ('00A4040007D276000085010100', '6A82'),
        ('00A40000023F0000', '9000'),
      ]);
      final scan = await discoverCpuDirectory(CpuCardAccess(script.transmit));
      expect(scan.cardStatuses, {'EF.DIR': 0x6982});
      expect(scan.tree.childrenOf(null).last.address.display, 'AID F010203040');
      expect(scan.tree.at(CpuFileAddress([0x2F00]))?.label, 'EF.DIR');
      script.done();
    },
  );

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
