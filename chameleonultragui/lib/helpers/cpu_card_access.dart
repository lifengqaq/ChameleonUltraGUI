import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_dump.dart' show cpuFindTlv;
import 'package:chameleonultragui/helpers/iso14443_4.dart';

enum CpuLiveFileKind { directory, binary, record, unknown }

class CpuFileStatus implements Exception {
  final int word;
  const CpuFileStatus(this.word);
}

class CpuFileReply {
  final Uint8List data;
  final int status;
  CpuFileReply(Uint8List response)
    : status = response[response.length - 2] << 8 | response.last,
      data = response.sublist(0, response.length - 2);
}

class CpuLiveFile {
  final int? fid, size, recordLength, recordCount;
  final Uint8List? aid;
  final Uint8List control;
  final CpuLiveFileKind kind;
  final bool canChange;

  bool get isDirectory => kind == CpuLiveFileKind.directory;
  bool get supportsBinary =>
      kind == CpuLiveFileKind.binary || kind == CpuLiveFileKind.unknown;
  bool get supportsRecords =>
      kind == CpuLiveFileKind.record || kind == CpuLiveFileKind.unknown;

  CpuLiveFile._(
    this.control,
    this.kind,
    this.fid,
    this.aid,
    this.size,
    this.recordLength,
    this.recordCount,
    this.canChange,
  );

  factory CpuLiveFile.fromSelect(
    Uint8List control, {
    required bool directory,
    required bool typedSelection,
    int? fid,
    Uint8List? aid,
  }) {
    Uint8List? firstField(Uint8List? data, int tag) => data == null
        ? null
        : cpuFindTlv(data, tag, recursive: false).firstOrNull;
    final fci = firstField(control, 0x6F);
    final params = firstField(control, 0x62) ?? firstField(fci, 0x62) ?? fci;
    Uint8List? field(int tag) => firstField(params, tag);
    final descriptor = field(0x82);
    final flags = descriptor?.firstOrNull;
    final kind = flags == null || flags & 0x80 != 0
        ? null
        : flags & 0x38 == 0x38
        ? CpuLiveFileKind.directory
        : switch (flags & 7) {
            1 => CpuLiveFileKind.binary,
            >= 2 => CpuLiveFileKind.record,
            _ => null,
          };
    final actualFid = field(0x83);
    final id = actualFid?.length == 2 ? _cpuFileInt(actualFid!) : null;
    final name = firstField(fci, 0x84) ?? field(0x84);
    final dfName = name != null && name.length >= 5 && name.length <= 16
        ? name
        : null;
    if ((kind != null && directory != (kind == CpuLiveFileKind.directory)) ||
        (id != null && fid != null && id != fid) ||
        (aid != null && dfName != null && !_cpuBytesEqual(aid, dfName))) {
      throw const FormatException('SELECT returned a different file');
    }
    final length = field(0x80);
    final size = length != null && length.isNotEmpty && length.length <= 4
        ? _cpuFileInt(length)
        : null;
    final recordLength =
        kind == CpuLiveFileKind.record && descriptor!.length >= 4
        ? _cpuFileInt(descriptor.sublist(2, 4))
        : null;
    final count =
        recordLength != null &&
            descriptor!.length >= 5 &&
            descriptor.length <= 6
        ? _cpuFileInt(descriptor.sublist(4))
        : null;
    return CpuLiveFile._(
      control,
      kind ?? (directory ? CpuLiveFileKind.directory : CpuLiveFileKind.unknown),
      id ?? fid,
      directory ? dfName ?? aid : null,
      size,
      recordLength == 0 ? null : recordLength,
      count,
      typedSelection || kind != null,
    );
  }
}

int _cpuFileInt(Iterable<int> data) =>
    data.fold(0, (value, byte) => value << 8 | byte);
