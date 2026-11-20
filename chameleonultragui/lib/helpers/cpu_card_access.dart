import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_dump.dart' show cpuFindTlv;
import 'package:chameleonultragui/helpers/cpu_auth.dart'
    show CpuPinEncoding, cpuAuthStatus, cpuVerifyData;
import 'package:chameleonultragui/helpers/iso14443_4.dart';

enum CpuLiveFileKind { directory, binary, record, unknown }

bool _selectVariantRejected(int status) =>
    const [0x6700, 0x6A81, 0x6A82, 0x6A86, 0x6D00].contains(status) ||
    status >> 8 == 0x6C;

const cpuPseName = '1PAY.SYS.DDF01';
const cpuPpseName = '2PAY.SYS.DDF01';

bool cpuIsPaymentDirectoryName(List<int>? name) =>
    name != null &&
    {cpuPseName, cpuPpseName}.contains(String.fromCharCodes(name));

class CpuFileStatus implements Exception {
  final int word;
  final bool originalRejected;
  const CpuFileStatus(this.word, {this.originalRejected = true});
}

/// The card must reject the original operation with 6982 before asking for a
/// credential. A successful, user-approved authentication authorizes one retry.
Future<T> runCpuFileOperation<T>(
  Future<T> Function() operation, {
  Future<bool> Function()? authorize,
}) async {
  try {
    return await operation();
  } on CpuFileStatus catch (error) {
    if (error.word != 0x6982 ||
        !error.originalRejected ||
        authorize == null ||
        !await authorize())
      rethrow;
    return operation();
  }
}

class CpuFileReply {
  final Uint8List data;
  final int status;
  CpuFileReply(Uint8List response)
    : status = response[response.length - 2] << 8 | response.last,
      data = response.sublist(0, response.length - 2);
  CpuFileReply.fromData(this.data, this.status);
}

class CpuPartialWrite implements Exception {
  final int confirmedBytes;
  final Object cause;
  const CpuPartialWrite(this.confirmedBytes, this.cause);
}

class CpuLiveFile {
  final int? fid, size, recordLength, recordCount;
  final Uint8List? aid;
  final Uint8List control;
  final CpuLiveFileKind kind;
  final bool canChange;
  final String label;
  final int? directorySfi;
  int? get descriptor => controlFields[0x82]?.firstOrNull;
  bool get fixedRecordLength =>
      kind == CpuLiveFileKind.record &&
      const {2, 3, 6, 7}.contains((descriptor ?? 0) & 7);
  bool get hasDataObjects => (descriptor ?? 0) & 0xBF == 0x39;
  bool get isInternalEf => (descriptor ?? 0) & 0xB8 == 0x08;
  late final Map<int, Uint8List> controlFields = _readControlFields();
  Map<int, Uint8List> _readControlFields() {
    final fci = _cpuField(control, 0x6F);
    final fcp = _cpuField(control, 0x62) ?? _cpuField(fci, 0x62);
    return Map.unmodifiable({
      for (final tag in const [
        0x80,
        0x81,
        0x82,
        0x83,
        0x84,
        0x86,
        0x88,
        0x8A,
        0x8B,
        0x8C,
        0xAB,
      ])
        if (_cpuField(fcp ?? fci, tag) ??
                (tag == 0x84 ? _cpuField(fci, tag) : null)
            case final value?)
          tag: value,
    });
  }

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
    this.label, {
    this.directorySfi,
  });

  factory CpuLiveFile.shortFile({bool binary = false}) => CpuLiveFile._(
    Uint8List(0),
    binary ? CpuLiveFileKind.binary : CpuLiveFileKind.record,
    null,
    null,
    null,
    null,
    null,
    false,
    '',
  );

  factory CpuLiveFile.fromSelect(
    Uint8List control, {
    required bool directory,
    required bool typedSelection,
    bool readOnly = false,
    int? fid,
    Uint8List? aid,
  }) {
    final firstField = _cpuField;
    final fci = firstField(control, 0x6F);
    final params = firstField(control, 0x62) ?? firstField(fci, 0x62) ?? fci;
    Uint8List? field(int tag) => firstField(params, tag);
    final descriptor = field(0x82);
    final flags = descriptor?.firstOrNull;
    final kind = flags == null || flags & 0x80 != 0
        ? null
        : flags & 0x3F == 0x38
        ? CpuLiveFileKind.directory
        : flags & 0x38 == 0x38
        ? null
        : switch (flags & 7) {
            1 => CpuLiveFileKind.binary,
            >= 2 => CpuLiveFileKind.record,
            _ => null,
          };
    final actualFid = field(0x83);
    final id = actualFid?.length == 2 ? _cpuFileInt(actualFid!) : null;
    final name = firstField(fci, 0x84) ?? field(0x84);
    final proprietary = firstField(fci, 0xA5);
    final sfiByte = firstField(proprietary, 0x88);
    final sfi =
        sfiByte?.length == 1 && sfiByte!.single >= 1 && sfiByte.single <= 30
        ? sfiByte.single
        : null;
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
    final namedPaymentDirectory =
        fid == 0x3F00 && cpuIsPaymentDirectoryName(dfName);
    return CpuLiveFile._(
      control,
      kind ?? (directory ? CpuLiveFileKind.directory : CpuLiveFileKind.unknown),
      namedPaymentDirectory ? null : id ?? fid,
      directory ? dfName ?? aid : null,
      size,
      recordLength == 0 ? null : recordLength,
      count,
      !readOnly &&
          !namedPaymentDirectory &&
          !cpuIsPaymentDirectoryName(dfName) &&
          (flags == null || flags & 0xB8 != 0x08 && flags & 0xBF != 0x39) &&
          (typedSelection || kind != null),
      cpuDirectoryLabel(firstField(proprietary, 0x50) ?? field(0x50)),
      directorySfi: sfi,
    );
  }
}

