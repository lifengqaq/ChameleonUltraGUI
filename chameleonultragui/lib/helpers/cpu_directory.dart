import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_dump.dart' show cpuFindTlv;
import 'package:chameleonultragui/helpers/iso14443_4.dart' show exchangeCpuApdu;

const cpuType4Aid = [0xD2, 0x76, 0, 0, 0x85, 1, 1];
const cpuType4CcFid = 0xE103;

/// An unambiguous address: a path under MF, or under a named application.
/// Never infer a parent from an FCI's FID alone.
class CpuFileAddress {
  final List<int> path;
  final List<int>? aid;
  final CpuFileAddress? _branch;
  final int? sfi;
  final bool metadataOnly;
  const CpuFileAddress.master()
    : path = const [],
      aid = null,
      _branch = null,
      sfi = null,
      metadataOnly = false;
  CpuFileAddress(
    List<int> path, {
    List<int>? aid,
    CpuFileAddress? branch,
    this.metadataOnly = false,
  }) : path = List.unmodifiable(path),
       aid = aid == null ? null : List.unmodifiable(aid),
       _branch = branch,
       sfi = null;
  CpuFileAddress.directoryRecords(CpuFileAddress parent, int this.sfi)
    : _branch = parent,
      path = const [],
      aid = null,
      metadataOnly = true;

  int? get fid =>
      sfi == null ? path.lastOrNull ?? (aid == null ? 0x3F00 : null) : null;
  CpuFileAddress? get parent => path.isEmpty
      ? _branch
      : CpuFileAddress(
          path.sublist(0, path.length - 1),
          aid: aid,
          branch: _branch,
          metadataOnly: metadataOnly,
        );
  CpuFileAddress child(int fid) => CpuFileAddress(
    [...path, fid],
    aid: aid,
    branch: _branch,
    metadataOnly: metadataOnly,
  );
  String get display => [
    if (_branch != null) _branch.display,
    if (sfi != null)
      entryLabel
    else if (aid == null)
      '3F00'
    else
      'AID ${cpuAidHex(aid!)}',
    ...path.map(cpuFidHex),
  ].join('/');
  String get entryLabel => sfi != null
      ? 'SFI ${sfi.toString().padLeft(2, '0')}'
      : fid != null
      ? 'FID ${cpuFidHex(fid!)}'
      : 'AID ${cpuAidHex(aid!)}';

  Future<CpuLiveFile> open(
    CpuCardAccess card, {
    required bool directory,
    bool type4 = false,
    bool preferFcp = false,
    CpuFileAddress? selectedDirectory,
  }) async {
    if (sfi != null) {
      if (parent!.display != selectedDirectory?.display) {
        await parent!.open(card, directory: true);
      }
      return CpuLiveFile.directoryRecords();
    }
    if (path.isEmpty) {
      if (aid != null) {
        try {
          return await card.selectAidForAccess(
            Uint8List.fromList(aid!),
            readOnly: metadataOnly,
          );
        } on CpuFileStatus catch (error) {
          if (_branch != null ||
              !cpuIsPaymentDirectoryName(aid) ||
              ![0x6A81, 0x6A82, 0x6A86, 0x6D00].contains(error.word))
            rethrow;
          // Some cards expose the PSE through the default selection only.
          final fallback = await card.selectMaster();
          if (fallback.aid == null ||
              cpuAidHex(fallback.aid!) != cpuAidHex(aid!))
            rethrow;
          return fallback;
        }
      }
      final CpuLiveFile file;
      try {
        file = await card.selectMaster();
      } on CpuFileStatus catch (error) {
        if (!preferFcp ||
            !const [0x6A82, 0x6A86, 0x6A81, 0x6700].contains(error.word))
          rethrow;
        final master = await card.selectVerifiedMaster();
        if (master == null) rethrow;
        return master;
      }
      if (cpuIsPaymentDirectoryName(file.aid)) {
        if (preferFcp) {
          final master = await card.selectVerifiedMaster();
          if (master != null) return master;
        }
        throw const FormatException(
          'The card returned a payment directory in place of MF',
        );
      }
      return file;
    }
    if (parent!.display == selectedDirectory?.display) {
      return type4
          ? card.selectType4File(path.last)
          : card.selectFile(
              path.last,
              directory: directory,
              preferFcp: preferFcp,
            );
    }
    if (aid == null && !type4 && (path.length > 1 || preferFcp)) {
      try {
        return await card.selectPath(
          path,
          directory: directory,
          preferFcp: preferFcp,
        );
      } on CpuFileStatus catch (error) {
        if (![0x6A81, 0x6A86, 0x6A82].contains(error.word)) rethrow;
        // Some cards only implement child selection. The directory already
        // provided each exact FID; no search across neighboring IDs.
      }
    }
    if (aid == null) {
      await const CpuFileAddress.master().open(
        card,
        directory: true,
        preferFcp: preferFcp,
      );
    } else {
      await card.selectAidForAccess(
        Uint8List.fromList(aid!),
        readOnly: metadataOnly,
      );
      if (path.length > 1) {
        return card.selectPath(
          path,
          directory: directory,
          relative: true,
          preferFcp: preferFcp,
        );
      }
    }
    for (final fid in path.take(path.length - 1)) {
      await card.selectFile(fid, directory: true, preferFcp: preferFcp);
    }
    return type4
        ? card.selectType4File(path.last)
        : card.selectFile(
            path.last,
            directory: directory,
            preferFcp: preferFcp,
          );
  }
}

