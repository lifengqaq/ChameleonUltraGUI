import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_auth.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_change_pin.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_card.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_directory_view.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_emv_summary.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_profiles.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_directory.dart';
import 'package:chameleonultragui/helpers/cpu_directory_record.dart';
import 'package:chameleonultragui/helpers/cpu_dump.dart' show cpuFindTlv;
import 'package:chameleonultragui/helpers/cpu_live_archive.dart';
import 'package:chameleonultragui/helpers/cpu_transit_info.dart';
import 'package:chameleonultragui/helpers/cpu_type4.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

typedef _Link = ({ChameleonCommunicator device, Uint8List id});

enum _Command {
  open,
  openDf,
  openEf,
  parent,
  readCatalog,
  listApps,
  readBinary,
  readRecord,
  updateBinary,
  updateRecord,
  writeUnknown,
  createDf,
  createBinary,
  createRecords,
  deleteChild,
  deleteSelected,
  changePin,
}

enum _ManagerTool { profiles, slots, apdu, radio }

enum _ArchiveDestination { library, json }

typedef _FileAction = ({
  _Command command,
  IconData icon,
  String label,
  Future<void> Function() run,
});

class CpuCardManager extends StatefulWidget {
  const CpuCardManager({super.key});

  @override
  State<CpuCardManager> createState() => _CpuCardManagerState();
}

class _CpuCardManagerState extends State<CpuCardManager> {
  late final ChameleonGUIState _app = context.read<ChameleonGUIState>();
  _Link? _link;
  CardData? _identity;
  CpuLiveFile? _file, _directory;
  CpuFileAddress? _address, _directoryAddress;
  CpuDirectoryTree _tree = CpuDirectoryTree();
  CpuLiveArchive _archive = CpuLiveArchive();
  CpuDirectoryScan? _directoryScan;
  CpuMasterUnavailable? _masterIssue;
  CpuFileAddress? _missingSelection;
  final _missingAids = <String>{};
  CpuFileReply? _lastRead;
  ({int index, bool record}) _readPosition = (index: 0, record: false);
  int? _purseBalance;
  String? _purseError;
  String? _previewError;
  int _recordNumber = 1;
  int _lastRecordInFile = 254;
  String? _notice;
  bool _busy = false, _problem = false, _menuOpen = false;
  int _pendingIo = 0;

  AppLocalizations get _l => AppLocalizations.of(context)!;
  bool get _online =>
      _app.connector?.connected == true &&
      _app.connector?.device == ChameleonDevice.ultra &&
      _app.communicator != null;
  bool _ownsDevice(ChameleonCommunicator device) =>
      _online && identical(_app.communicator, device);
  bool get _active => _link != null && _ownsDevice(_link!.device);
  CpuTransitInfoProfile? get _transitProfile => _file?.isDirectory == true
      ? CpuTransitInfoProfile.forAid(_file?.aid ?? _address?.aid)
      : null;
  bool get _purseSelected => _transitProfile == CpuTransitInfoProfile.cityUnion;
  CpuDirectoryEntry? get _selectedEntry =>
      _address == null ? null : _tree.at(_address!);
  bool get _canArchive => _identity != null && !_tree.isEmpty;

  @override
  void dispose() {
    final link = _link;
    if (link != null) unawaited(_releaseQuietly(link));
    super.dispose();
  }

  Future<void> _releaseQuietly(_Link link) async {
    if (!_ownsDevice(link.device)) return;
    try {
      await link.device.hf14a4CloseManagedSession(link.id);
    } catch (_) {}
  }

  void _forgetSelection() {
    _file = null;
    _directory = null;
    _address = null;
    _missingSelection = null;
    _masterIssue = null;
    _directoryAddress = null;
    _lastRead = null;
    _purseBalance = null;
    _purseError = null;
    _previewError = null;
    _recordNumber = 1;
    _lastRecordInFile = 254;
  }

  void _forgetSession() {
    _link = null;
    _forgetSelection();
  }

  Future<void> _disconnect() async {
    final link = _link;
    setState(_forgetSession);
    if (link == null || !_ownsDevice(link.device)) return;
    try {
      await _deviceRequest(
        () => link.device.hf14a4CloseManagedSession(link.id),
      );
    } on CpuCommandError catch (error) {
      if (error.status != 0x76 && error.status != 0x66) rethrow;
    }
  }

  Future<void> _connect() async {
    if (!_online) throw StateError(_l.raw_ultra_required);
    final l = _l;
    final device = _app.communicator!;
    setState(() {
      _forgetSession();
      _identity = null;
      _tree = CpuDirectoryTree();
      _archive = CpuLiveArchive();
      _missingAids.clear();
      _directoryScan = null;
    });
    final (identity, id) = await _deviceRequest(() async {
      final commands = await device.getDeviceCapabilities();
      if (!commands.contains(ChameleonCommand.hf14a4ManagedSession.value)) {
        throw StateError(l.cpu_error_firmware);
      }
      if (!_ownsDevice(device)) throw StateError(l.cpu_manage_session_lost);
      if (!await device.isReaderDeviceMode()) {
        await device.setReaderDeviceMode(true);
      }
      if (!_ownsDevice(device)) throw StateError(l.cpu_manage_session_lost);
      return device.hf14a4OpenManagedSession();
    });
    final link = (device: device, id: id);
    if (!mounted || !_ownsDevice(device)) {
      await _releaseQuietly(link);
      throw StateError(l.cpu_manage_session_lost);
    }
    setState(() {
      _link = link;
      _identity = identity;
    });
    await _discoverDirectory();
  }

  Future<T> _deviceRequest<T>(Future<T> Function() send) async {
    if (mounted) setState(() => _pendingIo++);
    try {
      return await send();
    } finally {
      if (mounted) setState(() => _pendingIo--);
    }
  }

  Future<Uint8List> _transmit(_Link link, Uint8List apdu) async {
    try {
      if (_link != link || !_ownsDevice(link.device)) {
        throw StateError(_l.cpu_manage_session_lost);
      }
      final result = await _deviceRequest(
        () => link.device.hf14a4ManagedApdu(link.id, apdu),
      );
      if (!mounted || !_ownsDevice(link.device) || _link != link) {
        throw const CpuSessionEnded();
      }
      if (result.length < 2) throw const FormatException('Missing APDU status');
      return result;
    } catch (error) {
      if (mounted && _link == link) setState(_forgetSession);
      if (error is! CpuCommandError || error.status != 0x76) {
        unawaited(_releaseQuietly(link));
      }
      rethrow;
    }
  }

