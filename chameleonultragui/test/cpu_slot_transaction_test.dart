import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/hf14a4_slot.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

class _Slots extends ChameleonCommunicator {
  final calls = <String>[];
  TagType type = TagType.hf14a4;
  bool failUpload = false, supported = true;
  _Slots() : super(Logger(level: Level.off));
  @override
  Future<List<SlotTypes>> getSlotTagTypes() async => [
    for (var i = 0; i < 8; i++) SlotTypes(hf: type),
  ];
  @override
  Future<void> setSlotType(int slot, TagType type) async {
    calls.add('type');
    this.type = type;
  }

  @override
  Future<void> setDefaultDataToSlot(int slot, TagType type) async {
    calls.add('factory');
  }

  @override
  Future<List<int>> getDeviceCapabilities() async => [
    6008,
    if (supported) 6009,
  ];
  @override
  Future<void> hf14a4WriteFilesystem(Uint8List image) async {
    calls.add('upload');
    if (failUpload) throw StateError('transfer failed');
    calls.add('committed-and-verified');
  }

  @override
  Future<void> setMf1AntiCollision(CardData data) async {
    calls.add('identity');
  }
}

void main() {
  final identity = CardData(
    uid: cpuHex('04010203040506'),
    atqa: cpuHex('0004'),
    sak: 0x20,
    ats: cpuHex('0208'),
  );
  final card = cpuProfileFromJson(
    cpuProfileJson(identity, [], filesystem: CpuFileSystem.example()),
  );
  test('existing CPU slot stays intact until image commit completes', () async {
    final device = _Slots();
    await prepareHf14a4Slot(device, 0);
    expect(device.calls, isEmpty);
    await writeHf14a4SlotIdentity(device, card);
    expect(device.calls, ['upload', 'committed-and-verified', 'identity']);
  });
  test(
    'failed image transfer neither factory-resets slot nor replaces identity',
    () async {
      final device = _Slots()..failUpload = true;
      await prepareHf14a4Slot(device, 0);
      await expectLater(
        writeHf14a4SlotIdentity(device, card),
        throwsStateError,
      );
      expect(device.calls, ['upload']);
    },
  );
  test(
    'changing from a different card type initializes CPU slot once',
    () async {
      final device = _Slots()..type = TagType.mifare1K;
      await prepareHf14a4Slot(device, 0);
      await prepareHf14a4Slot(device, 0);
      expect(device.calls, ['type', 'factory']);
    },
  );
  test(
    'missing filesystem capability rejects before identity or image change',
    () async {
      final device = _Slots()..supported = false;
      await expectLater(
        writeHf14a4SlotIdentity(device, card),
        throwsStateError,
      );
      expect(device.calls, isEmpty);
    },
  );
}
