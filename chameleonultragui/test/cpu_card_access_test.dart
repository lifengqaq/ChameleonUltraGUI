import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
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
        ('00B2020400', '61074F05F0102030409000'),
        ('00B2030400', '6A83'),
      ]);
      final applications = await CpuCardAccess(script.transmit)
          .readApplications();
      expect(applications.single.aid, cpuHex('F010203040'));
      expect(applications.single.label, 'App');
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