bool _cpuBytesEqual(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
List<int> _fid(int id) {
  RangeError.checkValueInInterval(id, 0, 0xFFFF, 'FID');
  return [id >> 8, id & 255];
}

class CpuDirectoryApplication {
  final Uint8List aid;
  final String label;
  CpuDirectoryApplication(this.aid, this.label);
}

/// ISO 7816 file operations on one already selected RF session, basic channel.
class CpuCardAccess {
  final Future<Uint8List> Function(Uint8List) exchange;
  CpuCardAccess(this.exchange);

  Future<CpuFileReply> _send(List<int> apdu, {bool reading = false}) async {
    // Follow GET RESPONSE when needed; this never repeats a write or VERIFY.
    final response = CpuFileReply(
      await exchangeCpuApdu(Uint8List.fromList(apdu), exchange),
    );
    if (response.status != 0x9000 && !(reading && response.status == 0x6282)) {
      throw CpuFileStatus(response.status);
    }
    return response;
  }

  Future<CpuLiveFile> _select(
    int mode,
    List<int> name, {
    required bool directory,
    bool typedSelection = true,
    int? fid,
    Uint8List? aid,
  }) async {
    final command = [
      0x00,
      0xA4,
      mode,
      0x00,
      if (name.isNotEmpty) ...[name.length, ...name],
    ];
    CpuFileReply response;
    try {
      response = await _send([...command, 0]);
    } on CpuFileStatus catch (error) {
      if (error.word != 0x6700) rethrow;
      response = await _send(command);
    }
    return CpuLiveFile.fromSelect(
      response.data,
      directory: directory,
      typedSelection: typedSelection,
      fid: fid,
      aid: aid,
    );
  }

  Future<CpuLiveFile> selectMaster() =>
      _select(0x00, _fid(0x3F00), directory: true, fid: 0x3F00);
  Future<CpuLiveFile> selectParent() =>
      _select(0x03, const [], directory: true);
  Future<CpuLiveFile> selectAid(Uint8List aid) {
    RangeError.checkValueInInterval(aid.length, 5, 16, 'AID length');
    return _select(0x04, aid, directory: true, aid: aid);
  }

  Future<CpuLiveFile> selectFile(int fid, {required bool directory}) async {
    final id = _fid(fid);
    try {
      return await _select(
        directory ? 0x01 : 0x02,
        id,
        directory: directory,
        fid: fid,
      );
    } on CpuFileStatus catch (error) {
      if (error.word != 0x6A86 && error.word != 0x6A81) rethrow;
      // Some cards only support generic FID selection. Without a descriptor
      // it cannot establish the file type needed to enable changes.
      return _select(
        0x00,
        id,
        directory: directory,
        typedSelection: false,
        fid: fid,
      );
    }
  }

  Future<CpuLiveFile> selectPath(List<int> path, {required bool directory}) {
    RangeError.checkValueInInterval(path.length, 1, 16, 'Path length');
    return _select(
      0x08,
      [for (final id in path) ..._fid(id)],
      directory: directory,
      typedSelection: false,
      fid: path.last,
    );
  }

  Future<CpuFileReply> readBinary(int offset, int length) {
    _binaryBounds(offset, length, 256);
    return _send([
      0x00,
      0xB0,
      offset >> 8,
      offset & 255,
      length & 255,
    ], reading: true);
  }

  Future<CpuFileReply> updateBinary(int offset, Uint8List data) {
    _binaryBounds(offset, data.length, 255);
    return _send([0x00, 0xD6, offset >> 8, offset & 255, data.length, ...data]);
  }

  void _binaryBounds(int offset, int length, int limit) {
    RangeError.checkValueInInterval(offset, 0, 0x7FFF, 'Offset');
    RangeError.checkValueInInterval(
      length,
      1,
      math.min(limit, 0x8000 - offset),
      'Length',
    );
  }

  Future<CpuFileReply> readRecord(int number, int length) {
    RangeError.checkValueInInterval(number, 1, 254, 'Record');
    RangeError.checkValueInInterval(length, 1, 256, 'Length');
    return _send([0x00, 0xB2, number, 0x04, length & 255], reading: true);
  }

  Future<CpuFileReply> updateRecord(int number, Uint8List data) {
    RangeError.checkValueInInterval(number, 1, 254, 'Record');
    RangeError.checkValueInInterval(data.length, 1, 255, 'Length');
    return _send([0x00, 0xDC, number, 0x04, data.length, ...data]);
  }

  Future<CpuFileReply> createFile(
    int fid,
    CpuLiveFileKind kind, {
    int? size,
    int? recordLength,
    int? recordCount,
    Uint8List? aid,
  }) {
    if (fid == 0 || fid == 0x3F00 || fid == 0x3FFF || fid == 0xFFFF) {
      throw ArgumentError.value(fid, 'FID');
    }
    final id = _fid(fid);
    final descriptor = switch (kind) {
      CpuLiveFileKind.directory => [0x38, 0x21],
      CpuLiveFileKind.binary => [0x01, 0x21],
      CpuLiveFileKind.record => [
        0x02,
        0x21,
        0,
        RangeError.checkValueInInterval(recordLength!, 1, 255, 'Record length'),
        RangeError.checkValueInInterval(recordCount!, 1, 254, 'Records'),
      ],
      CpuLiveFileKind.unknown => throw ArgumentError.value(kind, 'Kind'),
    };
    if (kind == CpuLiveFileKind.binary) {
      RangeError.checkValueInInterval(size!, 1, 0x8000, 'File size');
    } else if (kind == CpuLiveFileKind.record) {
      size = recordLength! * recordCount!;
    }
    if (aid != null)
      RangeError.checkValueInInterval(aid.length, 5, 16, 'DF name');
    final params = [
      0x82,
      descriptor.length,
      ...descriptor,
      0x83,
      2,
      ...id,
      if (kind != CpuLiveFileKind.directory) ...[
        0x80,
        2,
        size! >> 8,
        size & 255,
      ],
      if (kind == CpuLiveFileKind.directory && aid != null) ...[
        0x84,
        aid.length,
        ...aid,
      ],
    ];
    return _send([
      0x00,
      0xE0,
      0x00,
      0x00,
      params.length + 2,
      0x62,
      params.length,
      ...params,
    ]);
  }

  Future<CpuFileReply> deleteFile(int fid) {
    if (fid == 0 || fid == 0x3F00 || fid == 0x3FFF || fid == 0xFFFF) {
      throw ArgumentError.value(fid, 'FID');
    }
    return _send([0x00, 0xE4, 0x00, 0x00, 2, ..._fid(fid)]);
  }

  /// Read only the published application directory. EF.DIR is optional and
  /// does not enumerate private files in a DF. Reading leaves EF.DIR selected.
  Future<List<CpuDirectoryApplication>> readApplications() async {
    await selectMaster();
    final directory = await selectFile(0x2F00, directory: false);
    final records = <Uint8List>[];
    if (directory.kind == CpuLiveFileKind.binary) {
      records.add(await _readDirectoryBinary(directory.size));
    } else {
      final count = math.min(directory.recordCount ?? 32, 32);
      for (var number = 1; number <= count; number++) {
        try {
          final reply = await readRecord(number, 256);
          if (reply.data.isEmpty) break;
          records.add(reply.data);
          if (reply.status == 0x6282) break;
        } on CpuFileStatus catch (error) {
          if (error.word == 0x6A83) break;
          if (error.word != 0x6981 ||
              number != 1 ||
              directory.kind != CpuLiveFileKind.unknown)
            rethrow;
          records.add(await _readDirectoryBinary(directory.size));
          break;
        }
      }
    }
    final applications = <String, CpuDirectoryApplication>{};
    for (final record in records) {
      for (final template in cpuFindTlv(record, 0x61)) {
        final aid = cpuFindTlv(template, 0x4F).firstOrNull;
        if (aid == null || aid.length < 5 || aid.length > 16) continue;
        final label = utf8
            .decode(
              cpuFindTlv(template, 0x50).firstOrNull ?? const [],
              allowMalformed: true,
            )
            .replaceAll(
              RegExp(r'[\x00-\x1F\x7F\u202A-\u202E\u2066-\u2069]'),
              '',
            )
            .trim();
        applications.putIfAbsent(
          aid.join('.'),
          () => CpuDirectoryApplication(aid, label),
        );
        if (applications.length == 32) return applications.values.toList();
      }
    }
    return applications.values.toList();
  }

  Future<Uint8List> _readDirectoryBinary(int? size) async {
    final maximum = math.min(size ?? 4096, 4096);
    final data = BytesBuilder(copy: false);
    while (data.length < maximum) {
      final length = math.min(256, maximum - data.length);
      final reply = await readBinary(data.length, length);
      data.add(reply.data);
      if (reply.status == 0x6282 || reply.data.length != length) break;
    }
    return data.takeBytes();
  }
}
