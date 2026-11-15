import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// Explicit card profiles; these are not DESFire mutual auth or EMV cryptograms.
enum CpuAuthMethod { pin, des, tdes }
enum CpuPinEncoding { ascii, bcd, iso9564 }

class CpuAuthSettings {
  final CpuAuthMethod method;
  final CpuPinEncoding pinEncoding;
  final int reference, algorithm;
  const CpuAuthSettings({this.method = CpuAuthMethod.pin,
    this.pinEncoding = CpuPinEncoding.ascii, this.reference = 0, this.algorithm = 0});
  String get counterId => '${method == CpuAuthMethod.pin ? 'pin' : 'key'}:$reference';
}

class CpuAuthResult {
  final int status;
  final bool attempted;
  const CpuAuthResult(this.status, {this.attempted = true});
  bool get success => attempted && status == 0x9000;
  int? get remaining => attempted && (status & 0xFFF0) == 0x63C0 ? status & 15 : null;
  bool get blocked => status == 0x6983 || (attempted && remaining == 0);
}

/// Counts only come from a failed VERIFY/EXTERNAL AUTHENTICATE response.
/// No VERIFY-without-data, GET DATA 9F17 or speculative counter commands.
class CpuAuthHistory {
  final Map<String, CpuAuthResult> _results = {};
  CpuAuthResult? forSettings(CpuAuthSettings settings) => _results[settings.counterId];
  void record(CpuAuthSettings settings, CpuAuthResult result) {
    if (result.attempted) _results[settings.counterId] = result;
  }
  void clear() => _results.clear();
}

Uint8List cpuVerifyData(String pin, CpuPinEncoding encoding) {
  if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
    throw const FormatException('PIN must contain 4–12 decimal digits');
  }
  if (encoding == CpuPinEncoding.ascii) return Uint8List.fromList(pin.codeUnits);
  final text = (encoding == CpuPinEncoding.iso9564
    ? '2${pin.length.toRadixString(16)}$pin' : pin).padRight(16, 'F');
  return Uint8List.fromList([for (var i = 0; i < 16; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16)]);
}

Uint8List cpuAuthKey(String value, CpuAuthMethod method) {
  final text = value.replaceAll(RegExp(r'\s'), '');
  final lengths = method == CpuAuthMethod.des ? [16] : [32, 48];
  if (!lengths.contains(text.length) || !RegExp(r'^[a-fA-F0-9]+$').hasMatch(text)) {
    throw const FormatException('DES requires 8 bytes; 3DES requires 16 or 24 bytes');
  }
  return Uint8List.fromList([for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16)]);
}

Uint8List cpuEncryptChallenge(Uint8List key, Uint8List challenge) {
  if (challenge.length != 8 || ![8, 16, 24].contains(key.length)) {
    throw const FormatException('The selected profile requires an 8-byte challenge');
  }
  final BlockCipher cipher = key.length == 8 ? DESEngine() : DESedeEngine();
  cipher.init(true, KeyParameter(key));
  final result = Uint8List(8);
  cipher.processBlock(challenge, 0, result, 0);
  return result;
}

int cpuAuthStatus(Uint8List response) {
  if (response.length < 2) throw const FormatException('Truncated APDU status');
  return response[response.length - 2] << 8 | response.last;
}

typedef CpuAuthExchange = Future<Uint8List> Function(Uint8List command);
Future<CpuAuthResult> authenticateCpuCard(CpuAuthSettings settings,
    String credential, CpuAuthExchange exchange) async {
  RangeError.checkValueInInterval(settings.reference, 0, 255);
  RangeError.checkValueInInterval(settings.algorithm, 0, 255);
  if (settings.method == CpuAuthMethod.pin) {
    final data = cpuVerifyData(credential, settings.pinEncoding);
    try {
      return CpuAuthResult(cpuAuthStatus(await exchange(Uint8List.fromList([
        0, 0x20, 0, settings.reference, data.length, ...data,
      ]))));
    } finally { data.fillRange(0, data.length, 0); }
  }
  final key = cpuAuthKey(credential, settings.method);
  try {
    final challenge = await exchange(Uint8List.fromList([0, 0x84, 0, 0, 8]));
    final status = cpuAuthStatus(challenge);
    if (status != 0x9000) return CpuAuthResult(status, attempted: false);
    final answer = cpuEncryptChallenge(key, Uint8List.fromList(challenge.sublist(0, challenge.length - 2)));
    try {
      return CpuAuthResult(cpuAuthStatus(await exchange(Uint8List.fromList([
        0, 0x82, settings.algorithm, settings.reference, answer.length, ...answer,
      ]))));
    } finally { answer.fillRange(0, answer.length, 0); }
  } finally { key.fillRange(0, key.length, 0); }
}
final Map<String, CpuAuthHistory> _cardAuthHistories = {};
CpuAuthHistory cpuAuthHistoryForCard(List<int> uid, List<int> ats) {
  final key = '${uid.join(',')}:${ats.join(',')}';
  if (!_cardAuthHistories.containsKey(key) && _cardAuthHistories.length >= 64) {
    _cardAuthHistories.remove(_cardAuthHistories.keys.first);
  }
  return _cardAuthHistories.putIfAbsent(key, CpuAuthHistory.new);
}