String cpuFidHex(int fid) =>
    fid.toRadixString(16).padLeft(4, '0').toUpperCase();
String cpuAidHex(Iterable<int> aid) =>
    aid.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

class CpuDirectoryEntry {
  final CpuFileAddress address;
  final CpuLiveFileKind kind;
  final String label;
  final List<int>? applicationAid;
  final int? capacity;
  final bool type4;
  const CpuDirectoryEntry(
    this.address, {
    required this.kind,
    this.label = '',
    this.applicationAid,
    this.capacity,
    this.type4 = false,
  });

  bool get isDirectory => kind == CpuLiveFileKind.directory;
  bool get isMaster => address.fid == 0x3F00 && address.parent == null;
}

class CpuDirectoryTree {
  final _entries = <String, CpuDirectoryEntry>{};
  bool get isEmpty => _entries.isEmpty;
  CpuDirectoryEntry? at(CpuFileAddress address) => _entries[address.display];

  List<CpuDirectoryEntry> childrenOf(CpuFileAddress? parent) => [
    for (final entry in _entries.values)
      if (entry.address.parent?.display == parent?.display) entry,
  ]..sort((a, b) => a.address.display.compareTo(b.address.display));

  void add(CpuDirectoryEntry entry) {
    final address = entry.address;
    final parent = address.parent;
    if (parent != null && at(parent)?.isDirectory == false) return;
    if (parent != null && at(parent) == null) {
      add(CpuDirectoryEntry(parent, kind: CpuLiveFileKind.directory));
    }
    final old = at(address);
    if (old == null && _entries.length >= 256) return;
    _entries[address.display] = CpuDirectoryEntry(
      address,
      kind: entry.kind == CpuLiveFileKind.unknown && old != null
          ? old.kind
          : entry.kind,
      label: old != null && old.label.isNotEmpty ? old.label : entry.label,
      applicationAid: entry.applicationAid ?? old?.applicationAid,
      capacity: entry.capacity ?? old?.capacity,
      type4: entry.type4 || old?.type4 == true,
    );
  }

  void remove(CpuFileAddress address) {
    final prefix = address.display;
    _entries.removeWhere(
      (key, _) => key == prefix || key.startsWith('$prefix/'),
    );
  }

  void merge(CpuDirectoryTree other) {
    for (final entry in other._entries.values) {
      add(entry);
    }
  }

  CpuFileAddress? applicationAddress(List<int> aid) {
    final name = cpuAidHex(aid);
    return _entries.values
        .where(
          (entry) =>
              entry.applicationAid != null &&
              cpuAidHex(entry.applicationAid!) == name,
        )
        .firstOrNull
        ?.address;
  }

