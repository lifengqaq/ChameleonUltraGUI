import 'dart:typed_data';

import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';

int _status(Uint8List response) {
  if (response.length < 2)
    throw const FormatException('Truncated APDU response');
  return response[response.length - 2] << 8 | response.last;
}

typedef CpuDumpAuthenticate = Future<bool> Function();

class CpuDumpCancelled implements Exception {}

class CpuReadFailure implements Exception {
  final int status;
  const CpuReadFailure(this.status);
}

class CpuDumpTarget {
  final List<int> path;
  final Uint8List aid;
  final int type, sfi, firstRecord, lastRecord;
  CpuDumpTarget(
    this.path, {
    List<int> aid = const [],
    this.type = 0,
    this.sfi = 0,
    this.firstRecord = 1,
    this.lastRecord = 254,
  }) : aid = Uint8List.fromList(aid);
  String get label =>
      '${aid.isEmpty ? '' : '${_hex(aid)}:'}${sfi == 0 ? '' : 'SFI $sfi ($firstRecord–$lastRecord)'}${path.map((v) => v.toRadixString(16).padLeft(4, '0')).join('/')}';
}

String _hex(List<int> data) =>
    data.map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
List<CpuDumpTarget> parseCpuDumpPaths(
  String source, {
  List<int> aid = const [],
}) {
  final parts = source
      .split(RegExp(r'[,;\n，；]+'))
      .where((p) => p.trim().isNotEmpty)
      .toList();
  if (parts.isEmpty || parts.length > 64)
    throw const FormatException('Choose 1–64 file paths');
  final seen = <String>{};
  return [
    for (final part in parts)
      (() {
        final text = part.replaceAll(RegExp(r'\s'), '').toUpperCase();
        if (!RegExp(r'^[0-9A-F]{4}(/[0-9A-F]{4})*$').hasMatch(text) ||
            !seen.add(text)) {
          throw const FormatException('Invalid or duplicate FID path');
        }
        final path = text
            .split('/')
            .map((p) => int.parse(p, radix: 16))
            .toList();
        if (path.first == 0x3F00) path.removeAt(0);
        if (path.isEmpty ||
            path.length > 8 ||
            path.any((p) => p == 0 || p == 0x3F00 || p == 0x3FFF)) {
          throw const FormatException('Invalid FID path');
        }
        return CpuDumpTarget(path, aid: aid);
      })(),
  ];
}

/// Bounded BER-TLV lookup for file descriptors, sizes and directory AIDs.
List<Uint8List> cpuFindTlv(
  Uint8List data,
  int wanted, {
  bool recursive = true,
  int depth = 0,
}) {
  if (depth > 8) return [];
  final found = <Uint8List>[];
  var offset = 0;
  while (offset < data.length) {
    final first = data[offset++];
    if (first == 0 || first == 255) continue;
    var tag = first;
    if (first & 31 == 31) {
      var count = 0;
      while (true) {
        if (offset >= data.length || count++ >= 3) return found;
        final b = data[offset++];
        tag = tag << 8 | b;
        if (b & 128 == 0) break;
      }
    }
    if (offset >= data.length) return found;
    var length = data[offset++];
    if (length & 128 != 0) {
      final n = length & 127;
      if (n == 0 || n > 2 || offset + n > data.length) return found;
      length = 0;
      for (var i = 0; i < n; i++) {
        length = length << 8 | data[offset++];
      }
    }
    if (offset + length > data.length) return found;
    final value = Uint8List.fromList(data.sublist(offset, offset + length));
    offset += length;
    if (tag == wanted) found.add(value);
    if (recursive && first & 32 != 0) {
      found.addAll(cpuFindTlv(value, wanted, depth: depth + 1));
    }
  }
  return found;
}

class CpuDumpFile {
  final CpuDumpTarget target;
  final Uint8List data, fci;
  final int type, recordLength;
  final bool complete, authenticationRequired;
  CpuDumpFile(
    this.target,
    this.data,
    this.fci,
    this.type,
    this.recordLength, {
    required this.complete,
    required this.authenticationRequired,
  });
  Map<String, dynamic> toJson() => {
    'path': target.path,
    'aid': _hex(target.aid),
    'sfi': target.sfi,
    'firstRecord': target.firstRecord,
    'lastRecord': target.lastRecord,
    'fileIdKnown': target.path.isNotEmpty,
    'type': type,
    'recordLength': recordLength,
    'data': _hex(data),
    'fci': _hex(fci),
    'complete': complete,
    'authenticationRequired': authenticationRequired,
  };
}

