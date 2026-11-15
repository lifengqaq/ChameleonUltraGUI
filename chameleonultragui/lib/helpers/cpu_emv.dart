import 'dart:typed_data';

import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';

enum CpuEmvStepKind { directory, application, processing, record, other }

enum CpuStatusMeaning {
  success,
  parameters,
  instruction,
  notFound,
  authentication,
  conditions,
  length,
  other,
}

CpuStatusMeaning cpuStatusMeaning(int status) => switch (status) {
  0x9000 => CpuStatusMeaning.success,
  0x6A86 || 0x6B00 => CpuStatusMeaning.parameters,
  0x6D00 => CpuStatusMeaning.instruction,
  0x6A82 || 0x6A83 => CpuStatusMeaning.notFound,
  0x6982 => CpuStatusMeaning.authentication,
  0x6985 => CpuStatusMeaning.conditions,
  0x6700 => CpuStatusMeaning.length,
  _ => CpuStatusMeaning.other,
};

class CpuEmvStep {
  final CpuEmvStepKind kind;
  final int status;
  final bool malformedData;
  const CpuEmvStep(this.kind, this.status, {this.malformedData = false});
}

/// Display data only. The account number and transaction cryptogram are not
/// retained here; callers can inspect the original APDU separately.
class CpuEmvSummary {
  final String? applicationLabel;
  final String? aid;
  final String? maskedPan;
  final String? expiry;
  final String? cardholder;
  final int? transactionCounter;
  final List<CpuEmvStep> steps;
  final bool gpoReturnedData;
  final bool hasAfl;

  const CpuEmvSummary({
    this.applicationLabel,
    this.aid,
    this.maskedPan,
    this.expiry,
    this.cardholder,
    this.transactionCounter,
    required this.steps,
    this.gpoReturnedData = false,
    this.hasAfl = false,
  });

  bool get hasCardError => steps.any((step) => step.status != 0x9000);
  bool get hasMalformedData => steps.any((step) => step.malformedData);
}

class _EmvTlv {
  final int tag;
  final Uint8List value;
  const _EmvTlv(this.tag, this.value);
}

List<_EmvTlv> _tlvs(Uint8List bytes, [int depth = 0]) {
  if (depth > 8) throw const FormatException('EMV TLV nesting limit');
  final result = <_EmvTlv>[];
  var offset = 0;
  while (offset < bytes.length) {
    final first = bytes[offset++];
    if (first == 0 || first == 0xFF) continue; // EMV padding.
    var tag = first;
    if ((first & 0x1F) == 0x1F) {
      var complete = false;
      for (var n = 0; n < 2; n++) {
        if (offset >= bytes.length) {
          throw const FormatException('Truncated EMV tag');
        }
        final next = bytes[offset++];
        tag = tag << 8 | next;
        if ((next & 0x80) == 0) {
          complete = true;
          break;
        }
      }
      if (!complete) throw const FormatException('EMV tag length limit');
    }
    if (offset >= bytes.length) {
      throw const FormatException('Missing EMV length');
    }
    var length = bytes[offset++];
    if ((length & 0x80) != 0) {
      final count = length & 0x7F;
      if (count == 0 || count > 2 || offset + count > bytes.length) {
        throw const FormatException('Invalid EMV length');
      }
      length = 0;
      for (var n = 0; n < count; n++) {
        length = length << 8 | bytes[offset++];
      }
    }
    if (offset + length > bytes.length) {
      throw const FormatException('Truncated EMV value');
    }
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length));
    offset += length;
    result.add(_EmvTlv(tag, value));
    if ((first & 0x20) != 0) result.addAll(_tlvs(value, depth + 1));
  }
  return result;
}

String? _text(Uint8List? value) {
  if (value == null || value.any((byte) => byte < 0x20 || byte > 0x7E)) {
    return null;
  }
  final text = String.fromCharCodes(value).trim();
  return text.isEmpty ? null : text;
}

String? _expiry(String? value) {
  if (value == null || !RegExp(r'^\d{4}$').hasMatch(value)) return null;
  final month = int.parse(value.substring(2));
  if (month < 1 || month > 12) return null;
  return '${value.substring(2)}/${value.substring(0, 2)}';
}

