import 'dart:typed_data';

import 'package:chameleonultragui/helpers/sm4.dart';

class CpuSecurity {
  final String pin;
  final Uint8List key;
  final CpuSm4Challenge? sm4Challenge;
  final int pinReference, keyReference, algorithm, pinEncoding;
  final int pinTries, keyTries, pinRemaining, keyRemaining;
  CpuSecurity({
    this.pin = '000000',
    List<int> key = const [],
    this.sm4Challenge,
    this.pinReference = 0,
    this.keyReference = 0,
    this.algorithm = 0,
    this.pinEncoding = 0,
    this.pinTries = 3,
    this.keyTries = 3,
    int? pinRemaining,
    int? keyRemaining,
  }) : key = Uint8List.fromList(key),
       pinRemaining = pinRemaining ?? (pin.isEmpty ? 0 : pinTries),
       keyRemaining = keyRemaining ?? (key.isEmpty ? 0 : keyTries);

  void validate({bool requireSingleMethod = true}) {
    if ((pin.isNotEmpty && !RegExp(r'^\d{4,12}$').hasMatch(pin)) ||
        ![0, 8, 16].contains(key.length) ||
        (sm4Challenge != null &&
            (pin.isNotEmpty || key.length != sm4BlockSize)) ||
        (pin.isEmpty && key.isEmpty) ||
        (requireSingleMethod && pin.isNotEmpty && key.isNotEmpty) ||
        [pinReference, keyReference, algorithm].any((v) => v < 0 || v > 255) ||
        pinEncoding < 0 ||
        pinEncoding > 2 ||
        (pin.isNotEmpty &&
            (pinTries < 1 ||
                pinTries > 15 ||
                pinRemaining < 0 ||
                pinRemaining > pinTries)) ||
        (key.isNotEmpty &&
            (keyTries < 1 ||
                keyTries > 15 ||
                keyRemaining < 0 ||
                keyRemaining > keyTries))) {
      throw const FormatException('Invalid CPU PIN/key security configuration');
    }
  }

  Uint8List encode() => _encode(allowLegacyMixedAuthentication: false);

  /// Reads legacy mixed-mode profiles for explicit user migration only.
  Uint8List encodeForLegacyValidation() =>
      _encode(allowLegacyMixedAuthentication: true);

  Uint8List _encode({required bool allowLegacyMixedAuthentication}) {
    validate(requireSingleMethod: !allowLegacyMixedAuthentication);
    final data = Uint8List(44)..fillRange(12, 40, 255);
    data.setRange(0, 4, 'SEC1'.codeUnits);
    data[4] = pinReference;
    data[5] = keyReference;
    data[6] = pin.isEmpty ? 0 : pinTries;
    data[7] = key.isEmpty ? 0 : keyTries;
    data[8] = pin.isEmpty ? 0 : pinRemaining;
    data[9] = key.isEmpty ? 0 : keyRemaining;
    data[10] = pin.length;
    data[11] = key.length;
    data.setRange(12, 12 + pin.length, pin.codeUnits);
    data.setRange(24, 24 + key.length, key);
    data[40] = pinEncoding;
    data[41] = algorithm;
    data[42] = sm4Challenge?.wireCode ?? 0;
    return data;
  }

  factory CpuSecurity.decode(Uint8List data, {bool sm4 = false}) {
    if (data.length != 44 ||
        String.fromCharCodes(data.take(4)) != 'SEC1' ||
        data[10] > 12 ||
        ![0, 8, 16].contains(data[11]) ||
        (sm4
            ? !CpuSm4Challenge.values.any((v) => v.wireCode == data[42])
            : data[42] != 0) ||
        data[43] != 0 ||
        (data[10] == 0 && (data[6] != 0 || data[8] != 0)) ||
        (data[11] == 0 && (data[7] != 0 || data[9] != 0))) {
      throw const FormatException('Invalid SEC1 trailer');
    }
    final result = CpuSecurity(
      pin: String.fromCharCodes(data.sublist(12, 12 + data[10])),
      key: data.sublist(24, 24 + data[11]),
      sm4Challenge: sm4
          ? CpuSm4Challenge.values.firstWhere((v) => v.wireCode == data[42])
          : null,
      pinReference: data[4],
      keyReference: data[5],
      pinTries: data[6],
      keyTries: data[7],
      pinRemaining: data[8],
      keyRemaining: data[9],
      pinEncoding: data[40],
      algorithm: data[41],
    );
    result.validate(requireSingleMethod: false);
    return result;
  }
  Map<String, dynamic> toJson() => {
    'pin': pin,
    'key': key
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase(),
    'pinReference': pinReference,
    'keyReference': keyReference,
    'algorithm': algorithm,
    if (sm4Challenge != null) 'sm4Challenge': sm4Challenge!.name,
    'pinEncoding': pinEncoding,
    'pinTries': pinTries,
    'keyTries': keyTries,
    'pinRemaining': pinRemaining,
    'keyRemaining': keyRemaining,
  };
  factory CpuSecurity.fromJson(Map<String, dynamic> value) {
    final text = value['key'] ?? '';
    if (text is! String ||
        !RegExp(r'^(?:[a-fA-F0-9]{16}|[a-fA-F0-9]{32})?$').hasMatch(text)) {
      throw const FormatException('Invalid DES / 2-key 3DES / SM4 key');
    }
    int number(String key, int fallback) {
      final result = value[key] ?? fallback;
      if (result is! int)
        throw const FormatException('Expected security integer');
      return result;
    }

    final pin = value['pin'] ?? '';
    if (pin is! String) throw const FormatException('Expected decimal PIN');
    final layout = value['sm4Challenge'];
    final sm4Challenge = CpuSm4Challenge.values
        .where((v) => v.name == layout)
        .firstOrNull;
    if (layout != null && sm4Challenge == null) {
      throw const FormatException('Unknown SM4 challenge format');
    }
    final result = CpuSecurity(
      pin: pin,
      sm4Challenge: sm4Challenge,
      key: [
        for (var i = 0; i < text.length; i += 2)
          int.parse(text.substring(i, i + 2), radix: 16),
      ],
      pinReference: number('pinReference', 0),
      keyReference: number('keyReference', 0),
      algorithm: number('algorithm', 0),
      pinEncoding: number('pinEncoding', 0),
      pinTries: number('pinTries', 3),
      keyTries: number('keyTries', 3),
      pinRemaining: number(
        'pinRemaining',
        pin.isEmpty ? 0 : number('pinTries', 3),
      ),
      keyRemaining: number(
        'keyRemaining',
        text.isEmpty ? 0 : number('keyTries', 3),
      ),
    );
    result.encode();
    return result;
  }
}