class CpuDumpResult {
  final List<CpuDumpFile> files;
  final List<Map<String, dynamic>> failures;
  bool cancelled = false;
  CpuDumpResult() : files = [], failures = [];
  bool get completeForPlan =>
      files.isNotEmpty &&
      !cancelled &&
      failures.isEmpty &&
      files.every((f) => f.complete);
  Map<String, dynamic> toJson() => {
    'version': 1,
    'files': files.map((f) => f.toJson()).toList(),
    'failures': failures,
    'completeForPlan': completeForPlan,
    'universalComplete': false,
    'cancelled': cancelled,
    'keysExported': false,
  };

  /// Only exact, complete files are put into a device image. Oversized archives
  /// remain in the card library and must never silently upload as UID-only.
  CpuFileSystem? deviceFilesystem() {
    final nodes = <CpuFileNode>[CpuFileNode(parent: 255, type: 0, fid: 0x3F00)];
    final directories = <String, int>{'': 0};
    for (final file in files.where((f) => f.complete)) {
      if (file.target.path.isEmpty && file.target.firstRecord != 1) return null;
      final path = file.target.path.isEmpty
          ? [0x8000 + file.target.sfi]
          : file.target.path;
      var parent = 0, prefix = '';
      if (file.target.aid.isNotEmpty) {
        prefix = 'A:${_hex(file.target.aid)}';
        parent = directories.putIfAbsent(prefix, () {
          final index = nodes.length;
          nodes.add(
            CpuFileNode(
              parent: 0,
              type: 0,
              fid: 0xE000 + index,
              aid: file.target.aid,
              fci: file.target.path.isEmpty ? file.fci : [],
            ),
          );
          return index;
        });
      }
      for (final fid in path.take(path.length - 1)) {
        prefix += '/$fid';
        final parentIndex = parent;
        parent = directories.putIfAbsent(prefix, () {
          final index = nodes.length;
          nodes.add(CpuFileNode(parent: parentIndex, type: 0, fid: fid));
          return index;
        });
      }
      nodes.add(
        CpuFileNode(
          parent: parent,
          type: file.type,
          fid: path.last,
          sfi: file.target.sfi,
          // Do not accidentally make a protected source file public in emulation.
          access: file.authenticationRequired ? 0 : 1,
          recordLength: file.recordLength,
          data: file.data,
        ),
      );
    }
    if (nodes.length == 1) return null;
    try {
      final result = CpuFileSystem(nodes);
      result.encode();
      return result;
    } on FormatException {
      return null;
    }
  }
}

class CpuDumpReader {
  final Future<Uint8List> Function(Uint8List command) exchange;
  final CpuDumpAuthenticate authenticate;
  final int maxBytes;
  bool _authRequired = false, _authenticatedInSession = false;
  CpuDumpReader({
    required this.exchange,
    required this.authenticate,
    this.maxBytes = 65535,
  });
  Future<Uint8List> _read(Uint8List command) async {
    var response = await exchangeCpuApdu(command, exchange, followStatus: true);
    if (_status(response) == 0x6982) {
      _authRequired = true;
      if (!await authenticate()) throw CpuDumpCancelled();
      _authenticatedInSession = true;
      response = await exchangeCpuApdu(command, exchange, followStatus: true);
    }
    return response;
  }

  Future<Uint8List> _select(List<int> command) async {
    var response = await _read(Uint8List.fromList(command));
    if (_status(response) == 0x6A86 && command[3] == 4) {
      final alternate = List<int>.from(command)..[3] = 0;
      response = await _read(Uint8List.fromList(alternate));
    }
    if (_status(response) != 0x9000) throw CpuReadFailure(_status(response));
    return Uint8List.fromList(response.sublist(0, response.length - 2));
  }

