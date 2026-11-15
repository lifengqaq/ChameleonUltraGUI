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
  final image = card.tag == TagType.hf14a4 ? cpuFilesystemFromData(card.data) : null;
  final pairs = card.tag == TagType.hf14a4 && image == null
      ? cpuRulesFromData(card.data) : <CpuApduPair>[];
  final commands = card.tag == TagType.hf14a4
      ? await communicator.getDeviceCapabilities() : <int>[];
  final supported = commands.contains(ChameleonCommand.hf14a4StaticRead.value);
  if (image != null && !commands.contains(ChameleonCommand.hf14a4Filesystem.value)) {
    throw StateError('请先升级配套固件：当前设备缺少 CPU 文件系统命令 6009');
  }
  if (pairs.isNotEmpty && !supported) {
    throw StateError('APDU table upload requires updated ISO-DEP firmware');
  }
  await communicator.setMf1AntiCollision(
    CardData(
      uid: hexToBytes(card.uid),
      atqa: card.atqa,
      sak: card.sak,
      ats: card.ats,
    ),
  );
  if (image != null) {
    await communicator.hf14a4WriteFilesystem(image);
  } else if (supported) {
    await communicator.hf14a4ClearStaticResponses();
    for (final pair in pairs) {
      await communicator.hf14a4AddStaticResponse(pair.command, pair.response);
    }
  }
}

Future<CardSave> readHf14a4SlotIdentity(
  ChameleonCommunicator communicator,
  String name,
) async {
  final data = await communicator.mf1GetAntiCollData();

  final commands = await communicator.getDeviceCapabilities();
  final image = commands.contains(ChameleonCommand.hf14a4Filesystem.value)
      ? await communicator.hf14a4ReadFilesystem() : null;
  final pairs = image == null && commands.contains(ChameleonCommand.hf14a4StaticRead.value)
      ? await communicator.hf14a4ReadStaticResponses() : <CpuApduPair>[];
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