Uint8List? _cpuField(Uint8List? data, int tag) =>
    data == null ? null : cpuFindTlv(data, tag, recursive: false).firstOrNull;

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
  final List<int> path;
  CpuDirectoryApplication(this.aid, this.label, this.path);
}

String cpuDirectoryLabel(Uint8List? value) => value == null
    ? ''
    : utf8
          .decode(value.take(64).toList(), allowMalformed: true)
          .replaceAll(
            RegExp(r'[\x00-\x1F\x7F-\x9F\u202A-\u202E\u2066-\u2069]'),
            '',
          )
          .trim();

/// Parse only fields directly in a published application template. Arbitrary
/// proprietary TLVs elsewhere in a reply do not name children or paths.
List<CpuDirectoryApplication> cpuDirectoryApplications(
  Iterable<Uint8List> records, {
  bool allowPath = true,
}) {
  final apps = <String, CpuDirectoryApplication>{};
  for (final record in records) {
    for (final template in cpuFindTlv(record, 0x61, recursive: false)) {
      Uint8List? field(int tag) =>
          cpuFindTlv(template, tag, recursive: false).firstOrNull;
      final aid = field(0x4F);
      if (aid == null || aid.length < 5 || aid.length > 16) continue;
      final path = <int>[];
      final encoded = allowPath ? field(0x51) : null;
      if (encoded != null && encoded.length.isEven && encoded.length <= 34) {
        for (var i = 0; i < encoded.length; i += 2) {
          path.add(encoded[i] << 8 | encoded[i + 1]);
        }
        if (path.firstOrNull == 0x3F00) path.removeAt(0);
        if (path.length > 16 ||
            path.any((fid) => [0, 0x3F00, 0x3FFF, 0xFFFF].contains(fid))) {
          path.clear();
        }
      }
      final key = aid.join('.');
      final previous = apps[key];
      final label = cpuDirectoryLabel(field(0x50));
      if (previous == null && apps.length >= 32) continue;
      apps[key] = CpuDirectoryApplication(
        aid,
        previous != null && previous.label.isNotEmpty ? previous.label : label,
        previous != null && previous.path.isNotEmpty
            ? previous.path
            : List.unmodifiable(path),
      );
    }
  }
  return apps.values.toList();
}

/// ISO 7816 file operations on one already selected RF session, basic channel.
class CpuCardAccess {
  final Future<Uint8List> Function(Uint8List) exchange;
  CpuCardAccess(this.exchange);

