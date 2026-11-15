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
  final pairs = card.tag == TagType.hf14a4
      ? cpuRulesFromData(card.data)
      : <CpuApduPair>[];
  final supported = card.tag == TagType.hf14a4 &&
      (await communicator.getDeviceCapabilities()).contains(
    ChameleonCommand.hf14a4StaticRead.value,
  );
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
  if (supported) {
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

  final supported = (await communicator.getDeviceCapabilities()).contains(
    ChameleonCommand.hf14a4StaticRead.value,
  );
  final pairs = supported
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
      for (final pair in pairs) ...[pair.command, pair.response],
    ],
  );
}