  CpuFileAddress addApplication(CpuDirectoryApplication app) {
    final name = cpuAidHex(app.aid);
    final canUsePath =
        app.path.isNotEmpty &&
        app.path.first != 0x2F00 &&
        name != cpuAidHex(cpuType4Aid);
    final preferred = canUsePath
        ? CpuFileAddress(app.path)
        : CpuFileAddress([], aid: app.aid);
    final address = applicationAddress(app.aid) ?? preferred;
    add(
      CpuDirectoryEntry(
        address,
        kind: CpuLiveFileKind.directory,
        label: app.label,
        applicationAid: app.aid,
      ),
    );
    return address;
  }

  /// Parse explicitly read directory records without opening any advertised ADF.
  int addDirectoryRecords(
    CpuFileAddress directory,
    Iterable<Uint8List> records,
  ) {
    final seen = <String>{};
    for (final record in records) {
      for (final item in _paymentItems(record, record: true)) {
        if (seen.length >= 32) return seen.length;
        if (seen.add(cpuAidHex(item.name))) _addPaymentEntry(directory, item);
      }
    }
    return seen.length;
  }

  CpuFileAddress? _addPaymentEntry(
    CpuFileAddress parent,
    _PaymentDirectoryItem item,
  ) {
    final name = cpuAidHex(item.name);
    for (
      CpuFileAddress? ancestor = parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor.aid != null && cpuAidHex(ancestor.aid!) == name) return null;
    }
    if (!item.nested && applicationAddress(item.name) != null) return null;
    final child = CpuFileAddress(
      [],
      aid: item.name,
      branch: parent,
      metadataOnly: item.nested,
    );
    add(
      CpuDirectoryEntry(
        child,
        kind: CpuLiveFileKind.directory,
        label: item.label,
        applicationAid: item.name,
      ),
    );
    return child;
  }
}

class CpuDirectoryScan {
  final CpuDirectoryTree tree;
  final Map<String, int> cardStatuses;
  final CpuLiveFile? master;
  final CpuFileAddress? selectedAddress;
  final bool incomplete;
  const CpuDirectoryScan(
    this.tree,
    this.cardStatuses,
    this.master,
    this.incomplete, {
    this.selectedAddress,
  });
}

class _DirectoryBudget implements Exception {
  const _DirectoryBudget();
}

typedef _PaymentDirectoryItem = ({Uint8List name, String label, bool nested});

Iterable<_PaymentDirectoryItem> _paymentItems(
  Uint8List data, {
  bool record = false,
}) sync* {
  final containers = record ? cpuFindTlv(data, 0x70, recursive: false) : [data];
  for (final container in containers) {
    for (final app in cpuFindTlv(container, 0x61, recursive: false)) {
      final aid = _field(app, 0x4F), ddfName = _field(app, 0x9D);
      final name = aid ?? ddfName;
      if (name == null ||
          name.length < 5 ||
          name.length > 16 ||
          (aid != null && ddfName != null))
        continue;
      yield (
        name: name,
        label: cpuDirectoryLabel(_field(app, 0x50)),
        nested: ddfName != null,
      );
    }
  }
}

/// Follow only directory definitions (9D) and only their declared SFI. ADFs
/// are listed by AID, without running GPO or trying to enumerate payments data.
Future<bool> _walkPaymentDirectory(
  CpuCardAccess card,
  CpuDirectoryTree tree,
  Map<String, int> statuses,
  CpuFileAddress root,
  CpuLiveFile rootFile, {
  bool records = true,
}) async {
  final seen = <String>{};
  var partial = false;
  Future<void> walk(CpuFileAddress address, CpuLiveFile file, int depth) async {
    if (!seen.add(cpuAidHex(address.aid!))) return;
    if (depth > 5 || seen.length > 24) {
      partial = true;
      return;
    }
    final children = <String, _PaymentDirectoryItem>{};
    void addAll(Iterable<_PaymentDirectoryItem> items) {
      for (final item in items) {
        if (children.length >= 32) {
          partial = true;
          break;
        }
        children.putIfAbsent(cpuAidHex(item.name), () => item);
      }
    }

    final inline = _field(_field(_field(file.control, 0x6F), 0xA5), 0xBF0C);
    if (inline != null) addAll(_paymentItems(inline));
    final sfi = records ? file.directorySfi : null;
    if (sfi != null) {
      final shortFile = CpuFileAddress.directoryRecords(address, sfi);
      tree.add(CpuDirectoryEntry(shortFile, kind: CpuLiveFileKind.record));
      for (var record = 1; record <= 24; record++) {
        try {
          final reply = await card.readRecord(record, 256, sfi: sfi);
          addAll(_paymentItems(reply.data, record: true));
          if (reply.status == 0x6282) break;
          if (record == 24) partial = true;
        } on CpuFileStatus catch (error) {
          if (error.word != 0x6A83) statuses[shortFile.display] = error.word;
          break;
        }
      }
    }
    for (final item in children.values) {
      if (item.nested && seen.contains(cpuAidHex(item.name))) continue;
      final child = tree._addPaymentEntry(address, item);
      if (child == null || !item.nested || !records) continue;
      if (depth >= 5 || seen.length >= 24) {
        partial = true;
        continue;
      }
      try {
        await walk(
          child,
          await card.selectAid(item.name, readOnly: true),
          depth + 1,
        );
      } on CpuFileStatus catch (error) {
        statuses[child.display] = error.word;
      } on FormatException {
        partial = true;
      }
    }
  }

  try {
    await walk(root, rootFile, 0);
  } on _DirectoryBudget {
    return true;
  }
  return partial;
}