  Future<CpuFileReply> _send(
    List<int> apdu, {
    bool reading = false,
    bool mutation = false,
  }) async {
    // Follow GET RESPONSE when needed; this never repeats a write or VERIFY.
    int? firstStatus;
    final response = CpuFileReply(
      await exchangeCpuApdu(Uint8List.fromList(apdu), (command) async {
        final reply = await exchange(command);
        if (reply.length >= 2)
          firstStatus ??= reply[reply.length - 2] << 8 | reply.last;
        return reply;
      }),
    );
    if (response.status != 0x9000 && !(reading && response.status == 0x6282)) {
      throw CpuFileStatus(
        response.status,
        originalRejected: !mutation || firstStatus == response.status,
      );
    }
    return response;
  }

  Future<CpuLiveFile> _select(
    int mode,
    List<int> name, {
    required bool directory,
    bool typedSelection = true,
    bool readOnly = false,
    int response = 0,
    bool? withLe,
    int? fid,
    Uint8List? aid,
  }) async {
    final command = [
      0x00,
      0xA4,
      mode,
      response,
      if (name.isNotEmpty) ...[name.length, ...name],
    ];
    CpuFileReply reply;
    try {
      reply = await _send([...command, if (withLe != false) 0]);
    } on CpuFileStatus catch (error) {
      if (error.word >> 8 == 0x6C && withLe != false) {
        reply = await _send([...command, error.word & 255]);
      } else if (error.word == 0x6700 && withLe == null) {
        reply = await _send(command);
      } else {
        rethrow;
      }
    }
    return CpuLiveFile.fromSelect(
      reply.data,
      directory: directory,
      typedSelection: typedSelection,
      readOnly: readOnly,
      fid: fid,
      aid: aid,
    );
  }

  Future<CpuLiveFile> selectMaster() =>
      _select(0x00, _fid(0x3F00), directory: true, fid: 0x3F00);

  /// A card can alias the default selection to a named application. FCP
  /// alone establishes a real MF only when it actually returns FID 3F00.
  Future<CpuLiveFile?> selectVerifiedMaster() async {
    for (final withLe in [true, false]) {
      try {
        final file = await _select(
          0,
          _fid(0x3F00),
          directory: true,
          response: 4,
          withLe: withLe,
        );
        if (file.fid == 0x3F00 && !cpuIsPaymentDirectoryName(file.aid))
          return file;
        return null;
      } on CpuFileStatus catch (error) {
        if (!_selectVariantRejected(error.word)) rethrow;
      }
    }
    return null;
  }

  Future<CpuLiveFile> selectParent() =>
      _select(0x03, const [], directory: true);
  Future<CpuLiveFile> selectAid(Uint8List aid, {bool readOnly = false}) {
    RangeError.checkValueInInterval(aid.length, 5, 16, 'AID length');
    return _select(0x04, aid, directory: true, aid: aid, readOnly: readOnly);
  }

  /// Only for an explicit user selection. Try the same exact DF name with
  /// different SELECT response formats; never guess a prefix or retry auth.
  Future<CpuLiveFile> selectAidForAccess(
    Uint8List aid, {
    bool readOnly = false,
  }) async {
    RangeError.checkValueInInterval(aid.length, 5, 16, 'AID length');
    CpuFileStatus? failure;
    for (final (p2, withLe) in [
      (0, true),
      (0, false),
      (4, true),
      (0x0C, false),
    ]) {
      try {
        return await _select(
          4,
          aid,
          directory: true,
          aid: aid,
          readOnly: readOnly,
          response: p2,
          withLe: withLe,
        );
      } on CpuFileStatus catch (error) {
        if (!_selectVariantRejected(error.word)) rethrow;
        if (failure == null || error.word == 0x6A82) failure = error;
      }
    }
    throw failure!;
  }

  /// Type 4 EF selection uses the NFC Forum short SELECT without FCI.
  Future<CpuLiveFile> selectType4File(int fid) async {
    final reply = await _send([0, 0xA4, 0, 0x0C, 2, ..._fid(fid)]);
    return CpuLiveFile._(
      reply.data,
      CpuLiveFileKind.binary,
      fid,
      null,
      null,
      null,
      null,
      false,
      '',
    );
  }

