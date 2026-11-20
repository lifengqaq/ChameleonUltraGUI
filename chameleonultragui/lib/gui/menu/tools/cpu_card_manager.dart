import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_auth.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_card.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_directory_view.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_emv_summary.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_profiles.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_directory.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

typedef _Link = ({ChameleonCommunicator device, Uint8List id});

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
  CpuDirectoryScan? _directoryScan;
  CpuFileReply? _lastRead;
  String? _notice;
  bool _busy = false, _problem = false, _authenticated = false;

  AppLocalizations get _l => AppLocalizations.of(context)!;
  bool get _online =>
      _app.connector?.connected == true &&
      _app.connector?.device == ChameleonDevice.ultra &&
      _app.communicator != null;
  bool _ownsDevice(ChameleonCommunicator device) =>
      _online && identical(_app.communicator, device);
  bool get _active => _link != null && _ownsDevice(_link!.device);

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
    _directoryAddress = null;
    _lastRead = null;
    _authenticated = false;
  }

  void _forgetSession() {
    _link = null;
    _tree = CpuDirectoryTree();
    _directoryScan = null;
    _forgetSelection();
  }

  Future<void> _disconnect() async {
    final link = _link;
    setState(_forgetSession);
    if (link == null || !_ownsDevice(link.device)) return;
    try {
      await link.device.hf14a4CloseManagedSession(link.id);
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
    });
    final commands = await device.getDeviceCapabilities();
    if (!commands.contains(ChameleonCommand.hf14a4ManagedSession.value)) {
      throw StateError(l.cpu_error_firmware);
    }
    if (!_ownsDevice(device)) throw StateError(l.cpu_manage_session_lost);
    if (!await device.isReaderDeviceMode())
      await device.setReaderDeviceMode(true);
    if (!_ownsDevice(device)) throw StateError(l.cpu_manage_session_lost);
    final (identity, id) = await device.hf14a4OpenManagedSession();
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

  Future<Uint8List> _transmit(_Link link, Uint8List apdu) async {
    try {
      if (_link != link || !_ownsDevice(link.device)) {
        throw StateError(_l.cpu_manage_session_lost);
      }
      final result = await link.device.hf14a4ManagedApdu(link.id, apdu);
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
      final message = switch (error) {
        CpuFileStatus(:final word) => _status(word),
        CpuSessionEnded() ||
        CpuCommandError(status: 0x76) => l.cpu_manage_session_lost,
        CpuCommandError() => cpuCommandErrorText(l, error),
        StateError() => error.message,
        FormatException() => l.cpu_manage_unexpected_file,
        _ => l.cpu_error_no_response,
      };
      if (error case CpuFileStatus(word: 0x6982)) _authenticated = false;
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

  Future<void> _authenticate() async {
    final card = _card;
    final identity = _identity!;
    setState(() => _authenticated = false);
    final accepted = await showCpuAuthentication(
      context,
      exchange: card.exchange,
      history: cpuAuthHistoryForCard(identity.uid, identity.ats),
      prefillCredential: false,
    );
    if (!mounted) return;
    if (!_active) {
      _message(_l.cpu_manage_session_lost, problem: true);
    } else if (accepted) {
      setState(() => _authenticated = true);
      _message(_status(0x9000));
    }
  }

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
    final file = await select(card);
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
        _tree.add(
          CpuDirectoryEntry(
            location,
            kind: file.kind,
            label: file.label,
            applicationAid: file.aid,
          ),
        );
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
      await _select((card) => card.selectAid(aid), address: address);
    }
  }

  Future<void> _chooseFile(bool directory) async {
    final l = _l;
    final path = await _prompt(
      directory ? l.cpu_manage_open_df : l.cpu_manage_open_ef,
      [_Field(l.cpu_manage_path)],
      (values) {
        final parts = values.single.split('/').map(_readFid).toList();
        if (parts.length > 17 ||
            (parts.length > 1 && parts.first != 0x3F00) ||
            (!directory && parts.last == 0x3F00))
          throw const FormatException();
        return parts;
      },
      help: l.cpu_manage_path_help,
    );
    if (path == null || !mounted) return;
    if (path.length == 1 && path.first == 0x3F00) {
      await _select((card) => card.selectMaster());
    } else if (path.length == 1) {
      await _select(
        (card) => card.selectFile(path.first, directory: directory),
        relative: true,
      );
    } else {
      await _select(
        (card) => card.selectPath(path.sublist(1), directory: directory),
        address: CpuFileAddress(path.sublist(1)),
      );
    }
  }

  Future<void> _discoverDirectory() async {
    setState(_forgetSelection);
    final scan = await discoverCpuDirectory(_card);
    if (!mounted) return;
    setState(() {
      _tree.merge(scan.tree);
      _directoryScan = scan;
      if (scan.master != null) {
        _file = _directory = scan.master;
        _address = _directoryAddress = const CpuFileAddress.master();
      }
    });
  }

  Future<void> _openEntry(CpuDirectoryEntry entry) async {
    if (_address?.display == entry.address.display && _file != null) return;
    final parent = _directoryAddress;
    await _select(
      (card) => entry.address.open(
        card,
        directory: entry.isDirectory,
        type4: entry.type4,
        selectedDirectory: parent,
      ),
      address: entry.address,
      expectedAid: entry.applicationAid,
      relative:
          parent != null && entry.address.parent?.display == parent.display,
    );
  }

  Future<void> _readSelectedDirectory() async {
    final applications = await _card.readApplicationEntries(_file!);
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
    final knownLength = record ? file.recordLength : file.size;
    final suggestedLength = knownLength?.clamp(1, 256) ?? 256;
    final request = await _prompt(
      record ? l.cpu_manage_read_record : l.cpu_manage_read_binary,
      [
        _Field(
          record ? l.cpu_manage_record_number : l.cpu_manage_offset,
          initial: record ? '1' : '0',
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
            : _decimal(values.first, 0, 32767);
        final length = _decimal(
          values.last,
          1,
          record ? 256 : 256.clamp(1, 32768 - index),
        );
        return (index, length);
      },
      action: l.read,
    );
    if (request == null || !mounted) return;
    setState(() => _lastRead = null);
    final (index, length) = request;
    final response = record
        ? await _card.readRecord(index, length)
        : await _card.readBinary(index, length);
    if (mounted) setState(() => _lastRead = response);
    _message(_status(response.status));
  }

  Future<void> _write({required bool record}) async {
    final l = _l;
    final title = record
        ? l.cpu_manage_write_record
        : l.cpu_manage_write_binary;
    final request = await _prompt(
      title,
      [
        _Field(
          record ? l.cpu_manage_record_number : l.cpu_manage_offset,
          initial: record ? '1' : '0',
          number: true,
        ),
        _Field(l.cpu_manage_update_data, multiline: true),
      ],
      (values) {
        final index = record
            ? _decimal(values.first, 1, 254)
            : _decimal(values.first, 0, 32767);
        return (
          index,
          cpuHex(
            values.last,
            min: 1,
            max: record ? 255 : 255.clamp(1, 32768 - index),
          ),
        );
      },
      action: l.ok,
    );
    if (request == null || !mounted) return;
    final (index, data) = request;
    final location = record ? l.cpu_manage_record_number : l.cpu_manage_offset;
    await _mutate(
      title,
      '$location: $index\n${l.cpu_manage_bytes(data.length)}',
      () => record
          ? _card.updateRecord(index, data)
          : _card.updateBinary(index, data),
    );
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
                ),
              );
            },
    );
  }

  Future<void> _delete() async {
    final l = _l;
    final fid = await _prompt(
      l.cpu_manage_delete_child,
      [_Field(l.cpu_manage_fid)],
      (values) {
        final target = _mutationFid(values.single);
        if (_file?.fid == target) throw const FormatException();
        return target;
      },
    );
    if (fid == null || !mounted) return;
    await _mutate(
      l.cpu_manage_delete_child,
      'FID ${_hex(fid, 4)}',
      () => _card.deleteFile(fid),
      directoryChange: true,
      warning: l.cpu_manage_delete_warning,
      onSuccess: _directoryAddress == null
          ? null
          : () => _tree.remove(_directoryAddress!.child(fid)),
    );
  }

  Future<void> _mutate(
    String title,
    String target,
    Future<CpuFileReply> Function() send, {
    bool directoryChange = false,
    String? warning,
    VoidCallback? onSuccess,
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
    setState(() => _lastRead = null);
    try {
      final response = await send();
      if (!mounted) return;
      if (directoryChange)
        setState(() {
          onSuccess?.call();
          _forgetSelection();
        });
      _message('$title · ${_status(response.status)}');
    } on CpuFileStatus catch (error) {
      if (error.word >> 8 == 0x63 || error.word >> 8 == 0x65) {
        if (mounted && directoryChange) setState(_forgetSelection);
        _message(
          '${_status(error.word)}\n${l.cpu_manage_write_unknown}',
          problem: true,
        );
      } else {
        rethrow;
      }
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

  Widget _button(IconData icon, String title, VoidCallback? run) =>
      OutlinedButton.icon(
        icon: Icon(icon),
        label: Text(title),
        onPressed: run == null || _busy ? null : run,
      );

  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          ...children,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    context.watch<ChameleonGUIState>();
    final l = _l;
    final active = _active;
    final file = active ? _file : null;
    final scan = _directoryScan;
    final read = active ? _lastRead : null;
    final online = _online;
    final canManageChildren =
        file != null &&
        file.isDirectory &&
        file.canChange &&
        (file.fid != null || file.aid != null);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l.cpu_manage_title)),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _section(l.cpu_manage_live, [
                  CpuIdentityPanel(identity: _identity),
                  Text(
                    active
                        ? l.cpu_manage_session_active
                        : online
                        ? l.cpu_manage_session_idle
                        : l.raw_ultra_required,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
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
                        Icons.lock_open,
                        l.cpu_authenticate,
                        active ? () => _run(_authenticate) : null,
                      ),
                      _button(
                        Icons.save_outlined,
                        l.save_only_uid,
                        _identity == null ? null : () => _run(_saveIdentity),
                      ),
                    ],
                  ),
                  if (active && _authenticated) Text(l.cpu_manage_auth_ok),
                ]),
                if (_busy) const LinearProgressIndicator(),
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _notice!,
                      style: TextStyle(
                        color: _problem
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                if (active)
                  _section(l.cpu_manage_files, [
                    Text(l.cpu_manage_directory_help),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _button(
                          Icons.refresh,
                          l.cpu_tree_refresh,
                          () => _run(_discoverDirectory),
                        ),
                        _button(
                          Icons.home_outlined,
                          'MF 3F00',
                          () => _run(
                            () => _select((card) => card.selectMaster()),
                          ),
                        ),
                        _button(
                          Icons.apps,
                          l.cpu_manage_select_aid,
                          () => _run(_chooseAid),
                        ),
                        _button(
                          Icons.folder_open,
                          l.cpu_manage_open_df,
                          () => _run(() => _chooseFile(true)),
                        ),
                        _button(
                          Icons.insert_drive_file_outlined,
                          l.cpu_manage_open_ef,
                          () => _run(() => _chooseFile(false)),
                        ),
                        _button(
                          Icons.arrow_upward,
                          l.cpu_manage_parent,
                          file?.isDirectory == true && file?.fid != 0x3F00
                              ? () => _run(
                                  () => _select(
                                    (card) => card.selectParent(),
                                    address: _directoryAddress?.parent,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                    if (!_tree.isEmpty)
                      CpuDirectoryView(
                        tree: _tree,
                        selected: _address,
                        onOpen: _busy
                            ? null
                            : (entry) => _run(() => _openEntry(entry)),
                      ),
                    if (scan != null) ...[
                      if (_tree.isEmpty ||
                          (_tree.childrenOf(null).length == 1 &&
                              _tree.childrenOf(null).single.isMaster &&
                              _tree
                                  .childrenOf(const CpuFileAddress.master())
                                  .isEmpty))
                        Text(l.cpu_tree_no_entries),
                      if (scan.incomplete) Text(l.cpu_tree_incomplete),
                      for (final item in scan.cardStatuses.entries)
                        Text('${item.key}: ${_status(item.value)}'),
                    ],
                    if (file != null) ...[
                      const Divider(),
                      CpuInfoRow(
                        label: l.cpu_manage_selected_file,
                        value: _selectionLabel(file),
                      ),
                      CpuInfoRow(
                        label: l.cpu_files_type,
                        value: _kind(file.kind),
                      ),
                      if (file.size != null)
                        Text(l.cpu_manage_bytes(file.size!)),
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
                          children: [
                            SelectableText(bytesToHexSpace(file.control)),
                          ],
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (_address?.display == '3F00/2F00')
                            _button(
                              Icons.list_alt,
                              l.cpu_manage_list_apps,
                              () => _run(_readSelectedDirectory),
                            ),
                          if (file.supportsBinary) ...[
                            _button(
                              Icons.download,
                              l.cpu_manage_read_binary,
                              () => _run(() => _read(record: false)),
                            ),
                            if (file.canChange)
                              _button(
                                Icons.edit_outlined,
                                l.cpu_manage_write_binary,
                                () => _run(() => _write(record: false)),
                              ),
                          ],
                          if (file.supportsRecords) ...[
                            _button(
                              Icons.download,
                              l.cpu_manage_read_record,
                              () => _run(() => _read(record: true)),
                            ),
                            if (file.canChange)
                              _button(
                                Icons.edit_outlined,
                                l.cpu_manage_write_record,
                                () => _run(() => _write(record: true)),
                              ),
                          ],
                          if (canManageChildren) ...[
                            for (final kind in [
                              CpuLiveFileKind.directory,
                              CpuLiveFileKind.binary,
                              CpuLiveFileKind.record,
                            ])
                              _button(
                                Icons.add,
                                _createLabel(kind),
                                () => _run(() => _create(kind)),
                              ),
                            _button(
                              Icons.delete_outline,
                              l.cpu_manage_delete_child,
                              () => _run(_delete),
                            ),
                          ],
                        ],
                      ),
                    ],
                    if (read != null) ...[
                      const Divider(),
                      Text(l.cpu_manage_bytes(read.data.length)),
                      SelectableText(
                        bytesToHexSpace(read.data),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      if (read.data.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _button(
                            Icons.copy,
                            l.copy,
                            () => Clipboard.setData(
                              ClipboardData(text: bytesToHexSpace(read.data)),
                            ),
                          ),
                        ),
                    ],
                  ]),
                _section(l.cpu_manage_profiles, [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _button(
                        Icons.credit_card,
                        l.cpu_manage_profile_library,
                        () => _run(() => _openTool(const CpuProfilesPage())),
                      ),
                      _button(
                        Icons.storage,
                        l.slot_manager,
                        _app.connector?.connected == true
                            ? () =>
                                  _run(() => _openTool(const SlotManagerPage()))
                            : null,
                      ),
                      _button(
                        Icons.terminal,
                        l.cpu_apdu_tools,
                        online
                            ? () => _run(
                                () => _openTool(
                                  const CpuCardMenu(),
                                  dialog: true,
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ]),
              ],
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