CpuEmvStepKind _kind(Uint8List command) {
  if (command.length < 4) return CpuEmvStepKind.other;
  if (command[1] == 0xA4 && command[2] == 4 && command.length >= 5) {
    final length = command[4];
    if (command.length < 5 + length) return CpuEmvStepKind.other;
    final name = String.fromCharCodes(command.sublist(5, 5 + length));
    return name == '2PAY.SYS.DDF01'
        ? CpuEmvStepKind.directory
        : CpuEmvStepKind.application;
  }
  if (command[1] == 0xA8) return CpuEmvStepKind.processing;
  if (command[1] == 0xB2) return CpuEmvStepKind.record;
  return CpuEmvStepKind.other;
}

/// Interpret only well-formed, successful responses. An invalid response is
/// marked on its own step, preserving usable earlier results and the raw log.
CpuEmvSummary summarizeCpuEmv(List<CpuApduPair> pairs) {
  final fields = <int, Uint8List>{};
  final steps = <CpuEmvStep>[];
  String? selectedAid;
  var gpoReturnedData = false;
  var hasAfl = false;
  for (final pair in pairs) {
    final kind = _kind(pair.command);
    final status = pair.statusWord;
    var malformed = false;
    if (status == 0x9000) {
      if (kind == CpuEmvStepKind.application) {
        final length = pair.command[4];
        selectedAid = bytesToHex(pair.command.sublist(5, 5 + length));
        // Directory labels describe candidates, not necessarily this selection.
        fields.remove(0x50);
        fields.remove(0x9F12);
      }
      final data = Uint8List.fromList(
        pair.response.take(pair.response.length - 2).toList(),
      );
      try {
        final parsed = _tlvs(data);
        for (final field in parsed) {
          if (field.tag == 0x94 && field.value.length % 4 != 0) {
            throw const FormatException('Invalid application file locator');
          }
        }
        if (kind == CpuEmvStepKind.processing) {
          final formatOne = parsed.where((field) => field.tag == 0x80);
          if (formatOne.isNotEmpty) {
            final value = formatOne.first.value;
            if (value.length < 2 || (value.length - 2) % 4 != 0) {
              throw const FormatException('Invalid GPO format 1');
            }
            hasAfl = value.length > 2;
          }
          gpoReturnedData = data.isNotEmpty;
        }
        for (final field in parsed) {
          fields[field.tag] = field.value;
          if (field.tag == 0x94 && field.value.isNotEmpty) {
            hasAfl = true;
          }
        }
      } on FormatException {
        malformed = true;
      }
    }
    steps.add(CpuEmvStep(kind, status, malformedData: malformed));
  }
  final trackBytes = fields[0x57];
  final track = trackBytes == null ? '' : bytesToHex(trackBytes).toUpperCase();
  final separator = track.indexOf('D');
  final panBytes = fields[0x5A];
  final pan = panBytes != null
      ? bytesToHex(panBytes).replaceFirst(RegExp(r'[fF]+$'), '')
      : separator > 0
          ? track.substring(0, separator)
          : '';
  final validPan = RegExp(r'^\d{12,19}$').hasMatch(pan);
  final expiryBytes = fields[0x5F24];
  final expiryValue = expiryBytes != null && expiryBytes.length == 3
      ? bytesToHex(expiryBytes).substring(0, 4)
      : separator >= 0 && track.length >= separator + 5
          ? track.substring(separator + 1, separator + 5)
          : null;
  final counter = fields[0x9F36];
  final aidBytes = fields[0x4F];
  return CpuEmvSummary(
    applicationLabel: _text(fields[0x50]) ?? _text(fields[0x9F12]),
    aid: selectedAid ?? (aidBytes == null ? null : bytesToHex(aidBytes)),
    maskedPan: validPan
        ? '${pan.substring(0, 6)} ${''.padLeft(pan.length - 10, '•')} ${pan.substring(pan.length - 4)}'
        : null,
    expiry: _expiry(expiryValue),
    cardholder: _text(fields[0x5F20]),
    transactionCounter: counter != null && counter.length == 2
        ? counter[0] << 8 | counter[1]
        : null,
    steps: List.unmodifiable(steps),
    gpoReturnedData: gpoReturnedData,
    hasAfl: hasAfl,
  );
}