  Future<CpuLiveFile> selectFile(
    int fid, {
    required bool directory,
    bool preferFcp = false,
  }) async {
    final id = _fid(fid);
    if (preferFcp) {
      try {
        return await _select(
          directory ? 1 : 2,
          id,
          directory: directory,
          fid: fid,
          response: 4,
        );
      } on CpuFileStatus catch (error) {
        if (!_selectVariantRejected(error.word)) rethrow;
      }
    }
    try {
      return await _select(
        directory ? 0x01 : 0x02,
        id,
        directory: directory,
        fid: fid,
      );
    } on CpuFileStatus catch (error) {
      if (error.word != 0x6A86 &&
          error.word != 0x6A81 &&
          !(preferFcp && error.word == 0x6A82))
        rethrow;
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

  Future<CpuLiveFile> selectPath(
    List<int> path, {
    required bool directory,
    bool relative = false,
    bool preferFcp = false,
  }) async {
    RangeError.checkValueInInterval(path.length, 1, 16, 'Path length');
    final mode = relative ? 9 : 8;
    final name = [for (final id in path) ..._fid(id)];
    if (preferFcp) {
      try {
        return await _select(
          mode,
          name,
          directory: directory,
          typedSelection: false,
          response: 4,
          fid: path.last,
        );
      } on CpuFileStatus catch (error) {
        if (!_selectVariantRejected(error.word)) rethrow;
      }
    }
    return _select(
      mode,
      name,
      directory: directory,
      typedSelection: false,
      fid: path.last,
    );
  }

  /// City Union electronic purse (EP). The matching DF must be selected.
  /// Return the card's big-endian binary amount in minor units on 9000 only.
  Future<int> readCityUnionPurseBalance() async {
    final reply = await _send([0x80, 0x5C, 0x00, 0x02, 0x04]);
    if (reply.data.length != 4 || (reply.data.first & 0x80) != 0) {
      throw const FormatException('Unexpected electronic purse balance format');
    }
    return ByteData.sublistView(reply.data).getUint32(0, Endian.big);
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

  Future<CpuFileReply> readBinarySfi(int sfi, int offset, int length) {
    RangeError.checkValueInInterval(sfi, 1, 30, 'SFI');
    RangeError.checkValueInInterval(offset, 0, 255, 'Offset');
    RangeError.checkValueInInterval(length, 1, 256 - offset, 'Length');
    return _send([0, 0xB0, 0x80 | sfi, offset, length & 255], reading: true);
  }

  Future<CpuFileReply> readBinaryRange(
    int offset,
    int length, {
    int maxBlock = 256,
    Future<CpuFileReply> Function(int offset, int length)? read,
  }) async {
    _binaryBounds(offset, length, 32768);
    RangeError.checkValueInInterval(maxBlock, 1, 256);
    final data = BytesBuilder(copy: false);
    var status = 0x9000;
    while (data.length < length) {
      final position = offset + data.length;
      final block = math.min(maxBlock, length - data.length);
      final reply = await (read ?? readBinary)(position, block);
      if (reply.data.length > block) {
        throw const FormatException('READ BINARY exceeded Le');
      }
      data.add(reply.data);
      status = reply.status;
      if (status == 0x6282 || reply.data.length < block) break;
    }
    return CpuFileReply.fromData(data.takeBytes(), status);
  }

  Future<CpuFileReply> updateBinary(int offset, Uint8List data) {
    _binaryBounds(offset, data.length, 255);
    return _send([
      0x00,
      0xD6,
      offset >> 8,
      offset & 255,
      data.length,
      ...data,
    ], mutation: true);
  }

  /// Advance only after a confirmed write; report any previous blocks on failure.
  Future<CpuFileReply> updateBinaryRange(
    int offset,
    Uint8List data, {
    Future<CpuFileReply> Function(int offset, Uint8List block)? write,
  }) async {
    _binaryBounds(offset, data.length, 32768);
    var confirmed = 0;
    CpuFileReply? last;
    while (confirmed < data.length) {
      final end = math.min(data.length, confirmed + 255);
      final block = Uint8List.sublistView(data, confirmed, end);
      try {
        last = await (write ?? updateBinary)(offset + confirmed, block);
      } catch (error) {
        if (confirmed == 0) rethrow;
        throw CpuPartialWrite(confirmed, error);
      }
      confirmed = end;
    }
    return last!;
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

  Future<CpuFileReply> readRecord(int number, int length, {int sfi = 0}) {
    RangeError.checkValueInInterval(number, 1, 254, 'Record');
    RangeError.checkValueInInterval(length, 1, 256, 'Length');
    RangeError.checkValueInInterval(sfi, 0, 30, 'SFI');
    return _send([
      0x00,
      0xB2,
      number,
      sfi << 3 | 0x04,
      length & 255,
    ], reading: true);
  }

  Future<CpuFileReply> updateRecord(int number, Uint8List data) {
    RangeError.checkValueInInterval(number, 1, 254, 'Record');
    RangeError.checkValueInInterval(data.length, 1, 255, 'Length');
    return _send([
      0x00,
      0xDC,
      number,
      0x04,
      data.length,
      ...data,
    ], mutation: true);
  }

  /// ISO 7816 CHANGE REFERENCE DATA (old PIN followed by new PIN). Use an
  /// explicit P2 and a fixed field size; some cards have their own protocol.
  Future<CpuFileReply> changePin(
    int reference,
    CpuPinEncoding encoding,
    String current,
    String next,
  ) async {
    RangeError.checkValueInInterval(reference, 0, 255, 'PIN reference');
    final old = cpuVerifyData(current, encoding);
    final replacement = cpuVerifyData(next, encoding);
    if (old.length != replacement.length) {
      throw const FormatException(
        'The PIN fields must have the same byte length',
      );
    }
    final command = Uint8List.fromList([
      0,
      0x24,
      0,
      reference,
      old.length + replacement.length,
      ...old,
      ...replacement,
    ]);
    try {
      final raw = await exchange(command);
      final status = cpuAuthStatus(raw);
      if (status != 0x9000)
        throw CpuFileStatus(status, originalRejected: status >> 8 != 0x61);
      return CpuFileReply(raw);
    } finally {
      old.fillRange(0, old.length, 0);
      replacement.fillRange(0, replacement.length, 0);
      command.fillRange(5, command.length, 0);
    }
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
    ], mutation: true);
  }

  Future<CpuFileReply> deleteFile(int fid) {
    if (fid == 0 || fid == 0x3F00 || fid == 0x3FFF || fid == 0xFFFF) {
      throw ArgumentError.value(fid, 'FID');
    }
    return _send([0x00, 0xE4, 0x00, 0x00, 2, ..._fid(fid)], mutation: true);
  }

  /// Read EF.DIR, which must already be selected; regular records and binary
  /// directories share the same bounded application-template parser.
  Future<List<CpuDirectoryApplication>> readApplicationEntries(
    CpuLiveFile directory, {
    void Function(CpuFileReply reply, int index, bool record)? onRead,
  }) async {
    final records = <Uint8List>[];
    Future<void> addBinary() async {
      final length = math.min(directory.size ?? 4096, 4096);
      if (length == 0) return;
      final reply = await readBinaryRange(0, length);
      onRead?.call(reply, 0, false);
      records.add(reply.data);
    }

    if (directory.kind == CpuLiveFileKind.binary) {
      await addBinary();
    } else {
      final count = math.min(directory.recordCount ?? 32, 32);
      for (var number = 1; number <= count; number++) {
        try {
          final reply = await readRecord(number, 256);
          onRead?.call(reply, number, true);
          if (reply.data.isEmpty) break;
          records.add(reply.data);
          if (reply.status == 0x6282) break;
        } on CpuFileStatus catch (error) {
          if (error.word == 0x6A83) break;
          if (error.word != 0x6981 ||
              number != 1 ||
              directory.kind != CpuLiveFileKind.unknown)
            rethrow;
          await addBinary();
          break;
        }
      }
    }
    return cpuDirectoryApplications(records);
  }
}
