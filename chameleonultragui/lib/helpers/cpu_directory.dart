import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_dump.dart' show cpuFindTlv;

const cpuType4Aid = [0xD2, 0x76, 0, 0, 0x85, 1, 1];
const cpuType4CcFid = 0xE103;
const _ppse = [
  0x32,
  0x50,
  0x41,
  0x59,
  0x2E,
  0x53,
  0x59,
  0x53,
  0x2E,
  0x44,
  0x44,
  0x46,
  0x30,
  0x31,
];

/// An unambiguous address: a path under MF, or under a named application.
/// Never infer a parent from an FCI's FID alone.
class CpuFileAddress {
  final List<int> path;
  final List<int>? aid;
  const CpuFileAddress.master() : path = const [], aid = null;
  CpuFileAddress(List<int> path, {List<int>? aid})
    : path = List.unmodifiable(path),
      aid = aid == null ? null : List.unmodifiable(aid);

  int? get fid => path.lastOrNull ?? (aid == null ? 0x3F00 : null);
  CpuFileAddress? get parent => path.isEmpty
      ? null
      : CpuFileAddress(path.sublist(0, path.length - 1), aid: aid);
  CpuFileAddress child(int fid) => CpuFileAddress([...path, fid], aid: aid);
  String get display => [
    aid == null ? '3F00' : 'AID ${cpuAidHex(aid!)}',
    ...path.map(cpuFidHex),
  ].join('/');
  String get entryLabel =>
      fid != null ? 'FID ${cpuFidHex(fid!)}' : 'AID ${cpuAidHex(aid!)}';

  Future<CpuLiveFile> open(
    CpuCardAccess card, {
    required bool directory,
    bool type4 = false,
    CpuFileAddress? selectedDirectory,
  }) async {
    if (path.isEmpty) {
      return aid == null
          ? card.selectMaster()
          : card.selectAid(Uint8List.fromList(aid!));
    }
    if (parent!.display == selectedDirectory?.display) {
      return type4
          ? card.selectType4File(path.last)
          : card.selectFile(path.last, directory: directory);
    }
    if (aid == null && !type4 && path.length > 1) {
      try {
        return await card.selectPath(path, directory: directory);
      } on CpuFileStatus catch (error) {
        if (error.word != 0x6A86 && error.word != 0x6A81) rethrow;
        // Some cards only implement child selection. The directory already
        // provided each exact FID; no search across neighboring IDs.
      }
    }
    if (aid == null) {
      await card.selectMaster();
    } else {
      await card.selectAid(Uint8List.fromList(aid!));
      if (path.length > 1) {
        return card.selectPath(path, directory: directory, relative: true);
      }
    }
    for (final fid in path.take(path.length - 1)) {
      await card.selectFile(fid, directory: true);
    }
    return type4
        ? card.selectType4File(path.last)
        : card.selectFile(path.last, directory: directory);
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
  bool get isMaster => address.path.isEmpty && address.aid == null;
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
}

class CpuDirectoryScan {
  final CpuDirectoryTree tree;
  final Map<String, int> cardStatuses;
  final CpuLiveFile? master;
  final bool incomplete;
  const CpuDirectoryScan(
    this.tree,
    this.cardStatuses,
    this.master,
    this.incomplete,
  );
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
  final dir = await probe(
    'EF.DIR',
    () => selectedMaster != null
        ? card.selectFile(0x2F00, directory: false)
        : card.selectPath([0x2F00], directory: false),
  );
  if (selectedMaster != null || dir != null) {
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
  final ppse = await probe(
    'PPSE',
    () => card.selectAid(Uint8List.fromList(_ppse)),
  );
  if (ppse != null) {
    final fci = _field(ppse.control, 0x6F);
    final advertised = _field(_field(fci, 0xA5), 0xBF0C);
    if (advertised != null)
      addApps(cpuDirectoryApplications([advertised], allowPath: false));
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

  final restored = selectedMaster == null
      ? null
      : await probe('MF', card.selectMaster);
  return CpuDirectoryScan(
    tree,
    Map.unmodifiable(statuses),
    restored,
    incomplete,
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
