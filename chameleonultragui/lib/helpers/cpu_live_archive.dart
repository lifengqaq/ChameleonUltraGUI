import 'dart:typed_data';

import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_directory.dart';

const cpuLiveArchiveFormat = 'iso7816-directory-v1';

class CpuLiveArchive {
  static const _maxBytes = 256 * 1024;
  static const _maxReads = 512;
  final _selections = <String, CpuLiveFile>{};
  final _parts = <(String, bool, int), CpuFileReply>{};
  int _bytes = 0;
  bool _limited = false;

  void selected(CpuFileAddress address, CpuLiveFile file) {
    if (_selections.containsKey(address.display) || _selections.length < 256) {
      _selections[address.display] = file;
    }
  }

  void read(
    CpuFileAddress address,
    CpuFileReply reply,
    int index,
    bool record,
  ) {
    final key = (address.display, record, index);
    final old = _parts[key];
    // A later preview must not replace wider data already read at this offset.
    if (old != null && old.data.length > reply.data.length) return;
    final next = _bytes - (old?.data.length ?? 0) + reply.data.length;
    if (next > _maxBytes || (_parts.length >= _maxReads && old == null)) {
      _limited = true;
      return;
    }
    _bytes = next;
    _parts[key] = reply;
  }

  /// Drop old bytes before a mutation because a lost reply leaves card state
  /// uncertain. A metadata change also invalidates the affected subtree.
  void invalidate(CpuFileAddress address, {bool subtree = false}) {
    final path = address.display;
    bool contains(String key) =>
        key == path || subtree && key.startsWith('$path/');
    if (subtree) _selections.removeWhere((key, _) => contains(key));
    _parts.removeWhere((key, reply) {
      if (!contains(key.$1)) return false;
      _bytes -= reply.data.length;
      return true;
    });
  }

  Map<String, dynamic> toJson(
    CpuDirectoryTree tree, {
    Iterable<String> unresolved = const [],
    CpuDirectoryScan? scan,
  }) {
    final missing = unresolved.toSet();
    return {
      'format': cpuLiveArchiveFormat,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'archiveOnly': true,
      'universalComplete': false,
      'keysExported': false,
      'captureLimited': _limited || scan?.incomplete == true,
      if (scan != null && scan.cardStatuses.isNotEmpty)
        'directoryStatuses': scan.cardStatuses,
      'entries': [for (final entry in tree.entries) _entry(entry, missing)],
    };
  }

  Map<String, dynamic> _entry(CpuDirectoryEntry entry, Set<String> unresolved) {
    final address = entry.address;
    final file = _selections[address.display];
    final aid = entry.applicationAid ?? address.aid ?? file?.aid;
    final capacity = entry.capacity ?? file?.size;
    return {
      'address': address.display,
      if (address.parent case final parent?) 'parent': parent.display,
      if ((file?.fid ?? address.fid) case final fid?) 'fid': cpuFidHex(fid),
      if (aid != null) 'aid': cpuAidHex(aid),
      if (address.sfi case final sfi?) 'sfi': sfi,
      'kind': entry.kind.name,
      if (entry.label.isNotEmpty) 'label': entry.label,
      if (address.metadataOnly || entry.type4) 'metadataOnly': true,
      if (capacity != null) 'sizeBytes': capacity,
      if (file?.recordLength case final length?) 'recordLength': length,
      if (file?.recordCount case final count?) 'recordCount': count,
      if (file != null && file.control.isNotEmpty)
        'fci': cpuAidHex(file.control),
      if (unresolved.contains(address.display)) 'selectNotFound': true,
      if (entry.type4File case final layout?)
        'type4': {
          'readAccess': layout.readAccess,
          'writeAccess': layout.writeAccess,
          if (layout.lengthBytes != null) 'lengthBytes': layout.lengthBytes,
        },
      'readRanges': [
        for (final item in _parts.entries)
          if (item.key.$1 == address.display)
            {
              if (item.key.$2) 'record': item.key.$3 else 'offset': item.key.$3,
              'status': cpuFidHex(item.value.status),
              'data': cpuAidHex(item.value.data),
            },
      ],
    };
  }
}

/// Keep imported ranges explicit. They are never converted into an emulator
/// image or interpreted as instructions to update a card.
Uint8List cpuArchiveRangeData(Object? hex) {
  if (hex is! String ||
      hex.length > 65536 ||
      hex.length.isOdd ||
      !RegExp(r'^[A-Fa-f0-9]*$').hasMatch(hex)) {
    throw const FormatException('Invalid CPU archive range');
  }
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