  CpuCardAccess get _card {
    final link = _link;
    if (link == null) throw StateError(_l.cpu_manage_session_lost);
    return CpuCardAccess((apdu) => _transmit(link, apdu));
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _problem = false;
    });
    try {
      await operation();
    } catch (error) {
      if (!mounted) return;
      final l = _l;
      if (error is CpuMasterUnavailable) setState(() => _masterIssue = error);
      final message = switch (error) {
        CpuMasterUnavailable() => l.cpu_manage_master_unverified,
        CpuFileStatus(:final word) => _status(word),
        CpuSessionEnded() ||
        CpuCommandError(status: 0x76) => l.cpu_manage_session_lost,
        CpuCommandError() => cpuCommandErrorText(l, error),
        StateError() => error.message,
        FormatException() => l.cpu_manage_unexpected_file,
        _ => l.cpu_error_no_response,
      };
      _message(message, problem: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text, {bool problem = false}) {
    if (mounted)
      setState(() {
        _notice = text;
        _problem = problem;
      });
  }

  String _status(int word) {
    final l = _l;
    final description = switch (word) {
      0x6282 => l.cpu_manage_end_of_file,
      0x6981 => l.cpu_manage_wrong_kind,
      0x6A81 || 0x6D00 || 0x6E00 => l.cpu_status_instruction,
      0x6A84 => l.cpu_manage_no_space,
      0x6A89 => l.cpu_manage_file_exists,
      _ => cpuStatusText(l, word),
    };
    return 'SW ${_hex(word, 4)} · $description';
  }

  CpuAuthHistory _scopeHistory() {
    final identity = _identity!;
    return cpuAuthHistoryForCard(
      identity.uid,
      identity.ats,
    ).inDirectory(_directoryAddress?.display ?? '');
  }

  Future<T> _withAccess<T>(String operation, Future<T> Function() send) {
    final file = _file!;
    final link = _link;
    final card = _card;
    final scope = _selectionLabel(file);
    final history = _scopeHistory();
    bool sameSelection() =>
        mounted && _active && _link == link && _file == file;
    return runCpuFileOperation(
      send,
      authorize: () async {
        if (!sameSelection()) throw const CpuSessionEnded();
        final accepted = await showCpuAuthentication(
          context,
          exchange: card.exchange,
          history: history,
          prefillCredential: false,
          operation: '$operation\n$scope\n${_status(0x6982)}',
        );
        if (!sameSelection()) throw const CpuSessionEnded();
        return accepted;
      },
    );
  }

  Future<void> _openMaster() => _select(
    (card) => card.openMasterForAccess(),
    address: const CpuFileAddress.master(),
  );

  Future<void> _select(
    Future<CpuLiveFile> Function(CpuCardAccess) select, {
    bool relative = false,
    CpuFileAddress? address,
    List<int>? expectedAid,
  }) async {
    final previousDirectory = relative ? _directory : null;
    final previousAddress = relative ? _directoryAddress : null;
    final card = _card;
    setState(_forgetSelection);
    final CpuLiveFile file;
    try {
      file = await select(card);
    } on CpuFileStatus catch (error) {
      if (mounted &&
          error.word == 0x6A82 &&
          address != null &&
          (expectedAid ?? address.aid) != null) {
        setState(() {
          _missingSelection = address;
          _missingAids.add(address.display);
        });
      }
      rethrow;
    }
    if (!mounted) return;
    final explicitFid = address?.fid;
    if (explicitFid != null && file.fid != null && file.fid != explicitFid) {
      throw const FormatException('File ID differs from the published path');
    }
    if (expectedAid != null &&
        file.aid != null &&
        cpuAidHex(file.aid!) != cpuAidHex(expectedAid)) {
      throw const FormatException(
        'Application differs from the published directory',
      );
    }
    final location =
        address ??
        (file.fid == 0x3F00
            ? const CpuFileAddress.master()
            : previousAddress != null && file.fid != null
            ? previousAddress.child(file.fid!)
            : null);
    setState(() {
      _file = file;
      _directory = file.isDirectory ? file : previousDirectory;
      _address = location;
      _directoryAddress = file.isDirectory
          ? location
          : location?.parent ?? previousAddress;
      if (location != null) {
        _missingAids.remove(location.display);
        _archive.selected(location, file);
        _tree.add(
          CpuDirectoryEntry(
            location,
            kind: file.kind,
            label: file.label,
            applicationAid: file.aid,
          ),
        );
        final sfi = file.directorySfi;
        if (location.metadataOnly && sfi != null) {
          _tree.add(
            CpuDirectoryEntry(
              CpuFileAddress.directoryRecords(location, sfi),
              kind: CpuLiveFileKind.record,
            ),
          );
        }
      }
    });
    _message(_status(0x9000));
  }

  Future<void> _chooseAid() async {
    final aid = await _prompt(_l.cpu_manage_select_aid, [
      _Field(_l.cpu_manage_aid),
    ], (values) => cpuHex(values.single, min: 5, max: 16));
    if (aid != null && mounted) {
      final address =
          _tree.applicationAddress(aid) ?? CpuFileAddress([], aid: aid);
      final entry = _tree.at(address);
      if (entry != null) {
        await _openEntry(entry);
      } else {
        await _select(
          (card) =>
              card.selectAidForAccess(aid, readOnly: address.metadataOnly),
          address: address,
        );
        await _loadPreview();
      }
    }
  }

  Future<void> _chooseFile(bool directory) async {
    await _locateFile(directory: directory);
  }

  Future<bool> _locateFile({
    required bool directory,
    String? title,
    String? help,
    bool preview = true,
    String initialPath = '',
  }) async {
    final l = _l;
    final path = await _prompt(
      title ?? (directory ? l.cpu_manage_open_df : l.cpu_manage_open_ef),
      [_Field(l.cpu_manage_path, initial: initialPath)],
      (values) {
        final parts = values.single.split('/').map(_readFid).toList();
        if (parts.length > 17 ||
            (parts.length > 1 && parts.first != 0x3F00) ||
            (!directory && parts.last == 0x3F00))
          throw const FormatException();
        return parts;
      },
      help: [if (help != null) help, l.cpu_manage_path_help].join('\n\n'),
    );
    if (path == null || !mounted) return false;
    if (path.length == 1 && path.first == 0x3F00) {
      await _openMaster();
    } else if (path.length == 1 &&
        _directoryAddress != null &&
        _directoryAddress?.metadataOnly != true) {
      await _select(
        (card) =>
            card.selectFile(path.first, directory: directory, preferFcp: true),
        relative: true,
      );
    } else {
      final address = CpuFileAddress(
        path.first == 0x3F00 ? path.sublist(1) : path,
      );
      await _select(
        (card) => address.open(card, directory: directory, preferFcp: true),
        address: address,
      );
    }
    if (!directory && preview) await _loadPreview();
    return mounted && _active && _file != null;
  }

  Future<void> _discoverDirectory() async {
    setState(() {
      _forgetSelection();
      _missingAids.clear();
    });
    final scan = await discoverCpuDirectory(
      _card,
      onRead: _archive.read,
      onSelect: _archive.selected,
    );
    if (!mounted) return;
    setState(() {
      _tree.merge(scan.tree);
      _directoryScan = scan;
      if (scan.master != null && scan.selectedAddress != null) {
        _file = _directory = scan.master;
        _address = _directoryAddress = scan.selectedAddress;
      }
    });
  }

  Future<void> _openEntry(
    CpuDirectoryEntry entry, {
    bool preview = true,
  }) async {
    if (_address?.display == entry.address.display && _file != null) {
      if (preview && _lastRead == null) await _loadPreview();
      return;
    }
    final parent = _directoryAddress;
    await _select(
      (card) => entry.address.open(
        card,
        directory: entry.isDirectory,
        type4: entry.type4,
        preferFcp: !entry.isDirectory && !entry.address.metadataOnly,
        selectedDirectory: parent,
      ),
      address: entry.address,
      expectedAid: entry.applicationAid,
      relative:
          parent != null && entry.address.parent?.display == parent.display,
    );
    if (preview) await _loadPreview();
  }

  Future<void> _loadPreview({int record = 1}) async {
    final file = _file;
    if (!mounted || !_active || file == null) return;
    if (file.isInternalEf || file.hasDataObjects) return;
    if (file.kind != CpuLiveFileKind.binary &&
        file.kind != CpuLiveFileKind.record)
      return;
    final isRecord = file.kind == CpuLiveFileKind.record;
    final entry = _selectedEntry;
    if (entry?.type4File?.readAccess case final access? when access != 0) {
      setState(() => _previewError = _l.cpu_type4_read_access);
      return;
    }
    final size = isRecord ? file.recordLength : file.size ?? entry?.capacity;
    if (size == 0) return;
    final length = math.min(
      math.max(1, size ?? 256),
      math.min(256, entry?.type4Header?.maxRead ?? 256),
    );
    final card = _card;
    setState(() {
      _previewError = null;
    });
    try {
      final response = isRecord
          ? await card.readRecord(record, length, sfi: _address?.sfi ?? 0)
          : entry?.address.shortBinary == true
          ? await card.readBinarySfi(entry!.address.sfi!, 0, length)
          : entry?.type4 == true && entry!.address.fid == cpuType4CcFid
          ? await readCpuType4Capability(card)
          : entry?.type4File?.lengthBytes != null
          ? await _readNdefPreview(card, entry!)
          : await card.readBinary(0, length);
      if (!mounted) return;
      setState(() {
        _recordNumber = record;
        _showRead(response, index: isRecord ? record : 0, record: isRecord);
      });
    } on CpuFileStatus catch (error) {
      if (!mounted) return;
      setState(() {
        if (isRecord && error.word == 0x6A83 && record > _recordNumber) {
          _lastRecordInFile = record - 1;
        } else {
          _recordNumber = record;
          _lastRead = null;
        }
        _previewError = error.word == 0x6982
            ? _l.cpu_tree_preview_protected
            : _status(error.word);
      });
    }
  }

  Future<CpuFileReply> _readNdefPreview(
    CpuCardAccess card,
    CpuDirectoryEntry entry,
  ) async {
    final width = entry.type4File!.lengthBytes!;
    final first = await card.readBinary(0, width);
    _archive.read(entry.address, first, 0, false);
    final length = first.data.length == width
        ? cpuNdefLength(first.data, width)
        : 0;
    if (first.status != 0x9000 ||
        length == 0 ||
        length > entry.type4File!.capacity - width)
      return first;
    final next = await card.readBinaryRange(
      width,
      math.min(length, 4096 - width),
      maxBlock: math.min(256, entry.type4Header!.maxRead),
    );
    return CpuFileReply.fromData(
      Uint8List.fromList([...first.data, ...next.data]),
      next.status,
    );
  }

  void _showRead(
    CpuFileReply reply, {
    required int index,
    required bool record,
  }) {
    _lastRead = reply;
    _readPosition = (index: index, record: record);
    if (_address case final address?)
      _archive.read(address, reply, index, record);
  }

  Future<void> _readPurseBalance() async {
    final file = _file;
    if (!mounted || !_active || !_purseSelected) return;
    final card = _card;
    setState(() {
      _purseBalance = null;
      _purseError = null;
    });
    try {
      final balance = await card.readCityUnionPurseBalance();
      if (mounted && identical(_file, file))
        setState(() => _purseBalance = balance);
    } on CpuFileStatus catch (error) {
      if (mounted && identical(_file, file))
        setState(() => _purseError = _status(error.word));
    } on FormatException {
      if (mounted && identical(_file, file))
        setState(() => _purseError = _l.cpu_manage_purse_bad_response);
    }
  }

  Future<void> _openTransitInfo() async {
    final parent = _address;
    if (parent == null || _transitProfile == null) return;
    final address = CpuFileAddress.shortBinary(
      parent,
      CpuTransitInfoProfile.infoSfi,
    );
    final reply = await _card.readBinarySfi(
      CpuTransitInfoProfile.infoSfi,
      0,
      256,
    );
    if (!mounted) return;
    setState(() {
      _tree.add(
        CpuDirectoryEntry(
          address,
          kind: CpuLiveFileKind.binary,
          label: _l.cpu_transit_info,
        ),
      );
      _file = CpuLiveFile.shortFile(binary: true);
      _address = address;
      _previewError = null;
      _purseBalance = null;
      _purseError = null;
      _showRead(reply, index: 0, record: false);
    });
    _message(_status(reply.status));
  }

  Future<void> _openParent() async {
    final parent = _address?.parent;
    if (parent == null) return;
    await _openEntry(
      _tree.at(parent) ??
          CpuDirectoryEntry(parent, kind: CpuLiveFileKind.directory),
    );
  }

  Future<void> _parseDirectoryRecords() async {
    final l = _l;
    final address = _address!;
    final scope = address.sfi == null ? address : address.parent!;
    final sfi = address.sfi ?? _file!.directorySfi;
    if (sfi == null) return;
    final card = _card;
    final recordAddress = CpuFileAddress.directoryRecords(scope, sfi);
    final (records, limited) = await _withAccess(
      l.cpu_tree_parse_records,
      () async {
        final records = <Uint8List>[];
        for (var number = 1; number <= 24; number++) {
          try {
            final reply = await card.readRecord(number, 256, sfi: sfi);
            _archive.read(recordAddress, reply, number, true);
            records.add(reply.data);
            if (reply.status == 0x6282 || reply.data.isEmpty)
              return (records, false);
          } on CpuFileStatus catch (e) {
            if (e.word == 0x6A83) return (records, false);
            rethrow;
          }
        }
        return (records, true);
      },
    );
    if (!mounted) return;
    var found = 0;
    setState(() => found = _tree.addDirectoryRecords(scope, records));
    _message(
      limited ? l.cpu_tree_incomplete : l.cpu_tree_parsed_records(found),
    );
  }

  Future<void> _readSelectedDirectory() async {
    final address = _address!;
    final applications = await _withAccess(
      _l.cpu_manage_list_apps,
      () => _card.readApplicationEntries(
        _file!,
        onRead: (reply, index, record) =>
            _archive.read(address, reply, index, record),
      ),
    );
    if (!mounted) return;
    setState(() {
      for (final app in applications) {
        _tree.addApplication(app);
      }
    });
    _message(applications.isEmpty ? _l.cpu_manage_no_apps : _status(0x9000));
  }

  Future<void> _read({required bool record}) async {
    final l = _l;
    final file = _file!;
    final entry = _selectedEntry;
    final shortBinary = _address?.shortBinary == true;
    final limit = shortBinary ? 256 : 32768;
    final knownLength = record
        ? file.recordLength
        : file.size ?? entry?.capacity;
    final suggestedLength =
        knownLength?.clamp(1, record || entry?.type4 == true ? 256 : 32768) ??
        256;
    final request = await _prompt(
      record ? l.cpu_manage_read_record : l.cpu_manage_read_binary,
      [
        _Field(
          record ? l.cpu_manage_record_number : l.cpu_manage_offset,
          initial: record ? '$_recordNumber' : '0',
          number: true,
        ),
        _Field(
          l.cpu_manage_read_length,
          initial: '$suggestedLength',
          number: true,
        ),
      ],
      (values) {
        final index = record
            ? _decimal(values.first, 1, 254)
            : _decimal(values.first, 0, limit - 1);
        final length = _decimal(values.last, 1, record ? 256 : limit - index);
        return (index, length);
      },
      action: l.read,
    );
    if (request == null || !mounted) return;
    setState(() {
      _lastRead = null;
      _previewError = null;
    });
    final (index, length) = request;
    final card = _card;
    final sfi = _address?.sfi ?? 0;
    final response = await _withAccess(
      record ? l.cpu_manage_read_record : l.cpu_manage_read_binary,
      () => record
          ? card.readRecord(index, length, sfi: sfi)
          : shortBinary
          ? card.readBinarySfi(sfi, index, length)
          : card.readBinaryRange(
              index,
              length,
              maxBlock: math.min(256, entry?.type4Header?.maxRead ?? 256),
            ),
    );
    if (mounted)
      setState(() {
        _showRead(response, index: index, record: record);
        if (record) _recordNumber = index;
      });
    _message(_status(response.status));
  }

  Future<void> _write({required bool record}) async {
    final l = _l;
    final file = _file!;
    final title = record
        ? l.cpu_manage_write_record
        : l.cpu_manage_write_binary;
    final fileLimit = record
        ? math.min(255, file.recordLength ?? 255)
        : math.min(32768, file.size ?? 32768);
    ({String name, Uint8List bytes})? imported;
    var importFailed = false;
    final request = await _prompt(
      title,
      [
        _Field(
          record ? l.cpu_manage_record_number : l.cpu_manage_offset,
          initial: record ? '$_recordNumber' : '0',
          number: true,
        ),
        _Field(l.cpu_manage_update_data, multiline: true),
      ],
      (values) {
        final index = record
            ? _decimal(values.first, 1, math.min(254, file.recordCount ?? 254))
            : _decimal(values.first, 0, 32767);
        final limit = record ? fileLimit : fileLimit - index;
        if (limit < 1) throw const FormatException();
        final data = imported?.bytes ?? cpuHex(values.last, min: 1, max: limit);
        if (data.length > limit ||
            record &&
                file.fixedRecordLength &&
                file.recordLength != null &&
                data.length != file.recordLength)
          throw const FormatException();
        return (index, data, imported?.name);
      },
      action: l.ok,
      help: l.cpu_manage_write_file_help,
      extra: (dialog, refresh) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: Text(l.cpu_archive_import_bin),
            onPressed: () async {
              try {
                final picked = await FilePicker.pickFile(
                  dialogTitle: l.cpu_archive_import_bin,
                  type: FileType.custom,
                  allowedExtensions: const ['bin'],
                );
                if (picked == null || !dialog.mounted) return;
                if (await picked.length() > fileLimit)
                  throw const FormatException();
                final buffer = BytesBuilder(copy: false);
                await for (final data in picked.readAsByteStream()) {
                  if (buffer.length + data.length > fileLimit)
                    throw const FormatException();
                  buffer.add(data);
                }
                if (buffer.isEmpty) throw const FormatException();
                if (dialog.mounted)
                  refresh(() {
                    imported = (name: picked.name, bytes: buffer.takeBytes());
                    importFailed = false;
                  });
              } catch (_) {
                if (dialog.mounted)
                  refresh(() {
                    imported = null;
                    importFailed = true;
                  });
              }
            },
          ),
          if (imported case final source?) ...[
            Text('${source.name} · ${l.cpu_manage_bytes(source.bytes.length)}'),
            IconButton(
              tooltip: l.cancel,
              onPressed: () => refresh(() => imported = null),
              icon: const Icon(Icons.close),
            ),
          ],
          if (importFailed) Text(l.cpu_archive_bad_bin(fileLimit)),
        ],
      ),
    );
    if (request == null || !mounted) return;
    final (index, data, source) = request;
    final location = record ? l.cpu_manage_record_number : l.cpu_manage_offset;
    final card = _card;
    var askedForAccess = false;
    await _mutate(
      title,
      [
        '$location: $index',
        if (source != null) source,
        l.cpu_manage_bytes(data.length),
      ].join('\n'),
      () => record
          ? card.updateRecord(index, data)
          : card.updateBinaryRange(
              index,
              data,
              write: (offset, block) {
                if (askedForAccess) return card.updateBinary(offset, block);
                return _withAccess(title, () async {
                  try {
                    return await card.updateBinary(offset, block);
                  } on CpuFileStatus catch (error) {
                    if (error.word == 0x6982 && error.originalRejected)
                      askedForAccess = true;
                    rethrow;
                  }
                });
              },
            ),
      allowAuthentication: record,
      invalidate: _address,
      successDetail: l.cpu_manage_write_count(data.length),
    );
  }

  bool _knownType4(CpuLiveFile file, CpuFileAddress? address) =>
      (address != null && _tree.at(address)?.type4 == true) ||
      cpuAidHex(file.aid ?? address?.aid ?? _directory?.aid ?? const []) ==
          cpuAidHex(cpuType4Aid);

  bool get _canWriteFile =>
      _file != null &&
      _file!.canChange &&
      !_knownType4(_file!, _address) &&
      !_file!.isDirectory &&
      _address?.metadataOnly != true;

  bool get _canCreateHere =>
      _file?.isDirectory == true &&
      _file!.canChange &&
      !_knownType4(_file!, _address) &&
      _address?.metadataOnly != true &&
      (_file!.fid != null || _file!.aid != null);

  Future<void> _writeFile() async {
    final l = _l;
    if (!_canWriteFile) {
      if (!await _locateFile(
        directory: false,
        title: l.cpu_manage_choose_write_file,
        help: l.cpu_manage_write_target_help,
        preview: false,
      ))
        return;
      if (!_canWriteFile) throw StateError(l.cpu_manage_no_write_target);
    }
    final kind = _file!.kind;
    if (kind == CpuLiveFileKind.unknown) {
      if (!mounted) return;
      final record = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l.cpu_manage_write_file),
          content: Text(l.cpu_manage_choose_write_kind),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(l.cancel),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(l.cpu_manage_write_binary),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l.cpu_manage_write_record),
            ),
          ],
        ),
      );
      if (mounted && record != null) await _write(record: record);
    } else {
      await _write(record: kind == CpuLiveFileKind.record);
    }
  }

  Future<void> _newDirectory() async {
    final l = _l;
    if (!_canCreateHere) {
      if (!await _locateFile(
        directory: true,
        title: l.cpu_manage_choose_parent,
        help: l.cpu_manage_new_directory_target_help,
        initialPath: '3F00',
      ))
        return;
      if (!_canCreateHere) throw StateError(l.cpu_manage_no_create_target);
    }
    await _create(CpuLiveFileKind.directory);
  }

  Future<void> _create(CpuLiveFileKind kind) async {
    final l = _l;
    final title = _createLabel(kind);
    final dir = kind == CpuLiveFileKind.directory;
    final binary = kind == CpuLiveFileKind.binary;
    final command = await _prompt(
      title,
      [
        _Field(l.cpu_manage_fid),
        if (dir) _Field(l.cpu_manage_optional_aid),
        if (binary) _Field(l.cpu_manage_new_length, number: true),
        if (kind == CpuLiveFileKind.record) ...[
          _Field(l.cpu_manage_new_record_length, number: true),
          _Field(l.cpu_manage_record_count, number: true),
        ],
      ],
      (values) {
        final fid = _mutationFid(values.first);
        final aid = dir && values[1].trim().isNotEmpty
            ? cpuHex(values[1], min: 5, max: 16)
            : null;
        final size = binary ? _decimal(values[1], 1, 32768) : null;
        final recordLength = !dir && !binary
            ? _decimal(values[1], 1, 255)
            : null;
        final count = !dir && !binary ? _decimal(values[2], 1, 254) : null;
        return (fid, aid, size, recordLength, count);
      },
      help: l.cpu_manage_create_help,
    );
    if (command == null || !mounted) return;
    final (fid, aid, size, length, count) = command;
    await _mutate(
      title,
      [
        'FID ${_hex(fid, 4)}',
        if (aid != null) 'AID ${bytesToHexSpace(aid)}',
        if (size != null) l.cpu_manage_bytes(size),
        if (length != null && count != null)
          '$count × ${l.cpu_manage_bytes(length)}',
      ].join('\n'),
      () => _card.createFile(
        fid,
        kind,
        aid: aid,
        size: size,
        recordLength: length,
        recordCount: count,
      ),
      directoryChange: true,
      onSuccess: _directoryAddress == null
          ? null
          : () {
              _tree.add(
                CpuDirectoryEntry(
                  _directoryAddress!.child(fid),
                  kind: kind,
                  applicationAid: aid,
                  capacity: size,
                ),
              );
            },
    );
  }

  Future<void> _deleteChild({int? targetFid, String? target}) async {
    final l = _l;
    final fid =
        targetFid ??
        await _prompt(l.cpu_manage_delete_child, [_Field(l.cpu_manage_fid)], (
          values,
        ) {
          final target = _mutationFid(values.single);
          if (_file?.fid == target) throw const FormatException();
          return target;
        });
    if (fid == null || !mounted) return;
    await _mutate(
      l.cpu_manage_delete_child,
      target ?? 'FID ${_hex(fid, 4)}',
      () => _card.deleteFile(fid),
      directoryChange: true,
      warning: l.cpu_manage_delete_warning,
      invalidate: _directoryAddress?.child(fid),
      invalidateSubtree: true,
      onSuccess: _directoryAddress == null
          ? null
          : () => _tree.remove(_directoryAddress!.child(fid)),
    );
  }

  Future<void> _deleteSelection() async {
    final address = _address!;
    final parent = address.parent!;
    final directory = _directoryAddress;
    if (_file?.isDirectory == true || directory?.display != parent.display) {
      await _select(
        (card) => parent.open(card, directory: true),
        address: parent,
      );
    }
    if (!mounted || !_active) return;
    // The selected EF shares its parent DF; no reselect is needed there.
    await _deleteChild(targetFid: address.fid, target: address.display);
  }

  Future<void> _changePin() async {
    final l = _l;
    final request = await showCpuPinChange(context, _selectionLabel(_file!));
    if (request == null || !mounted) return;
    final settings = request.settings;
    final history = _scopeHistory();
    final previous = history.forSettings(settings);
    if (previous?.blocked == true) {
      _message(l.cpu_auth_blocked, problem: true);
      return;
    }
    final card = _card;
    await _mutate(
      l.cpu_manage_change_pin,
      'P2 ${_hex(settings.reference, 2)}',
      () async {
        try {
          final reply = await card.changePin(
            settings.reference,
            settings.pinEncoding,
            request.previous,
            request.next,
          );
          history.record(settings, const CpuAuthResult(0x9000));
          return reply;
        } on CpuFileStatus catch (error) {
          final result = CpuAuthResult(error.word);
          if (result.remaining != null || result.blocked)
            history.record(settings, result);
          rethrow;
        }
      },
      allowAuthentication: false,
      allowRetryWarning: false,
      warning: previous?.remaining == 1 ? l.cpu_auth_last_warning : null,
    );
  }

  Future<void> _mutate(
    String title,
    String target,
    Future<CpuFileReply> Function() send, {
    bool directoryChange = false,
    String? warning,
    VoidCallback? onSuccess,
    bool allowAuthentication = true,
    bool allowRetryWarning = true,
    CpuFileAddress? invalidate,
    bool invalidateSubtree = false,
    String? successDetail,
  }) async {
    final l = _l;
    if (!_active || _file == null) throw StateError(l.cpu_manage_session_lost);
    final link = _link;
    final file = _file!;
    final address = _selectionLabel(file);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          'UID ${bytesToHexSpace(_identity!.uid)}\n'
          '$address\n$target\n\n${l.cpu_manage_confirm_write}'
          '${warning == null ? '' : '\n$warning'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.ok),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    if (!_active || _link != link || _file != file)
      throw StateError(l.cpu_manage_session_lost);
    setState(() {
      _lastRead = null;
      if (invalidate != null)
        _archive.invalidate(invalidate, subtree: invalidateSubtree);
    });
    try {
      final response = allowAuthentication
          ? await _withAccess(title, send)
          : await send();
      if (!mounted) return;
      if (directoryChange)
        setState(() {
          onSuccess?.call();
          _forgetSelection();
        });
      _message(
        [
          title,
          if (successDetail != null) successDetail,
          _status(response.status),
        ].join(' · '),
      );
    } on CpuPartialWrite catch (error) {
      if (!mounted) return;
      final cause = error.cause;
      final definiteRejection =
          cause is CpuFileStatus &&
          cause.originalRejected &&
          cause.word >> 8 != 0x63 &&
          cause.word >> 8 != 0x65;
      final detail = [
        if (cause is CpuFileStatus) _status(cause.word),
        if (!definiteRejection) l.cpu_manage_write_unknown,
      ].join(' · ');
      _message(
        '${l.cpu_manage_write_partial(error.confirmedBytes)}\n$detail',
        problem: true,
      );
    } on CpuFileStatus catch (error) {
      final remaining = CpuAuthResult(error.word).remaining;
      if (!allowRetryWarning && remaining != null) {
        _message(
          '${_status(error.word)}\n${_l.cpu_auth_tries}: $remaining',
          problem: true,
        );
      } else if (!error.originalRejected ||
          error.word >> 8 == 0x63 ||
          error.word >> 8 == 0x65) {
        if (mounted && directoryChange) setState(_forgetSelection);
        _message(
          '${_status(error.word)}\n${l.cpu_manage_write_unknown}',
          problem: true,
        );
      } else {
        rethrow;
      }
    } on CpuSessionEnded {
      rethrow;
    } catch (_) {
      if (mounted && _link == link) {
        setState(_forgetSession);
        if (link != null) unawaited(_releaseQuietly(link));
      }
      _message(l.cpu_manage_write_unknown, problem: true);
    }
  }

  Future<void> _saveIdentity() async {
    final identity = _identity!;
    final uid = bytesToHexSpace(identity.uid);
    final l = _l;
    final name = await _prompt(
      l.save_only_uid,
      [_Field(l.name, initial: 'CPU $uid')],
      (values) {
        final name = values.single.trim();
        if (name.isEmpty) throw const FormatException();
        return name;
      },
      action: l.save,
    );
    if (name == null || !mounted) return;
    final prefs = _app.sharedPreferencesProvider;
    prefs.setCards(
      prefs.getCards()..add(
        CardSave(
          uid: uid,
          name: name,
          tag: TagType.hf14a4,
          atqa: identity.atqa,
          sak: identity.sak,
          ats: identity.ats,
          data: [],
        ),
      ),
    );
    _app.changesMade();
    _message(l.cpu_done);
  }

  Future<void> _saveDirectory() async {
    final l = _l;
    final identity = _identity!;
    final destination = await showDialog<_ArchiveDestination>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.cpu_archive_save),
        content: Text(l.cpu_archive_help),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l.cancel),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialog, _ArchiveDestination.json),
            child: Text(l.cpu_archive_export_json),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, _ArchiveDestination.library),
            child: Text(l.cpu_archive_to_library),
          ),
        ],
      ),
    );
    if (destination == null || !mounted) return;
    final uid = bytesToHexSpace(identity.uid);
    final name = destination == _ArchiveDestination.json
        ? 'CPU-${cpuAidHex(identity.uid)}-directory'
        : await _prompt(
            l.cpu_archive_to_library,
            [_Field(l.name, initial: 'CPU $uid')],
            (values) {
              final name = values.single.trim();
              if (name.isEmpty) throw const FormatException();
              return name;
            },
            action: l.save,
          );
    if (name == null || !mounted) return;
    final card = CardSave(
      uid: uid,
      name: name,
      tag: TagType.hf14a4,
      atqa: identity.atqa,
      sak: identity.sak,
      ats: identity.ats,
      data: [],
      extraData: CardSaveExtra(
        cpuDump: _archive.toJson(
          _tree,
          unresolved: _missingAids,
          scan: _directoryScan,
        ),
      ),
    );
    if (destination == _ArchiveDestination.json) {
      await saveTag(card, context, false);
      return;
    }
    final prefs = _app.sharedPreferencesProvider;
    prefs.setCards(prefs.getCards()..add(card));
    _app.changesMade();
    _message(l.cpu_done);
  }

  Future<void> _exportPreview(CpuFileReply reply) async {
    final position = _readPosition;
    final name = _address?.fid == null
        ? 'cpu'
        : 'cpu-${cpuFidHex(_address!.fid!)}';
    final suffix = position.record ? 'record' : 'offset';
    await FilePicker.saveFile(
      dialogTitle: _l.cpu_archive_export_bin,
      fileName: '$name-$suffix-${position.index}.bin',
      bytes: reply.data,
    );
  }

  Future<void> _openTool(Widget page, {bool dialog = false}) async {
    await _disconnect();
    if (!mounted) return;
    if (dialog) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => page,
      );
    } else {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page));
    }
  }

  Future<T?> _prompt<T>(
    String title,
    List<_Field> fields,
    T Function(List<String>) parse, {
    String? action,
    String? help,
    Widget Function(BuildContext, StateSetter)? extra,
  }) {
    final l = _l;
    final values = fields.map((field) => field.initial).toList();
    var invalid = false;
    return showDialog<T>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (help != null) Text(help),
                  for (var index = 0; index < fields.length; index++)
                    TextFormField(
                      initialValue: fields[index].initial,
                      autofocus: index == 0,
                      decoration: InputDecoration(
                        labelText: fields[index].label,
                      ),
                      keyboardType: fields[index].number
                          ? TextInputType.number
                          : TextInputType.text,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLines: fields[index].multiline ? 4 : 1,
                      onChanged: (value) => values[index] = value,
                    ),
                  if (extra != null) extra(context, refresh),
                  if (invalid)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l.cpu_manage_invalid,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.cancel),
            ),
            FilledButton(
              child: Text(action ?? l.ok),
              onPressed: () {
                try {
                  Navigator.pop(context, parse(values));
                } on FormatException {
                  refresh(() => invalid = true);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  String _selectionLabel(CpuLiveFile file) {
    final address = _address;
    final parent = _directory;
    if (address != null) {
      return address.aid != null || file.aid == null
          ? address.display
          : '${address.display} · AID ${bytesToHexSpace(file.aid!)}';
    }
    return '${parent == null || parent == file ? '' : '${_describe(parent)} / '}${_describe(file)}';
  }

  String _describe(CpuLiveFile file) {
    final details = [
      if (file.fid != null)
        '${file.fid == 0x3F00 ? 'MF' : 'FID'} ${_hex(file.fid!, 4)}',
      if (file.aid != null) 'AID ${bytesToHexSpace(file.aid!)}',
    ];
    return details.isEmpty ? _l.cpu_manage_selected_file : details.join(' · ');
  }

  String _kind(CpuLiveFileKind kind) => switch (kind) {
    CpuLiveFileKind.directory => _l.cpu_manage_directory_kind,
    CpuLiveFileKind.binary => _l.cpu_manage_binary_kind,
    CpuLiveFileKind.record => _l.cpu_manage_record_kind,
    CpuLiveFileKind.unknown => _l.cpu_manage_unknown_kind,
  };

  String _createLabel(CpuLiveFileKind kind) => switch (kind) {
    CpuLiveFileKind.directory => _l.cpu_files_add_df,
    CpuLiveFileKind.binary => _l.cpu_files_add_binary,
    _ => _l.cpu_manage_add_fixed_records,
  };

  List<_FileAction> _fileActions(
    CpuLiveFileKind kind,
    CpuFileAddress? address, {
    required bool canChange,
    required bool named,
    required bool hasCatalog,
    bool canRead = true,
  }) {
    final l = _l;
    canChange = canChange && address?.metadataOnly != true;
    final canDelete =
        canChange &&
        address?.parent != null &&
        address!.fid != null &&
        !const [0, 0x3F00, 0x3FFF, 0xFFFF].contains(address.fid);
    final actions = <_FileAction>[];
    void add(
      _Command command,
      IconData icon,
      String label,
      Future<void> Function() run,
    ) => actions.add((command: command, icon: icon, label: label, run: run));
    if (address?.parent != null) {
      add(
        _Command.parent,
        Icons.arrow_upward,
        l.cpu_manage_parent,
        _openParent,
      );
    }
    if (hasCatalog) {
      add(
        _Command.readCatalog,
        Icons.account_tree_outlined,
        l.cpu_tree_parse_records,
        _parseDirectoryRecords,
      );
    }
    if (kind == CpuLiveFileKind.directory) {
      if (address?.metadataOnly != true) {
        add(
          _Command.openDf,
          Icons.folder_open,
          l.cpu_manage_open_df,
          () => _chooseFile(true),
        );
        add(
          _Command.openEf,
          Icons.insert_drive_file_outlined,
          l.cpu_manage_open_ef,
          () => _chooseFile(false),
        );
      }
      if (canChange && named) {
        add(
          _Command.createDf,
          Icons.create_new_folder_outlined,
          _createLabel(CpuLiveFileKind.directory),
          () => _create(CpuLiveFileKind.directory),
        );
        add(
          _Command.createBinary,
          Icons.note_add_outlined,
          _createLabel(CpuLiveFileKind.binary),
          () => _create(CpuLiveFileKind.binary),
        );
        add(
          _Command.createRecords,
          Icons.playlist_add,
          _createLabel(CpuLiveFileKind.record),
          () => _create(CpuLiveFileKind.record),
        );
        add(
          _Command.deleteChild,
          Icons.delete_outline,
          l.cpu_manage_delete_child,
          _deleteChild,
        );
      }
    } else {
      if (canRead && address?.display == '3F00/2F00') {
        add(
          _Command.listApps,
          Icons.list_alt,
          l.cpu_manage_list_apps,
          _readSelectedDirectory,
        );
      }
      if (canRead &&
          (kind == CpuLiveFileKind.binary || kind == CpuLiveFileKind.unknown)) {
        add(
          _Command.readBinary,
          Icons.download,
          l.cpu_manage_read_binary,
          () => _read(record: false),
        );
      }
      if (canRead &&
          (kind == CpuLiveFileKind.record || kind == CpuLiveFileKind.unknown)) {
        add(
          _Command.readRecord,
          Icons.download,
          l.cpu_manage_read_record,
          () => _read(record: true),
        );
      }
      if (canChange && kind == CpuLiveFileKind.binary) {
        add(
          _Command.updateBinary,
          Icons.edit_outlined,
          l.cpu_manage_write_binary,
          () => _write(record: false),
        );
      }
      if (canChange && kind == CpuLiveFileKind.record) {
        add(
          _Command.updateRecord,
          Icons.edit_outlined,
          l.cpu_manage_write_record,
          () => _write(record: true),
        );
      }
      if (canChange && kind == CpuLiveFileKind.unknown) {
        add(
          _Command.writeUnknown,
          Icons.edit_outlined,
          l.cpu_manage_write_file,
          _writeFile,
        );
      }
    }
    if (canDelete) {
      add(
        _Command.deleteSelected,
        Icons.delete_outline,
        l.cpu_manage_delete_selected,
        _deleteSelection,
      );
    }
    if (canChange)
      add(
        _Command.changePin,
        Icons.password,
        l.cpu_manage_change_pin,
        _changePin,
      );
    return actions;
  }

  List<_FileAction> _actionsFor(CpuLiveFile file) => _fileActions(
    file.kind,
    _address,
    canChange: file.canChange && !_knownType4(file, _address),
    canRead:
        !file.hasDataObjects &&
        !file.isInternalEf &&
        (_selectedEntry?.type4File?.readAccess ?? 0) == 0,
    named: file.fid != null || file.aid != null,
    hasCatalog:
        (_address?.sfi != null && _address?.shortBinary != true) ||
        (_address?.metadataOnly == true && file.directorySfi != null),
  );

  Future<void> _entryMenu(CpuDirectoryEntry entry, Offset position) async {
    if (_busy || _menuOpen || !_active) return;
    final link = _link;
    final address = entry.address;
    final isSelected = _address?.display == address.display && _file != null;
    final actions = isSelected
        ? _actionsFor(_file!)
        : _fileActions(
            entry.kind,
            address,
            canChange:
                !entry.type4 &&
                cpuAidHex(entry.applicationAid ?? const []) !=
                    cpuAidHex(cpuType4Aid),
            canRead: (entry.type4File?.readAccess ?? 0) == 0,
            named: address.fid != null || address.aid != null,
            hasCatalog:
                (address.sfi != null && !address.shortBinary) ||
                _tree
                    .childrenOf(address)
                    .any(
                      (child) =>
                          child.address.sfi != null &&
                          !child.address.shortBinary,
                    ),
          );
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    _menuOpen = true;
    _Command? command;
    try {
      command = await showMenu<_Command>(
        context: context,
        position: RelativeRect.fromSize(
          overlay.globalToLocal(position) & Size.zero,
          overlay.size,
        ),
        items: [
          PopupMenuItem(
            value: _Command.open,
            child: _menuLabel(
              Icons.visibility_outlined,
              _l.cpu_tree_open_entry,
            ),
          ),
          for (final action in actions)
            PopupMenuItem(
              value: action.command,
              child: _menuLabel(action.icon, action.label),
            ),
        ],
      );
    } finally {
      _menuOpen = false;
    }
    if (command == null || !mounted || !_active || _link != link) return;
    await _run(() async {
      await _openEntry(entry, preview: command == _Command.open);
      if (!mounted || !_active || _file == null || command == _Command.open)
        return;
      final action = _actionsFor(_file!)
          .where((item) => item.command == command)
          .firstOrNull;
      if (action == null) {
        _message(_l.cpu_manage_no_actions, problem: true);
      } else {
        await action.run();
      }
    });
  }

  Widget _menuLabel(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );

  Widget _button(IconData icon, String title, VoidCallback? run) =>
      OutlinedButton.icon(
        icon: Icon(icon),
        label: Text(title),
        onPressed: run == null || _busy ? null : run,
      );

  Future<void> _chooseTool(_ManagerTool tool) async {
    if (_busy) return;
    switch (tool) {
      case _ManagerTool.profiles:
        await _run(() => _openTool(const CpuProfilesPage()));
      case _ManagerTool.slots:
        await _run(() => _openTool(const SlotManagerPage()));
      case _ManagerTool.apdu:
        await _run(() => _openTool(const CpuCardMenu(), dialog: true));
      case _ManagerTool.radio:
        await showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(_l.cpu_radio_details),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: CpuIdentityPanel(identity: _identity),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(_l.close),
              ),
            ],
          ),
        );
    }
  }

  Widget _connectionBar(AppLocalizations l) {
    final active = _active, online = _online, identity = _identity;
    final status = active
        ? l.cpu_manage_session_active
        : online
        ? l.cpu_manage_session_idle
        : l.raw_ultra_required;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              icon: Icon(active ? Icons.refresh : Icons.contactless),
              label: Text(
                active ? l.cpu_manage_reselect : l.cpu_manage_connect,
              ),
              onPressed: online && !_busy
                  ? () => _run(() async {
                      if (active) await _disconnect();
                      if (mounted) await _connect();
                    })
                  : null,
            ),
            _button(
              Icons.power_settings_new,
              l.cpu_disconnect,
              active ? () => _run(_disconnect) : null,
            ),
            _button(
              Icons.save_outlined,
              l.save_only_uid,
              identity == null ? null : () => _run(_saveIdentity),
            ),
            _button(
              Icons.snippet_folder_outlined,
              l.cpu_archive_save,
              _canArchive ? () => _run(_saveDirectory) : null,
            ),
            _button(
              Icons.edit_note,
              l.cpu_manage_write_file,
              active ? () => _run(_writeFile) : null,
            ),
            _button(
              Icons.create_new_folder_outlined,
              l.cpu_manage_new_directory,
              active ? () => _run(_newDirectory) : null,
            ),
            Text(
              identity == null
                  ? status
                  : 'UID ${bytesToHexSpace(identity.uid)} · $status',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _treePane(AppLocalizations l) {
    final scan = _directoryScan;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.cpu_tree_title,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: l.cpu_tree_refresh,
                  onPressed: _busy ? null : () => _run(_discoverDirectory),
                ),
                IconButton(
                  icon: const Icon(Icons.home_outlined),
                  tooltip: l.cpu_tree_root,
                  onPressed: _busy ? null : () => _run(_openMaster),
                ),
                PopupMenuButton<_Command>(
                  tooltip: l.cpu_tree_manual,
                  enabled: !_busy,
                  icon: const Icon(Icons.search),
                  onSelected: (command) => _run(
                    command == _Command.open
                        ? _chooseAid
                        : () => _chooseFile(command == _Command.openDf),
                  ),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _Command.open,
                      child: Text(l.cpu_manage_select_aid),
                    ),
                    PopupMenuItem(
                      value: _Command.openDf,
                      child: Text(l.cpu_manage_open_df),
                    ),
                    PopupMenuItem(
                      value: _Command.openEf,
                      child: Text(l.cpu_manage_open_ef),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              primary: false,
              key: const PageStorageKey('cpu-explorer-tree-scroll'),
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 12),
              children: [
                if (!_tree.isEmpty)
                  CpuDirectoryView(
                    tree: _tree,
                    selected: _address ?? _missingSelection,
                    missingAids: {
                      ..._missingAids,
                      if (scan != null)
                        for (final issue in scan.cardStatuses.entries)
                          if (issue.value == 0x6A82 &&
                              issue.key.contains('/SFI '))
                            issue.key,
                    },
                    onOpen: _busy
                        ? null
                        : (entry) => _run(() => _openEntry(entry)),
                    onContextMenu: _busy ? null : _entryMenu,
                  ),
                if (scan != null &&
                    (_tree.isEmpty ||
                        (_tree.childrenOf(null).length == 1 &&
                            _tree.childrenOf(null).single.isMaster &&
                            _tree
                                .childrenOf(const CpuFileAddress.master())
                                .isEmpty)))
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(l.cpu_tree_no_entries),
                  ),
                if (scan?.incomplete == true)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(l.cpu_tree_incomplete),
                  ),
                if (scan != null)
                  for (final item in scan.cardStatuses.entries)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('${item.key}: ${_status(item.value)}'),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _recordSummary(
    AppLocalizations l,
    Uint8List bytes,
    CpuDirectoryFormat format,
  ) {
    final inspected = inspectCpuDirectoryRecord(bytes, format: format);
    return [
      for (final field in inspected.fields)
        CpuInfoRow(
          label: switch (field.tag) {
            0x4F => 'AID (4F)',
            0x50 => l.cpu_tree_app_label,
            0x51 => l.cpu_preview_df_path,
            0x87 => l.cpu_preview_priority,
            _ => 'DDF (9D)',
          },
          value: field.tag == 0x50
              ? cpuDirectoryLabel(field.value)
              : cpuAidHex(field.value),
        ),
      for (final issue in inspected.issues)
        Text(switch (issue.kind) {
          CpuDirectoryIssueKind.structure =>
            format == CpuDirectoryFormat.pseRecord
                ? l.cpu_tree_record_structure
                : l.cpu_preview_app_template,
          CpuDirectoryIssueKind.lengthBytes => l.cpu_tree_record_length_error(
            _hex(issue.tag!, 2),
            issue.offset,
            issue.expected,
            issue.available,
          ),
          CpuDirectoryIssueKind.value => l.cpu_tree_record_value_error(
            _hex(issue.tag!, 2),
            issue.offset,
            issue.expected,
            issue.available,
          ),
          _ => l.cpu_tree_record_tlv_error(issue.offset),
        }, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ];
  }

  List<Widget> _type4Summary(
    AppLocalizations l,
    CpuDirectoryEntry entry,
    Uint8List bytes,
  ) {
    try {
      if (entry.address.fid == cpuType4CcFid) {
        final cc = parseCpuType4Capability(bytes);
        return [
          Text(l.cpu_type4_cc, style: Theme.of(context).textTheme.titleSmall),
          CpuInfoRow(label: 'CCLEN', value: '${cc.header.size}'),
          CpuInfoRow(
            label: l.cpu_type4_mapping,
            value: '${cc.header.version >> 4}.${cc.header.version & 15}',
          ),
          CpuInfoRow(
            label: 'MLe / MLc',
            value: '${cc.header.maxRead} / ${cc.header.maxWrite}',
          ),
          for (final file in cc.files)
            CpuInfoRow(
              label: 'FID ${cpuFidHex(file.fid)}',
              value:
                  '${l.cpu_manage_bytes(file.capacity)} · '
                  '${l.cpu_type4_access(_hex(file.readAccess, 2), _hex(file.writeAccess, 2))}',
            ),
        ];
      }
      final ndef = entry.type4File;
      if (ndef?.lengthBytes case final width?) {
        final size = cpuNdefLength(bytes, width);
        if (size > ndef!.capacity - width) {
          throw const FormatException('NDEF exceeds CC capacity');
        }
        final available = bytes.length - width;
        final decoded = size > 0 && size <= available
            ? parseCpuNdefMessage(
                Uint8List.sublistView(bytes, width, width + size),
              )
            : const <CpuNdefRecord>[];
        return [
          CpuInfoRow(
            label: width == 2 ? 'NLEN' : 'ENLEN',
            value: l.cpu_manage_bytes(size),
          ),
          if (size == 0) Text(l.cpu_type4_empty),
          if (size > available) Text(l.cpu_type4_partial(available, size)),
          for (final (index, record) in decoded.indexed) ...[
            CpuInfoRow(
              label: 'NDEF #${index + 1}',
              value:
                  '${record.type.isEmpty ? 'TNF ${record.tnf}' : record.type} · '
                  '${l.cpu_manage_bytes(record.payloadLength)}'
                  '${record.id.isEmpty ? '' : ' · ID ${cpuAidHex(record.id)}'}',
            ),
            if (record.text case final value?)
              SelectableText('${record.language} · $value'),
            if (record.uri case final uri?) SelectableText(uri),
          ],
        ];
      }
    } on FormatException {
      return [Text(l.cpu_type4_bad_format)];
    }
    return const [];
  }

  List<Widget> _controlSummary(AppLocalizations l, CpuLiveFile file) {
    final control = file.controlFields;
    return [
      for (final field in control.entries)
        CpuInfoRow(
          label: switch (field.key) {
            0x80 => l.cpu_preview_file_size,
            0x81 => l.cpu_preview_allocated_size,
            0x82 => l.cpu_preview_descriptor,
            0x83 => 'FID (83)',
            0x84 => 'DF / AID (84)',
            0x88 => 'SFI (88)',
            0x8A => l.cpu_preview_lifecycle,
            _ => l.cpu_preview_security(_hex(field.key, 2)),
          },
          value: bytesToHexSpace(field.value),
        ),
      SelectableText(bytesToHexSpace(file.control)),
    ];
  }

  Uint8List? _inlineDirectory(CpuLiveFile? file) {
    if (file == null || !cpuIsPaymentDirectoryName(file.aid)) return null;
    final fci = cpuFindTlv(file.control, 0x6F, recursive: false).firstOrNull;
    if (fci == null) return null;
    final data = cpuFindTlv(fci, 0xA5, recursive: false).firstOrNull;
    return data == null
        ? null
        : cpuFindTlv(data, 0xBF0C, recursive: false).firstOrNull;
  }

  String _transitName(AppLocalizations l, CpuTransitInfoProfile profile) =>
      switch (profile) {
        CpuTransitInfoProfile.cityUnion => l.cpu_transit_city_union,
        CpuTransitInfoProfile.tUnion => l.cpu_transit_t_union,
      };

  List<Widget> _transitSummary(
    AppLocalizations l,
    CpuFileAddress address,
    Uint8List bytes,
  ) {
    final parent = address.parent;
    final profile = CpuTransitInfoProfile.forAid(
      parent == null ? null : _tree.at(parent)?.applicationAid ?? parent.aid,
    );
    if (profile == null) return const [];
    try {
      final info = parseCpuTransitInfo(profile, bytes);
      return [
        Text('${_transitName(l, profile)} · ${l.cpu_transit_info}'),
        if (info.cityCode case final code?)
          CpuInfoRow(label: l.cpu_transit_city_code, value: code),
        if (info.version != 0)
          CpuInfoRow(label: l.cpu_transit_version, value: '${info.version}'),
        if (info.issued case final date?)
          CpuInfoRow(label: l.cpu_transit_issued, value: date),
        if (info.expires case final date?)
          CpuInfoRow(label: l.cpu_transit_expires, value: date),
      ];
    } on FormatException {
      return [Text(l.cpu_transit_incomplete)];
    }
  }

  List<Widget> _masterDetails(AppLocalizations l, CpuMasterUnavailable issue) {
    final observed = issue.observed;
    final name = observed?.aid;
    return [
      if (name != null)
        Text(
          l.cpu_manage_master_alias(
            cpuIsPaymentDirectoryName(name)
                ? String.fromCharCodes(name)
                : cpuAidHex(name),
          ),
        ),
      if (issue.status case final word?) Text(_status(word)),
      Text(l.cpu_manage_master_need_parent),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          _button(
            Icons.folder_open,
            l.cpu_manage_open_known_fid,
            () => _run(() => _chooseFile(true)),
          ),
          _button(Icons.apps, l.cpu_manage_select_aid, () => _run(_chooseAid)),
        ],
      ),
      if (observed != null && observed.control.isNotEmpty)
        ExpansionTile(
          title: const Text('FCI / FCP'),
          tilePadding: EdgeInsets.zero,
          children: _controlSummary(l, observed),
        ),
    ];
  }

  Widget _dataPane(AppLocalizations l, double actionHeight) {
    final file = _file, address = _address, read = _lastRead;
    final actions = file == null ? <_FileAction>[] : _actionsFor(file);
    final isRecord = file?.kind == CpuLiveFileKind.record;
    final maxRecord = math.min(file?.recordCount ?? 254, _lastRecordInFile);
    final entry = _selectedEntry;
    final inline = _inlineDirectory(file);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isRecord
                        ? l.cpu_tree_record_title(_recordNumber)
                        : l.cpu_tree_preview,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (isRecord) ...[
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    tooltip: l.cpu_tree_previous_record,
                    onPressed: _busy || _recordNumber <= 1
                        ? null
                        : () => _run(
                            () => _loadPreview(record: _recordNumber - 1),
                          ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    tooltip: l.cpu_tree_next_record,
                    onPressed: _busy || _recordNumber >= maxRecord
                        ? null
                        : () => _run(
                            () => _loadPreview(record: _recordNumber + 1),
                          ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              key: ValueKey('cpu-detail:${address?.display}'),
              primary: false,
              padding: const EdgeInsets.all(14),
              children: [
                if (file == null) ...[
                  if (_masterIssue case final issue?)
                    ..._masterDetails(l, issue)
                  else if (_missingSelection case final missing?) ...[
                    Text(
                      missing.display,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(l.cpu_manage_missing_aid_help),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: _button(
                        Icons.folder_open,
                        l.cpu_manage_open_known_fid,
                        () => _run(() async {
                          await _locateFile(
                            directory: true,
                            title: l.cpu_manage_open_known_fid,
                          );
                        }),
                      ),
                    ),
                  ] else
                    Text(l.cpu_tree_pick_entry),
                ] else ...[
                  if (_purseSelected) _pursePane(l),
                  if (_transitProfile case final profile?) ...[
                    CpuInfoRow(
                      label: l.cpu_transit_profile,
                      value: _transitName(l, profile),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: _button(
                        Icons.description_outlined,
                        l.cpu_transit_read_info,
                        () => _run(_openTransitInfo),
                      ),
                    ),
                  ],
                  if (file.hasDataObjects) Text(l.cpu_preview_data_objects),
                  if (file.isInternalEf) Text(l.cpu_preview_internal),
                  if (inline != null)
                    ..._recordSummary(l, inline, CpuDirectoryFormat.ppseInline),
                  if (_previewError != null)
                    Text(
                      _previewError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (read != null) ...[
                    if (address?.sfi != null &&
                        address?.shortBinary != true &&
                        _readPosition.record)
                      ..._recordSummary(
                        l,
                        read.data,
                        CpuDirectoryFormat.pseRecord,
                      ),
                    if (address?.display == '3F00/2F00' &&
                        (_readPosition.record || _readPosition.index == 0))
                      ..._recordSummary(l, read.data, CpuDirectoryFormat.efDir),
                    if (entry?.type4 == true &&
                        !_readPosition.record &&
                        _readPosition.index == 0)
                      ..._type4Summary(l, entry!, read.data),
                    if (address?.shortBinary == true &&
                        _readPosition.index == 0)
                      ..._transitSummary(l, address!, read.data),
                    const SizedBox(height: 6),
                    SelectableText(
                      bytesToHexSpace(read.data),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(l.cpu_manage_bytes(read.data.length)),
                        Text(
                          '${_readPosition.record ? l.cpu_manage_record_number : l.cpu_manage_offset}: ${_readPosition.index}',
                        ),
                        if (read.status != 0x9000) Text(_status(read.status)),
                        if (read.data.isNotEmpty)
                          TextButton.icon(
                            icon: const Icon(Icons.copy, size: 16),
                            label: Text(l.copy),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: bytesToHexSpace(read.data)),
                            ),
                          ),
                        if (read.data.isNotEmpty)
                          TextButton.icon(
                            icon: const Icon(Icons.save_alt, size: 16),
                            label: Text(l.cpu_archive_export_bin),
                            onPressed: _busy
                                ? null
                                : () => _run(() => _exportPreview(read)),
                          ),
                      ],
                    ),
                    const Divider(),
                  ],
                  CpuInfoRow(
                    label: l.cpu_manage_selected_file,
                    value: _selectionLabel(file),
                  ),
                  CpuInfoRow(label: l.cpu_files_type, value: _kind(file.kind)),
                  if (file.directorySfi != null || address?.sfi != null)
                    CpuInfoRow(
                      label: address?.shortBinary == true
                          ? 'SFI'
                          : l.cpu_tree_directory_sfi,
                      value: address?.shortBinary == true
                          ? _hex(address!.sfi!, 2)
                          : '${address?.sfi ?? file.directorySfi}',
                    ),
                  if (file.size != null) Text(l.cpu_manage_bytes(file.size!)),
                  if (file.recordLength != null)
                    CpuInfoRow(
                      label: l.cpu_files_record_length,
                      value: '${file.recordLength}',
                    ),
                  if (file.recordCount != null)
                    CpuInfoRow(
                      label: l.cpu_manage_records,
                      value: '${file.recordCount}',
                    ),
                  if (file.control.isNotEmpty)
                    ExpansionTile(
                      title: const Text('FCI / FCP'),
                      tilePadding: EdgeInsets.zero,
                      children: _controlSummary(l, file),
                    ),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: actionHeight),
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    for (final action in actions)
                      _button(
                        action.icon,
                        action.label,
                        () => _run(action.run),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pursePane(AppLocalizations l) {
    final balance = _purseBalance, error = _purseError;
    final display = balance == null
        ? null
        : '${balance ~/ 100}.${(balance % 100).toString().padLeft(2, '0')}';
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.account_balance_wallet_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.cpu_manage_purse_balance,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (display != null)
                    Text(
                      l.cpu_manage_purse_amount(display),
                      style: Theme.of(context).textTheme.titleLarge,
                    )
                  else if (error != null)
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  else
                    Text(
                      _busy
                          ? l.cpu_manage_purse_reading
                          : l.cpu_manage_purse_unread,
                    ),
                ],
              ),
            ),
            Tooltip(
              message: l.cpu_manage_purse_refresh,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: Text(l.cpu_manage_purse_refresh),
                onPressed: _busy ? null : () => _run(_readPurseBalance),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _workspace(AppLocalizations l) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 740;
      final detail = _dataPane(
        l,
        math.min(wide ? 150.0 : 112.0, constraints.maxHeight * 0.30),
      );
      if (wide) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: (constraints.maxWidth * 0.33).clamp(282.0, 410.0),
              child: _treePane(l),
            ),
            const SizedBox(width: 10),
            Expanded(child: detail),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 2, child: _treePane(l)),
          const SizedBox(height: 8),
          Expanded(flex: 3, child: detail),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    context.watch<ChameleonGUIState>();
    final l = _l;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.cpu_manage_title),
          actions: [
            PopupMenuButton<_ManagerTool>(
              tooltip: l.cpu_manage_profiles,
              enabled: !_busy,
              onSelected: _chooseTool,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _ManagerTool.profiles,
                  child: Text(l.cpu_manage_profile_library),
                ),
                PopupMenuItem(
                  value: _ManagerTool.slots,
                  enabled: _app.connector?.connected == true,
                  child: Text(l.slot_manager),
                ),
                PopupMenuItem(
                  value: _ManagerTool.apdu,
                  enabled: _online,
                  child: Text(l.cpu_apdu_tools),
                ),
                PopupMenuItem(
                  value: _ManagerTool.radio,
                  enabled: _identity != null,
                  child: Text(l.cpu_radio_details),
                ),
              ],
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1540),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _connectionBar(l),
                  SizedBox(
                    height: 3,
                    child: _pendingIo > 0
                        ? const LinearProgressIndicator()
                        : null,
                  ),
                  if (_notice case final notice?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: Text(
                        notice,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _problem
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                  const SizedBox(height: 7),
                  Expanded(
                    child: _active
                        ? _workspace(l)
                        : Center(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text(
                                _online
                                    ? l.cpu_place_help
                                    : l.raw_ultra_required,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CpuSessionEnded implements Exception {
  const CpuSessionEnded();
}

class _Field {
  final String label, initial;
  final bool multiline, number;
  const _Field(
    this.label, {
    this.initial = '',
    this.multiline = false,
    this.number = false,
  });
}

String _hex(int value, int digits) =>
    value.toRadixString(16).padLeft(digits, '0').toUpperCase();

int _readFid(String source) {
  final bytes = cpuHex(source, min: 2, max: 2);
  return bytes.first << 8 | bytes.last;
}

int _mutationFid(String source) {
  final fid = _readFid(source);
  if (fid == 0 || fid == 0x3F00 || fid == 0x3FFF || fid == 0xFFFF)
    throw const FormatException();
  return fid;
}

int _decimal(String source, int lower, int upper) {
  final text = source.trim();
  final value = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
  if (value == null || value < lower || value > upper)
    throw const FormatException();
  return value;
}
