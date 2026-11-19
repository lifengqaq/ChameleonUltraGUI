import 'package:chameleonultragui/helpers/iso7816_fs.dart';

import 'dart:typed_data';

import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

Future<void> writeHf14a4SlotIdentity(
  ChameleonCommunicator communicator,
  CardSave card,
) async {
  final image = validateCpuCardForDevice(card);
  final pairs = card.tag == TagType.hf14a4 && image == null
      ? cpuRulesFromData(card.data)
      : <CpuApduPair>[];
  final commands = card.tag == TagType.hf14a4
      ? await communicator.getDeviceCapabilities()
      : <int>[];
  final supported = commands.contains(ChameleonCommand.hf14a4StaticRead.value);
  if (image != null &&
      !commands.contains(ChameleonCommand.hf14a4Filesystem.value)) {
    throw StateError('请先升级配套固件：当前设备缺少 CPU 文件系统命令 6009');
  }
  if (pairs.isNotEmpty && !supported) {
    throw StateError('APDU table upload requires updated ISO-DEP firmware');
  }
  if (image != null) {
    if (image[4] == 2) await communicator.hf14a4RequireFilesystemSecurity();
    await communicator.hf14a4WriteFilesystem(image);
  } else if (supported) {
    await communicator.hf14a4ClearStaticResponses();
    for (final pair in pairs) {
      await communicator.hf14a4AddStaticResponse(pair.command, pair.response);
    }
  }
  await communicator.setMf1AntiCollision(
    CardData(
      uid: hexToBytes(card.uid),
      atqa: card.atqa,
      sak: card.sak,
      ats: card.ats,
    ),
  );
}

Future<CardSave> readHf14a4SlotIdentity(
  ChameleonCommunicator communicator,
  String name,
) async {
  final data = await communicator.mf1GetAntiCollData();

  final commands = await communicator.getDeviceCapabilities();
  final image = commands.contains(ChameleonCommand.hf14a4Filesystem.value)
      ? await communicator.hf14a4ReadFilesystem()
      : null;
  final pairs =
      image == null &&
          commands.contains(ChameleonCommand.hf14a4StaticRead.value)
      ? await communicator.hf14a4ReadStaticResponses()
      : <CpuApduPair>[];
  return CardSave(
    uid: bytesToHexSpace(data.uid),
    name: name,
    sak: data.sak,
    atqa: data.atqa,
    ats: data.ats,
    tag: TagType.hf14a4,
    data: <Uint8List>[
      if (image != null) image,
      for (final pair in pairs) ...[pair.command, pair.response],
    ],
  );
}

/// Preserve an existing CPU slot until the staged filesystem has committed.
Future<void> prepareHf14a4Slot(
  ChameleonCommunicator communicator,
  int slot,
) async {
  if (slot < 0 || slot > 7) throw RangeError.range(slot, 0, 7, 'slot');
  final types = await communicator.getSlotTagTypes();
  if (types.length <= slot) throw const FormatException('设备返回的卡槽列表不完整');
  if (types[slot].hf != TagType.hf14a4) {
    await communicator.setSlotType(slot, TagType.hf14a4);
    await communicator.setDefaultDataToSlot(slot, TagType.hf14a4);
  }
}

/// Validate before the caller changes the active slot or its contents.
Uint8List? validateCpuCardForDevice(CardSave card) {
  if (card.tag != TagType.hf14a4) return null;
  if (card.extraData.cpuDump['archiveOnly'] == true) {
    throw StateError('此卡是归档转储，无法作为 UID-only 卡上传。请在编辑数据中明确创建可容纳的模拟文件。');
  }
  return cpuFilesystemFromData(card.data, requireSingleAuthentication: true);
}