/// Read directory metadata only: no authentication, guessed FIDs, payment
/// processing or file contents outside the published directory/CC itself.
Future<CpuDirectoryScan> discoverCpuDirectory(CpuCardAccess card) async {
  final tree = CpuDirectoryTree();
  final statuses = <String, int>{};
  var incomplete = false;
  Future<T?> probe<T>(String name, Future<T> Function() read) async {
    try {
      return await read();
    } on CpuFileStatus catch (error) {
      if (![0x6A81, 0x6A82, 0x6A86, 0x6D00, 0x6E00].contains(error.word)) {
        statuses[name] = error.word;
      }
      return null;
    } on FormatException {
      incomplete = true;
      return null;
    }
  }

  const master = CpuFileAddress.master();
  final selectedMaster = await probe('MF', card.selectMaster);
  final defaultPse =
      selectedMaster != null && cpuIsPaymentDirectoryName(selectedMaster.aid)
      ? selectedMaster
      : null;
  final actualMaster = defaultPse == null ? selectedMaster : null;
  final dir = defaultPse != null
      ? null
      : await probe(
          'EF.DIR',
          () => actualMaster != null
              ? card.selectFile(0x2F00, directory: false)
              : card.selectPath([0x2F00], directory: false),
        );
  if (actualMaster != null || dir != null) {
    tree.add(
      const CpuDirectoryEntry(
        master,
        kind: CpuLiveFileKind.directory,
        label: 'MF',
      ),
    );
  }
  void addApps(List<CpuDirectoryApplication>? apps) {
    for (final app in apps ?? const <CpuDirectoryApplication>[]) {
      tree.addApplication(app);
    }
  }

  if (dir != null) {
    tree.add(
      CpuDirectoryEntry(master.child(0x2F00), kind: dir.kind, label: 'EF.DIR'),
    );
    addApps(await probe('EF.DIR', () => card.readApplicationEntries(dir)));
  }
  var remaining = 80;
  final boundedCard = CpuCardAccess((command) {
    if (remaining-- <= 0) throw const _DirectoryBudget();
    return card.exchange(command);
  });
  for (final (name, label) in [(cpuPseName, 'PSE'), (cpuPpseName, 'PPSE')]) {
    final aid = Uint8List.fromList(name.codeUnits);
    final current =
        defaultPse != null && cpuAidHex(defaultPse.aid!) == cpuAidHex(aid)
        ? defaultPse
        : null;
    final file =
        current ??
        await probe(label, () => card.selectAid(aid, readOnly: true));
    if (file == null) continue;
    final address = CpuFileAddress([], aid: aid, metadataOnly: true);
    // Reuse an EF.DIR entry in place if it already had this AID.
    final known = tree.applicationAddress(aid);
    if (known != null && known.display != address.display) tree.remove(known);
    tree.add(
      CpuDirectoryEntry(
        address,
        kind: CpuLiveFileKind.directory,
        label: label,
        applicationAid: aid,
      ),
    );
    final stopped = await _walkPaymentDirectory(
      boundedCard,
      tree,
      statuses,
      address,
      file,
      records: name == cpuPseName,
    );
    incomplete |= stopped;
  }
  final ndef = await probe(
    'NDEF',
    () => card.selectAid(Uint8List.fromList(cpuType4Aid)),
  );
  if (ndef != null) {
    final app = tree.addApplication(
      CpuDirectoryApplication(
        Uint8List.fromList(cpuType4Aid),
        'NDEF',
        const [],
      ),
    );
    tree.add(
      CpuDirectoryEntry(app, kind: CpuLiveFileKind.directory, label: 'NDEF'),
    );
    final cc = await probe(
      'NDEF CC',
      () => card.selectType4File(cpuType4CcFid),
    );
    if (cc != null) {
      tree.add(
        CpuDirectoryEntry(
          app.child(cpuType4CcFid),
          kind: cc.kind,
          label: 'CC',
          type4: true,
        ),
      );
      final files = await probe('NDEF CC', () => _readType4Files(card));
      for (final file in files ?? const <(int, int, bool)>[]) {
        final (fid, capacity, ndef) = file;
        tree.add(
          CpuDirectoryEntry(
            app.child(fid),
            kind: CpuLiveFileKind.binary,
            capacity: capacity,
            label: ndef ? 'NDEF' : '',
            type4: true,
          ),
        );
      }
    }
  }

  var restored = actualMaster == null && defaultPse == null
      ? null
      : await probe('MF', card.selectMaster);
  CpuFileAddress? initial = restored == null ? null : master;
  if (restored != null && cpuIsPaymentDirectoryName(restored.aid)) {
    initial = CpuFileAddress([], aid: restored.aid, metadataOnly: true);
    if (tree.at(initial) == null) {
      restored = null;
      initial = null;
    }
  }
  return CpuDirectoryScan(
    tree,
    Map.unmodifiable(statuses),
    restored,
    incomplete,
    selectedAddress: initial,
  );
}

