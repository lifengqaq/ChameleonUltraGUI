import 'dart:typed_data';

import 'package:chameleonultragui/helpers/sm4.dart';
import 'package:pointycastle/export.dart';

/// Explicit card profiles; these are not DESFire mutual auth or EMV cryptograms.
enum CpuAuthMethod { pin, des, tdes, sm4 }

enum CpuPinEncoding { ascii, bcd, iso9564 }

class CpuAuthSettings {
  final CpuAuthMethod method;
  final CpuPinEncoding pinEncoding;
  final CpuSm4Challenge sm4Challenge;
  final int reference, algorithm;
  const CpuAuthSettings({
    this.method = CpuAuthMethod.pin,
    this.pinEncoding = CpuPinEncoding.ascii,
    this.sm4Challenge = CpuSm4Challenge.padded8,
    this.reference = 0,
    this.algorithm = 0,
  });
  String get counterId =>
      '${method == CpuAuthMethod.pin ? 'pin' : 'key'}:$reference';
}

class CpuAuthResult {
  final int status;
  final bool attempted;
  const CpuAuthResult(this.status, {this.attempted = true});
  bool get success => attempted && status == 0x9000;
  int? get remaining =>
      attempted && (status & 0xFFF0) == 0x63C0 ? status & 15 : null;
  bool get blocked => status == 0x6983 || (attempted && remaining == 0);
}

/// Counts only come from a failed VERIFY/EXTERNAL AUTHENTICATE response.
/// No VERIFY-without-data, GET DATA 9F17 or speculative counter commands.
class CpuAuthHistory {
  final Map<String, CpuAuthResult> _results;
  final String _scope;
  CpuAuthHistory() : _results = {}, _scope = '';
  CpuAuthHistory._(this._results, this._scope);
  CpuAuthHistory inDirectory(String directory) =>
      CpuAuthHistory._(_results, directory);

  // For ISO reference bytes, b8 distinguishes the current DF from the global
  // reference. Keep the same retry history across files in a directory.
  String _id(CpuAuthSettings settings) => settings.reference & 0x80 == 0
      ? settings.counterId
      : '$_scope/${settings.counterId}';
  CpuAuthResult? forSettings(CpuAuthSettings settings) =>
      _results[_id(settings)];
  void record(CpuAuthSettings settings, CpuAuthResult result) {
    if (result.attempted || result.blocked) _results[_id(settings)] = result;
  }

  void clear() => _results.clear();
}

Uint8List cpuVerifyData(String pin, CpuPinEncoding encoding) {
  if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
    throw const FormatException('PIN must contain 4–12 decimal digits');
  }
  if (encoding == CpuPinEncoding.ascii)
    return Uint8List.fromList(pin.codeUnits);
  final text =
      (encoding == CpuPinEncoding.iso9564
              ? '2${pin.length.toRadixString(16)}$pin'
              : pin)
          .padRight(16, 'F');
  return Uint8List.fromList([
    for (var i = 0; i < 16; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List cpuAuthKey(String value, CpuAuthMethod method) {
  final text = value.replaceAll(RegExp(r'\s'), '');
  final lengths = switch (method) {
    CpuAuthMethod.des => const [16],
    CpuAuthMethod.tdes => const [32, 48],
    CpuAuthMethod.sm4 => const [32],
    CpuAuthMethod.pin => const <int>[],
  };
  if (!lengths.contains(text.length) ||
      !RegExp(r'^[a-fA-F0-9]+$').hasMatch(text)) {
    throw const FormatException(
      'DES requires 8 bytes; 3DES 16 or 24; SM4 exactly 16',
    );
  }
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List cpuEncryptChallenge(Uint8List key, Uint8List challenge) {
  if (challenge.length != 8 || ![8, 16, 24].contains(key.length)) {
    throw const FormatException(
      'The selected profile requires an 8-byte challenge',
    );
  }
  // Pointy Castle exposes DESedeEngine. EDE with K1 = K2 = K3 is
  // exactly single DES, so the same tested engine handles both profiles.
  final engineKey = key.length == 8
      ? Uint8List.fromList([...key, ...key, ...key])
      : Uint8List.fromList(key);
  final cipher = DESedeEngine();
  try {
    cipher.init(true, KeyParameter(engineKey));
    final result = Uint8List(8);
    cipher.processBlock(challenge, 0, result, 0);
    return result;
  } finally {
    cipher.reset();
    engineKey.fillRange(0, engineKey.length, 0);
  }
}

int cpuAuthStatus(Uint8List response) {
  if (response.length < 2) throw const FormatException('Truncated APDU status');
  return response[response.length - 2] << 8 | response.last;
}

typedef CpuAuthExchange = Future<Uint8List> Function(Uint8List command);

Future<CpuAuthResult> authenticateCpuCard(
  CpuAuthSettings settings,
  String credential,
  CpuAuthExchange exchange,
) async {
  RangeError.checkValueInInterval(settings.reference, 0, 255);
  RangeError.checkValueInInterval(settings.algorithm, 0, 255);
  if (settings.method == CpuAuthMethod.pin) {
    final data = cpuVerifyData(credential, settings.pinEncoding);
    try {
      return CpuAuthResult(
        cpuAuthStatus(
          await exchange(
            Uint8List.fromList([
              0,
              0x20,
              0,
              settings.reference,
              data.length,
              ...data,
            ]),
          ),
        ),
      );
    } finally {
      data.fillRange(0, data.length, 0);
    }
  }
  final key = cpuAuthKey(credential, settings.method);
  final isSm4 = settings.method == CpuAuthMethod.sm4;
  final length = isSm4 ? settings.sm4Challenge.length : 8;
  try {
    final challenge = await exchange(
      Uint8List.fromList([0, 0x84, 0, 0, length]),
    );
    final status = cpuAuthStatus(challenge);
    if (status != 0x9000) return CpuAuthResult(status, attempted: false);
    if (challenge.length != length + 2) {
      throw FormatException('Expected a $length-byte challenge from the card');
    }
    final block = Uint8List(isSm4 ? sm4BlockSize : length)
      ..setRange(0, length, challenge);
    if (isSm4 && length == 8) block[length] = 0x80;
    final answer = isSm4
        ? sm4EncryptBlock(key, block)
        : cpuEncryptChallenge(key, block);
    try {
      return CpuAuthResult(
        cpuAuthStatus(
          await exchange(
            Uint8List.fromList([
              0,
              0x82,
              settings.algorithm,
              settings.reference,
              answer.length,
              ...answer,
            ]),
          ),
        ),
      );
    } finally {
      block.fillRange(0, block.length, 0);
      answer.fillRange(0, answer.length, 0);
    }
  } finally {
    key.fillRange(0, key.length, 0);
  }
}

final Map<String, CpuAuthHistory> _cardAuthHistories = {};
CpuAuthHistory cpuAuthHistoryForCard(List<int> uid, List<int> ats) {
  final key = '${uid.join(',')}:${ats.join(',')}';
  if (!_cardAuthHistories.containsKey(key) && _cardAuthHistories.length >= 64) {
    _cardAuthHistories.remove(_cardAuthHistories.keys.first);
  }
  return _cardAuthHistories.putIfAbsent(key, CpuAuthHistory.new);
}
