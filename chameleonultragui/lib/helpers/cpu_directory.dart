import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_dump.dart' show cpuFindTlv;
import 'package:chameleonultragui/helpers/cpu_type4.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart' show exchangeCpuApdu;

export 'package:chameleonultragui/helpers/cpu_type4.dart'
    show cpuType4Aid, cpuType4CcFid;

typedef CpuObservedRead = void Function(
  CpuFileAddress address,
  CpuFileReply reply,
  int index,
  bool record,
);
typedef CpuObservedSelect = void Function(
  CpuFileAddress address,
  CpuLiveFile file,
);

/// An unambiguous address: a path under MF, or under a named application.
/// Never infer a parent from an FCI's FID alone.
class CpuFileAddress {
  final List<int> path;
  final List<int>? aid;
  final CpuFileAddress? _branch;
  final int? sfi;
  final bool metadataOnly;
  final bool shortBinary;
  const CpuFileAddress.master()
    : path = const [],
      aid = null,
      _branch = null,
      sfi = null,
      shortBinary = false,
      metadataOnly = false;
  CpuFileAddress(
    List<int> path, {
    List<int>? aid,
    CpuFileAddress? branch,
    this.metadataOnly = false,
  }) : path = List.unmodifiable(path),
       aid = aid == null ? null : List.unmodifiable(aid),
       _branch = branch,
       shortBinary = false,
       sfi = null;
  CpuFileAddress.directoryRecords(CpuFileAddress parent, int this.sfi)
    : _branch = parent,
      path = const [],
      aid = null,
      shortBinary = false,
      metadataOnly = true;
  CpuFileAddress.shortBinary(CpuFileAddress parent, int this.sfi)
    : _branch = parent,
      path = const [],
      aid = null,
      shortBinary = true,
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
      ? shortBinary
            ? 'SFI ${sfi!.toRadixString(16).padLeft(2, '0').toUpperCase()}h'
            : 'SFI ${sfi.toString().padLeft(2, '0')}'
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
      return CpuLiveFile.shortFile(binary: shortBinary);
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
  final CpuType4Header? type4Header;
  final CpuType4File? type4File;
  const CpuDirectoryEntry(
    this.address, {
    required this.kind,
    this.label = '',
    this.applicationAid,
    this.capacity,
    this.type4 = false,
    this.type4Header,
    this.type4File,
  });

  bool get isDirectory => kind == CpuLiveFileKind.directory;
  bool get isMaster => address.fid == 0x3F00 && address.parent == null;
}

class CpuDirectoryTree {
  final _entries = <String, CpuDirectoryEntry>{};
  bool get isEmpty => _entries.isEmpty;
  CpuDirectoryEntry? at(CpuFileAddress address) => _entries[address.display];
  Iterable<CpuDirectoryEntry> get entries => _entries.values;

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
      type4Header: entry.type4Header ?? old?.type4Header,
      type4File: entry.type4File ?? old?.type4File,
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
  CpuObservedRead? onRead,
  CpuObservedSelect? onSelect,
}) async {
  final seen = <String>{};
  var partial = false;
  Future<void> walk(CpuFileAddress address, CpuLiveFile file, int depth) async {
    if (!seen.add(cpuAidHex(address.aid!))) return;
    if (depth > 5 || seen.length > 24) {
      partial = true;
      return;
    }
    onSelect?.call(address, file);
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
          onRead?.call(shortFile, reply, record, true);
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
Future<CpuDirectoryScan> discoverCpuDirectory(
  CpuCardAccess card, {
  CpuObservedRead? onRead,
  CpuObservedSelect? onSelect,
}) async {
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
  if (actualMaster != null) onSelect?.call(master, actualMaster);
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
    final address = master.child(0x2F00);
    tree.add(CpuDirectoryEntry(address, kind: dir.kind, label: 'EF.DIR'));
    onSelect?.call(address, dir);
    addApps(
      await probe(
        'EF.DIR',
        () => card.readApplicationEntries(
          dir,
          onRead: (reply, index, record) =>
              onRead?.call(address, reply, index, record),
        ),
      ),
    );
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
      onRead: onRead,
      onSelect: onSelect,
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
    onSelect?.call(app, ndef);
    final cc = await probe(
      'NDEF CC',
      () => card.selectType4File(cpuType4CcFid),
    );
    if (cc != null) {
      final address = app.child(cpuType4CcFid);
      tree.add(
        CpuDirectoryEntry(address, kind: cc.kind, label: 'CC', type4: true),
      );
      onSelect?.call(address, cc);
      final capability = await probe('NDEF CC', () async {
        final reply = await readCpuType4Capability(card);
        onRead?.call(address, reply, 0, false);
        return parseCpuType4Capability(reply.data);
      });
      if (capability != null) {
        tree.add(
          CpuDirectoryEntry(
            address,
            kind: cc.kind,
            capacity: capability.header.size,
            type4: true,
            type4Header: capability.header,
          ),
        );
        for (final file in capability.files.take(32)) {
          tree.add(
            CpuDirectoryEntry(
              app.child(file.fid),
              kind: CpuLiveFileKind.binary,
              capacity: file.capacity,
              label: file.lengthBytes == null ? '' : 'NDEF',
              type4: true,
              type4Header: capability.header,
              type4File: file,
            ),
          );
        }
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
