import 'package:chameleonultragui/helpers/hf14a4_slot.dart';

import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

class Device extends ChameleonCommunicator {
  Device() : super(Logger(level: Level.off));
  final calls = <(ChameleonCommand, Uint8List)>[];
  final replies = <ChameleonMessage>[];
  @override
  Future<ChameleonMessage?> sendCmd(
    ChameleonCommand cmd, {
    Uint8List? data,
    Duration timeout = const Duration(seconds: 5),
    bool skipReceive = false,
    bool firstRun = false,
  }) async {
    calls.add((cmd, data ?? Uint8List(0)));
    return replies.removeAt(0);
  }

  void reply(int status, List<int> data) => replies.add(
    ChameleonMessage(
      command: 0,
      status: status,
      data: Uint8List.fromList(data),
    ),
  );
}

final identity = CardData(
  uid: cpuHex('04010203'),
  atqa: cpuHex('0004'),
  sak: 0x20,
  ats: cpuHex('067580700200'),
);
List<int> identityBytes() => [
  4,
  ...identity.uid,
  ...cpuAtqaToWire(identity.atqa),
  0x20,
  6,
  ...identity.ats,
];
void main() {
  test('CPU failures retain structured command and RF status', () async {
    final device = Device()..reply(1, []);
    await expectLater(
      device.hf14a4EmvScan(),
      throwsA(
        isA<CpuCommandError>()
            .having((error) => error.command, 'command', 6005)
            .having((error) => error.status, 'status', 1),
      ),
    );
  });

  test(
    'shared identity helper leaves MIFARE block dumps out of CPU validation',
    () async {
      final device = Device()..reply(0x68, []);
      final card = CardSave(
        uid: '01020304',
        name: 'EV1',
        tag: TagType.mifare2K,
        atqa: Uint8List(2),
        data: List.generate(72, (i) => Uint8List(16)),
      );
      await writeHf14a4SlotIdentity(device, card);
      expect(device.calls.single.$1, ChameleonCommand.mf1SetAntiCollision);
    },
  );

  test('strict hex and full identity bounds', () {
    expect(cpuHex('00 A4\n04'), [0, 0xA4, 4]);
    for (final value in ['0', 'GG', '0x00']) {
      expect(() => cpuHex(value), throwsFormatException);
    }
    final packed = Uint8List.fromList(identityBytes());
    for (var length = 0; length < packed.length; length++) {
      expect(
        () =>
            parseCpuIdentity(Uint8List.fromList(packed.take(length).toList())),
        throwsFormatException,
      );
    }
    expect(parseCpuIdentity(packed).$1.uid, identity.uid);
    expect(parseCpuIdentity(packed).$1.atqa, cpuHex('0004'));
    expect(cpuAtqaFromWire(cpuHex('0400')), cpuHex('0004'));
    expect(cpuAtqaToWire(cpuHex('0004')), cpuHex('0400'));
    expect(() => parseCpuIdentity(packed, offset: -1), throwsFormatException);
    final invalidAts = Uint8List.fromList([
      4,
      4,
      1,
      2,
      3,
      4,
      0,
      0x20,
      2,
      2,
      0x75,
    ]);
    expect(() => parseCpuIdentity(invalidAts), throwsFormatException);
  });

  test('legacy scan and CPU scan both normalize ATQA; both upload paths restore wire order', () async {
    final raw = <int>[4, ...identity.uid, 0x04, 0x00, 0x20, 6, ...identity.ats];
    final scanDevice = Device()..reply(0x68, raw);
    expect((await scanDevice.scan14443aTag())!.atqa, cpuHex('0004'));

    final keepDevice = Device()..reply(0x68, raw);
    expect((await keepDevice.scan14443aTagKeep()).single.atqa, cpuHex('0004'));

    final slotReadDevice = Device()..reply(0x68, raw);
    expect((await slotReadDevice.mf1GetAntiCollData()).atqa, cpuHex('0004'));

    final sessionDevice = Device()..reply(0, raw);
    expect((await sessionDevice.hf14a4OpenSession()).atqa, cpuHex('0004'));

    final legacyUpload = Device()..reply(0x68, []);
    await legacyUpload.setMf1AntiCollision(identity);
    expect(legacyUpload.calls.single.$2.sublist(5, 7), cpuHex('0400'));

    final cpuUpload = Device()..reply(0x68, []);
    await cpuUpload.hf14a4SetAntiColl(
      identity.uid,
      identity.atqa,
      identity.sak,
      identity.ats,
    );
    expect(cpuUpload.calls.single.$2.sublist(5, 7), cpuHex('0400'));

    final card = cpuProfileFromJson(cpuProfileJson(identity, []));
    expect(card.atqa, cpuHex('0004'));
    expect(CardSave.fromJson(card.toJson()).atqa, cpuHex('0004'));
  });
  test('profile and library JSON retain APDU pairs', () {
    final pair = CpuApduPair(cpuHex('00A4'), cpuHex('9000'));
    final card = cpuProfileFromJson(cpuProfileJson(identity, [pair]));
    final restored = CardSave.fromJson(card.toJson());
    expect(restored.tag, TagType.hf14a4);
    expect(cpuRulesFromData(restored.data).first.response, [0x90, 0]);
    expect(() => cpuRulesFromData([cpuHex('00')]), throwsFormatException);
  });
  test('validate capacities and duplicate prefixes before upload', () {
    expect(
      () => validateCpuRules([CpuApduPair(Uint8List(17), cpuHex('9000'))]),
      throwsFormatException,
    );
    expect(
      () => validateCpuRules([CpuApduPair(cpuHex('00'), Uint8List(261))]),
      throwsFormatException,
    );
    expect(
      () => validateCpuRules([
        for (var i = 0; i < 13; i++)
          CpuApduPair(Uint8List.fromList([i]), cpuHex('9000')),
      ]),
      throwsFormatException,
    );
    expect(
      () => validateCpuRules([
        for (var i = 0; i < 5; i++)
          CpuApduPair(Uint8List.fromList([i]), Uint8List(254)),
      ]),
      throwsFormatException,
    );
    expect(
      () => validateCpuRules([
        for (var i = 0; i < 2; i++) CpuApduPair(cpuHex('00A4'), cpuHex('9000')),
      ]),
      throwsFormatException,
    );
  });
  test('EMV parser supports little-endian responses longer than 255 bytes', () {
    final packed = Uint8List.fromList([
      ...identityBytes(),
      1,
      4,
      0,
      0xA4,
      4,
      0,
      0,
      1,
      ...List<int>.filled(254, 0x55),
      0x90,
      0,
    ]);
    final parsed = parseCpuEmvScan(packed);
    expect(parsed.$2.single.response.length, 256);
    expect(parsed.$2.single.statusWord, 0x9000);
    final truncated = Uint8List.fromList(
      packed.take(packed.length - 1).toList(),
    );
    expect(() => parseCpuEmvScan(truncated), throwsFormatException);
    expect(
      () => parseCpuEmvScan(Uint8List.fromList([...packed, 0])),
      throwsFormatException,
    );
  });
  test('61xx and read-only 6Cxx preserve status and data', () async {
    final calls = <Uint8List>[];
    final replies = [cpuHex('6C02'), cpuHex('AA6101'), cpuHex('BB9000')];
    final result = await exchangeCpuApdu(cpuHex('00B0000000'), (command) async {
      calls.add(command);
      return replies.removeAt(0);
    });
    expect(result, cpuHex('AABB9000'));
    expect(calls[1], cpuHex('00B0000002'));
    expect(calls[2], cpuHex('00C0000001'));
  });
  test(
    'writes are not repeated for 6Cxx and procedure loops are bounded',
    () async {
      var calls = 0;
      final result = await exchangeCpuApdu(cpuHex('00D6000000'), (
        command,
      ) async {
        calls++;
        return cpuHex('6C01');
      });
      expect(calls, 1);
      expect(result, cpuHex('6C01'));
      calls = 0;
      await expectLater(
        exchangeCpuApdu(cpuHex('00B0000000'), (command) async {
          calls++;
          return cpuHex('6101');
        }),
        throwsStateError,
      );
      expect(calls, 16);
    },
  );
  test('bridge preserves the high byte of 256-byte static responses', () async {
    final device = Device()..reply(0x68, []);
    await device.hf14a4AddStaticResponse(cpuHex('00A4'), Uint8List(256));
    final payload = device.calls.single.$2;
    expect(payload.sublist(0, 5), [2, 0, 0xA4, 1, 0]);
  });
  test(
    'bridge rejects firmware failures instead of returning debug bytes',
    () async {
      final device = Device()..reply(1, [1, 2]);
      await expectLater(
        device.hf14a4ReaderApdu(cpuHex('00A40400')),
        throwsStateError,
      );
    },
  );
  test('static table read uses BE16 and returns all pairs', () async {
    final device = Device()
      ..reply(0x68, [1])
      ..reply(0x68, [2, 0, 0xA4, 0, 2, 0x90, 0]);
    final pairs = await device.hf14a4ReadStaticResponses();
    expect(pairs.single.command, cpuHex('00A4'));
    expect(pairs.single.response, cpuHex('9000'));
  });
  test('open and close session have explicit wire commands', () async {
    final device = Device()
      ..reply(0, identityBytes())
      ..reply(0x68, []);
    expect((await device.hf14a4OpenSession()).uid, identity.uid);
    await device.hf14a4CloseSession();
    expect(device.calls.map((c) => c.$1.value), [6007, 6007]);
    expect(device.calls[0].$2, [1]);
    expect(device.calls[1].$2, [0]);
  });
}
