import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

Uint8List cpuHex(String text, {int min = 0, int max = 260}) {
  final hex = text.replaceAll(RegExp(r'\s'), '');
  if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex) ||
      hex.length ~/ 2 < min || hex.length ~/ 2 > max) {
    throw FormatException('Expected $min–$max bytes of hexadecimal data');
  }
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

class CpuApduPair {
  final Uint8List command;
  final Uint8List response;
  CpuApduPair(this.command, this.response);
  int get statusWord => response.length < 2
      ? throw const FormatException('APDU response has no status word')
      : (response[response.length - 2] << 8) | response.last;
}

List<CpuApduPair> cpuRulesFromData(List<Uint8List> data) {
  if (data.length.isOdd) throw const FormatException('Unpaired APDU response');
  final pairs = <CpuApduPair>[
    for (var i = 0; i < data.length; i += 2) CpuApduPair(data[i], data[i+1]),
  ];
  validateCpuRules(pairs);
  return pairs;
}

void validateCpuRules(List<CpuApduPair> pairs) {
  var normal = 0, large = 0;
  final commands = <String>{};
  for (final pair in pairs) {
    if (pair.command.isEmpty || pair.command.length > 16 ||
        pair.response.length < 2 || pair.response.length > 260) {
      throw const FormatException('Emulation: command prefix 1–16 B; response 2–260 B');
    }
    if (!commands.add(bytesToHex(pair.command))) {
      throw const FormatException('Duplicate command prefix');
    }
    if (pair.response.length > 253) {large++;} else {normal++;}
  }
  if (normal > 12 || large > 4) {
    throw const FormatException('Emulation capacity: 12 persistent and 4 volatile responses');
  }
}

/// Validate the entire packed card header before accessing any variable field.
(CardData, int) parseCpuIdentity(Uint8List bytes, {int offset = 0}) {
  var i = offset;
  if (i >= bytes.length) throw const FormatException('Missing card identity');
  final uidLength = bytes[i++];
  if (![4, 7, 10].contains(uidLength) || i + uidLength + 4 > bytes.length) {
    throw const FormatException('Truncated card identity');
  }
  final uid = Uint8List.fromList(bytes.sublist(i, i + uidLength)); i += uidLength;
  final atqa = Uint8List.fromList(bytes.sublist(i, i + 2)); i += 2;
  final sak = bytes[i++];
  final atsLength = bytes[i++];
  if ((sak & 0x20) == 0 || atsLength < 2 || i + atsLength > bytes.length ||
      bytes[i] != atsLength || (bytes[i+1] & 0x8F) > 8) {
    throw const FormatException('Invalid ISO-DEP ATS');
  }
  final ats = Uint8List.fromList(bytes.sublist(i, i + atsLength));
  i += atsLength;
  return (CardData(uid: uid, atqa: atqa, sak: sak, ats: ats), i);
}

(CardData, List<CpuApduPair>) parseCpuEmvScan(Uint8List bytes) {
  final (identity, headerSize) = parseCpuIdentity(bytes);
  var i = headerSize;
  if (i >= bytes.length) throw const FormatException('Missing APDU count');
  final count = bytes[i++];
  final pairs = <CpuApduPair>[];
  for (var n = 0; n < count; n++) {
    if (i >= bytes.length) throw const FormatException('Truncated APDU command');
    final commandLength = bytes[i++];
    if (commandLength < 4 || i + commandLength + 2 > bytes.length) {
      throw const FormatException('Invalid APDU command length');
    }
    final command = Uint8List.fromList(bytes.sublist(i, i + commandLength));
    i += commandLength;
    final responseLength = bytes[i] | bytes[i+1] << 8; i += 2;
    if (responseLength < 2 || i + responseLength > bytes.length) {
      throw const FormatException('Truncated APDU response');
    }
    pairs.add(CpuApduPair(command,
        Uint8List.fromList(bytes.sublist(i, i + responseLength))));
    i += responseLength;
  }
  if (i != bytes.length) throw const FormatException('Unexpected trailing scan data');
  return (identity, pairs);
}

/// ISO 7816 procedure bytes are handled at the host, never by repeating a write.
Future<Uint8List> exchangeCpuApdu(Uint8List command,
    Future<Uint8List> Function(Uint8List) transmit, {bool followStatus = true}) async {
  if (command.length < 4 || command.length > 260) {
    throw const FormatException('APDU must be 4–260 bytes');
  }
  var current = Uint8List.fromList(command);
  final result = <int>[];
  for (var step = 0; step < 16; step++) {
    final response = await transmit(current);
    if (response.length < 2) throw const FormatException('APDU response has no status word');
    final sw1 = response[response.length-2], sw2 = response.last;
    // Only case-2 read APDUs have an unambiguous, side-effect-free Le retry.
    if (followStatus && sw1 == 0x6C && current.length == 5 &&
        [0xB0, 0xB2, 0xC0, 0xCA].contains(current[1])) {
      current = Uint8List.fromList([...current.take(4), sw2]);
      continue;
    }
    result.addAll(response.take(response.length - 2));
    if (result.length > 4096) throw const FormatException('GET RESPONSE exceeds 4096 bytes');
    if (!followStatus || sw1 != 0x61) return Uint8List.fromList([...result, sw1, sw2]);
    current = Uint8List.fromList([command[0] & 0xEF, 0xC0, 0, 0, sw2]);
  }
  throw StateError('APDU procedure limit reached');
}

String cpuProfileJson(CardData identity, List<CpuApduPair> pairs, {String name = 'CPU card'}) {
  return const JsonEncoder.withIndent('  ').convert({
    'format': 'chameleon-iso14443-4', 'version': 1, 'name': name,
    'uid': bytesToHex(identity.uid), 'atqa': bytesToHex(identity.atqa),
    'sak': identity.sak.toRadixString(16).padLeft(2, '0'), 'ats': bytesToHex(identity.ats),
    'responses': [for (final pair in pairs)
      {'command': bytesToHex(pair.command), 'response': bytesToHex(pair.response)}],
  });
}

CardSave cpuProfileFromJson(String source) {
  final data = jsonDecode(source) as Map<String, dynamic>;
  if (data['format'] != 'chameleon-iso14443-4' || data['version'] != 1) {
    throw const FormatException('Unsupported CPU card profile');
  }
  final uid = cpuHex(data['uid'] as String, min: 4, max: 10);
  final atqa = cpuHex(data['atqa'] as String, min: 2, max: 2);
  final sak = cpuHex(data['sak'] as String, min: 1, max: 1).first;
  final ats = cpuHex(data['ats'] as String, min: 2, max: 255);
  parseCpuIdentity(Uint8List.fromList([uid.length, ...uid, ...atqa, sak, ats.length, ...ats]));
  final pairs = [for (final item in data['responses'] as List)
    CpuApduPair(cpuHex(item['command'] as String, min: 1, max: 16),
        cpuHex(item['response'] as String, min: 2, max: 260))];
  validateCpuRules(pairs);
  return CardSave(uid: bytesToHexSpace(uid), name: data['name'] as String? ?? 'CPU card',
      tag: TagType.hf14a4, atqa: atqa, sak: sak, ats: ats,
      data: [for (final pair in pairs) ...[pair.command, pair.response]]);
}