  Future<CpuDumpResult> read(List<CpuDumpTarget> targets) async {
    if (targets.isEmpty ||
        targets.length > 64 ||
        maxBytes < 1 ||
        maxBytes > 1048576) {
      throw const FormatException('Invalid dump bounds');
    }
    final result = CpuDumpResult();
    var remaining = maxBytes;
    for (final target in targets) {
      _authRequired = false;
      try {
        if (target.aid.isEmpty) {
          await _select([0, 0xA4, 0, 4, 2, 0x3F, 0]);
        } else {
          await _select([0, 0xA4, 4, 0, target.aid.length, ...target.aid, 0]);
        }
        Uint8List fci = Uint8List(0);
        for (final fid in target.path) {
          fci = await _select([0, 0xA4, 0, 4, 2, fid >> 8, fid & 255]);
        }
        final descriptors = cpuFindTlv(fci, 0x82);
        final descriptor = descriptors.isEmpty
            ? Uint8List(0)
            : descriptors.first;
        final record =
            target.type == 2 ||
            (descriptor.isNotEmpty && [2, 6].contains(descriptor.first & 7));
        var length = 0;
        var lengthKnown = false;
        for (final tag in [0x80, 0x81]) {
          final sizes = cpuFindTlv(fci, tag);
          if (sizes.isNotEmpty &&
              sizes.first.isNotEmpty &&
              sizes.first.length <= 3) {
            lengthKnown = true;
            for (final b in sizes.first) {
              length = length << 8 | b;
            }
            break;
          }
        }
        final bytes = BytesBuilder(copy: false);
        var complete = false, recordLength = 0;
        if (record) {
          if (target.sfi == 0 && descriptor.length >= 5)
            recordLength = descriptor[2] << 8 | descriptor[3];
          final count = target.sfi > 0
              ? target.lastRecord
              : descriptor.length >= 5
              ? descriptor[4]
              : 254;
          for (var n = target.firstRecord; n <= count && n <= 254; n++) {
            final response = await _read(
              Uint8List.fromList([0, 0xB2, n, target.sfi << 3 | 4, 0]),
            );
            final status = _status(response);
            if (status == 0x6A83) {
              complete = target.sfi == 0 && descriptor.length < 5;
              break;
            }
            if (status != 0x9000) throw CpuReadFailure(status);
            final data = response.sublist(0, response.length - 2);
            if (data.isEmpty ||
                (recordLength != 0 && data.length != recordLength)) {
              throw const FormatException('Variable or truncated record file');
            }
            if (data.length > remaining) break;
            recordLength = data.length;
            bytes.add(data);
            remaining -= data.length;
            if (n == count) complete = target.sfi > 0 || descriptor.length >= 5;
          }
        } else {
          var offset = 0;
          while (offset < 32768 && remaining > 0) {
            var count = lengthKnown ? length - offset : 200;
            if (count <= 0) {
              complete = true;
              break;
            }
            if (count > 200) count = 200;
            if (count > remaining) count = remaining;
            final response = await _read(
              Uint8List.fromList([0, 0xB0, offset >> 8, offset & 255, count]),
            );
            final status = _status(response);
            if (status != 0x9000 && status != 0x6282)
              throw CpuReadFailure(status);
            final data = response.sublist(0, response.length - 2);
            if (data.length > count)
              throw const FormatException('Oversized READ response');
            bytes.add(data);
            offset += data.length;
            remaining -= data.length;
            if (status == 0x6282 || data.isEmpty) {
              complete = !lengthKnown || offset == length;
              break;
            }
            if (lengthKnown && offset == length) {
              complete = true;
              break;
            }
          }
        }
        result.files.add(
          CpuDumpFile(
            target,
            bytes.toBytes(),
            fci,
            record ? 2 : 1,
            recordLength,
            complete: complete,
            authenticationRequired: _authRequired || _authenticatedInSession,
          ),
        );
      } on CpuDumpCancelled {
        result.cancelled = true;
        break;
      } on CpuReadFailure catch (error) {
        result.failures.add({'path': target.label, 'status': error.status});
      }
      if (remaining == 0) break;
    }
    if (result.files.length + result.failures.length < targets.length &&
        !result.cancelled) {
      result.failures.add({'reason': 'read_limit_reached'});
    }
    return result;
  }
}

enum CpuEmvReadPlanIssue {
  none,
  noResponses,
  directorySelectionFailed,
  applicationNotSelected,
  applicationSelectionFailed,
  gpoNotAttempted,
  gpoFailed,
  noUsableAfl,
}