Uint8List? _field(Uint8List? data, int tag) =>
    data == null ? null : cpuFindTlv(data, tag, recursive: false).firstOrNull;

Future<List<(int, int, bool)>> _readType4Files(CpuCardAccess card) async {
  final header = (await card.readBinary(0, 15)).data;
  if (header.length != 15)
    throw const FormatException('Incomplete Type 4 CC header');
  final size = header[0] << 8 | header[1], maxRead = header[3] << 8 | header[4];
  if (size < 15 || size > 1024 || maxRead < 15)
    throw const FormatException('Invalid Type 4 CC length');
  final blocks = BytesBuilder()..add(header.sublist(7));
  for (var offset = header.length; offset < size;) {
    final length = math.min(256, math.min(size - offset, maxRead));
    final block = (await card.readBinary(offset, length)).data;
    if (block.length != length)
      throw const FormatException('Incomplete Type 4 CC');
    blocks.add(block);
    offset += length;
  }
  final data = blocks.takeBytes();
  final files = <(int, int, bool)>[];
  final ids = <int>{cpuType4CcFid, 0, 0x3F00, 0x3FFF, 0xFFFF};
  for (var i = 0; i < data.length && files.length < 32;) {
    final tag = data[i++];
    if (tag == 0) continue;
    if (tag == 0xFE) break;
    if (i >= data.length) throw const FormatException('Incomplete Type 4 TLV');
    var length = data[i++];
    if (length == 0xFF) {
      if (i + 2 > data.length)
        throw const FormatException('Incomplete Type 4 TLV length');
      length = data[i] << 8 | data[i + 1];
      i += 2;
    }
    if (i + length > data.length)
      throw const FormatException('Incomplete Type 4 file descriptor');
    if ((tag == 4 || tag == 5) && length == 6 || tag == 6 && length == 8) {
      final fid = data[i] << 8 | data[i + 1];
      var capacity = 0;
      for (var index = i + 2; index < i + length - 2; index++) {
        capacity = capacity << 8 | data[index];
      }
      if (capacity > 0 && ids.add(fid)) files.add((fid, capacity, tag != 5));
    }
    i += length;
  }
  return files;
}