const _ppseHex = '325041592E5359532E4444463031';
const _paymentAidPrefixes = [
  'A000000003', // Visa
  'A000000004', // Mastercard
  'A000000025', // American Express
  'A000000065', // JCB
  'A000000152', // Discover / Diners
  'A000000333', // UnionPay / PBOC
];

Uint8List? _selectedName(Uint8List command) {
  if (command.length < 5 || command[1] != 0xA4 || command[2] != 4) {
    return null;
  }
  final length = command[4];
  if (length < 5 || length > 16 || command.length < length + 5) return null;
  return command.sublist(5, 5 + length);
}

bool _isGpo(Uint8List command) =>
    command.length >= 5 &&
    command[0] == 0x80 &&
    command[1] == 0xA8 &&
    command[2] == 0 &&
    command[3] == 0;

/// Build a plan only from GPO responses tied to a successful payment AID
/// selection. A failed directory SELECT alone does not classify the card.
({
  List<CpuDumpTarget> targets,
  CpuEmvReadPlanIssue issue,
  int? failedStatus,
  bool hasEmvFlow,
})
analyzeCpuEmvReadPlan(List<CpuApduPair> capture) {
  var issue = capture.isEmpty
      ? CpuEmvReadPlanIssue.noResponses
      : CpuEmvReadPlanIssue.applicationNotSelected;
  var hasEmvFlow = false;
  Uint8List? selectedAid;
  int? failedStatus;
  final targets = <CpuDumpTarget>[];
  final seen = <String>{};

  for (final pair in capture) {
    final selection = _selectedName(pair.command);
    if (selection != null) {
      final name = _hex(selection);
      final status = pair.statusWord;
      selectedAid = null;
      failedStatus = null;
      if (name == _ppseHex && status != 0x9000) {
        issue = CpuEmvReadPlanIssue.directorySelectionFailed;
        failedStatus = status;
      } else if (_paymentAidPrefixes.any(name.startsWith)) {
        if (status == 0x9000) {
          selectedAid = selection;
          issue = CpuEmvReadPlanIssue.gpoNotAttempted;
        } else {
          issue = CpuEmvReadPlanIssue.applicationSelectionFailed;
          failedStatus = status;
        }
      } else {
        issue = CpuEmvReadPlanIssue.applicationNotSelected;
      }
      continue;
    }
    final aid = selectedAid;
    if (aid == null || !_isGpo(pair.command)) continue;
    hasEmvFlow = true;
    final status = pair.statusWord;
    if (status != 0x9000) {
      issue = CpuEmvReadPlanIssue.gpoFailed;
      failedStatus = status;
      continue;
    }

    issue = CpuEmvReadPlanIssue.noUsableAfl;
    failedStatus = null;
    final data = pair.response.sublist(0, pair.response.length - 2);
    final format2 = cpuFindTlv(data, 0x94);
    final format1 = format2.isEmpty ? cpuFindTlv(data, 0x80) : <Uint8List>[];
    final afl = format2.isNotEmpty
        ? format2.first
        : format1.isNotEmpty && format1.first.length >= 2
        ? format1.first.sublist(2)
        : Uint8List(0);
    if (afl.length % 4 != 0 || afl.length > 252) continue;
    for (var offset = 0; offset < afl.length; offset += 4) {
      final sfi = afl[offset] >> 3;
      final first = afl[offset + 1];
      final last = afl[offset + 2];
      if (afl[offset] & 7 != 0 ||
          sfi < 1 ||
          sfi > 30 ||
          first < 1 ||
          last < first ||
          last > 254) {
        continue;
      }
      if (seen.add('${_hex(aid)}:$sfi:$first:$last')) {
        targets.add(
          CpuDumpTarget(
            [],
            aid: aid,
            type: 2,
            sfi: sfi,
            firstRecord: first,
            lastRecord: last,
          ),
        );
      }
    }
  }
  return (
    targets: targets,
    issue: targets.isEmpty ? issue : CpuEmvReadPlanIssue.none,
    failedStatus: targets.isEmpty ? failedStatus : null,
    hasEmvFlow: hasEmvFlow,
  );
}

List<CpuDumpTarget> cpuEmvReadTargets(List<CpuApduPair> capture) =>
    analyzeCpuEmvReadPlan(capture).targets;
