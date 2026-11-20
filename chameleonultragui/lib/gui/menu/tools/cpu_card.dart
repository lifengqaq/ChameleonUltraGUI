import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_dump.dart';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/cpu_emv.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_emv_summary.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class CpuCardMenu extends StatefulWidget {
  final bool readOnly, embedded, enabled;
  final ValueChanged<bool>? onBusyChanged;
  const CpuCardMenu({super.key, this.readOnly = false, this.embedded = false,
    this.enabled = true, this.onBusyChanged});
  @override
  State<CpuCardMenu> createState() => _CpuCardMenuState();
}

class _CpuCardMenuState extends State<CpuCardMenu> {
  final _commands = TextEditingController();
  CardData? _identity;
  final _capture = <CpuApduPair>[];
  bool _busy = false, _session = false, _follow = true, _messageIsError = false;
  CpuEmvSummary? _summary;
  String _log = '', _message = '';

  @override
  void dispose() {
    _commands.dispose();
    super.dispose();
  }

  ChameleonCommunicator _device() {
    final app = context.read<ChameleonGUIState>();
    if (app.connector?.connected != true || app.communicator == null) {
      throw StateError(AppLocalizations.of(context)!.device_required);
    }
    if (app.connector?.device != ChameleonDevice.ultra) {
      throw StateError(AppLocalizations.of(context)!.raw_ultra_required);
    }
    return app.communicator!;
  }

  Future<void> _requireFirmware(ChameleonCommunicator device) async {
    final commands = await device.getDeviceCapabilities();
    if (!commands.contains(ChameleonCommand.hf14a4Session.value) ||
        !commands.contains(ChameleonCommand.hf14a4StaticRead.value)) {
      throw StateError(
        AppLocalizations.of(context)!.cpu_error_firmware,
      );
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
    widget.onBusyChanged?.call(true);
    setState(() {
      _busy = true;
      _message = '';
      _messageIsError = false;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        _append(error.toString());
        setState(() {
          _message = error is CpuCommandError
              ? cpuCommandErrorText(l, error)
              : error is StateError ? error.message
              : error is FormatException ? error.message : error.toString();
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onBusyChanged?.call(false);
    }
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _log += '$line\n';
      if (_log.length > 20000) _log = _log.substring(_log.length - 20000);
    });
  }

  void _resetRead() {
    setState(() {
      _identity = null;
      _summary = null;
      _capture.clear();
      _log = '';
      _session = false;
    });
  }

  Future<void> _connect() async {
    final device = _device();
    _resetRead();
    await _requireFirmware(device);
    if (!await device.isReaderDeviceMode())
      await device.setReaderDeviceMode(true);
    if (mounted) setState(() => _session = false);
    final identity = await device.hf14a4OpenSession();
    if (!mounted) {
      await device.hf14a4CloseSession();
      return;
    }
    setState(() {
      _identity = identity;
      _session = true;
      _capture.clear();
    });
    _append(
      'UID ${bytesToHexSpace(identity.uid)}\nATS ${bytesToHexSpace(identity.ats)}',
    );
    if (widget.readOnly) {
      await device.hf14a4CloseSession();
      if (mounted) setState(() => _session = false);
    }
  }

  Future<void> _disconnect() async {
    await _device().hf14a4CloseSession();
    if (mounted) setState(() => _session = false);
  }

  Future<void> _send() async {
    final l = AppLocalizations.of(context)!;
    if (!_session) throw StateError('Select a card first');
    final commands = [
      for (final line in _commands.text.split('\n'))
        if (line.trim().isNotEmpty && !line.trim().startsWith('#'))
          cpuHex(line, min: 4, max: 260),
    ];
    if (commands.isEmpty) throw const FormatException('Enter an APDU');
    final device = _device();
    for (final command in commands) {
      Uint8List response;
      try {
        response = await exchangeCpuApdu(
          command,
          device.hf14a4ReaderApdu,
          followStatus: _follow,
        );
      } catch (_) {
        if (mounted) setState(() => _session = false);
        try {
          await device.hf14a4CloseSession();
        } catch (_) {}
        rethrow;
      }
      final pair = CpuApduPair(command, response);
      if (const [0x20, 0x24, 0x2C, 0x82].contains(command[1])) {
        _append('Authentication APDU [redacted], SW ${pair.statusWord.toRadixString(16)}');
        if (pair.statusWord != 0x9000) break;
        continue;
      }
      _capture.add(pair);
      _append(
        '> ${bytesToHexSpace(command)}\n< ${bytesToHexSpace(response)}\nSW ${pair.statusWord.toRadixString(16).padLeft(4, '0').toUpperCase()} · ${cpuStatusText(l, pair.statusWord)}',
      );
      if (pair.statusWord != 0x9000)
        break; // Stop scripts on the first card error.
    }
  }

  Future<void> _scan() async {
    final device = _device();
    _resetRead();
    await _requireFirmware(device);
    if (!await device.isReaderDeviceMode())
      await device.setReaderDeviceMode(true);
    if (mounted) setState(() => _session = false);
    final (identity, pairs) = parseCpuEmvScan(await device.hf14a4EmvScan());
    if (!mounted) return;
    setState(() {
      _identity = identity;
      _capture.addAll(pairs);
      _summary = pairs.isEmpty ? null : summarizeCpuEmv(pairs);
    });
    _append('UID ${bytesToHexSpace(identity.uid)}\nATS ${bytesToHexSpace(identity.ats)}');
    for (final pair in pairs) {
      _append(
        '> ${bytesToHexSpace(pair.command)}\n< ${bytesToHexSpace(pair.response)}',
      );
    }
    if (mounted && pairs.isEmpty) {
      setState(() => _message = AppLocalizations.of(context)!.cpu_emv_empty);
    }
  }

  Future<void> _saveReadCard() async {
    final identity = _identity;
    if (identity == null) return;
    final card = await showCpuDumpDialog(context, identity,
      name: _summary?.applicationLabel ?? '', capture: List.of(_capture));
    if (card == null || !mounted) return;
    final app = context.read<ChameleonGUIState>();
    final cards = app.sharedPreferencesProvider.getCards()..add(card);
    app.sharedPreferencesProvider.setCards(cards);
    app.changesMade();
    setState(() => _message = AppLocalizations.of(context)!.cpu_done);
  }

  Future<void> _exit() async {
    if (_busy) return;
    await _run(() async {
      try {
        if (_session && context.read<ChameleonGUIState>().connector?.connected == true) {
          await _disconnect();
        }
      } finally {
        if (mounted) setState(() => _session = false);
      }
    });
    if (mounted) Navigator.of(context).pop();
  }

  Widget _readerTab(AppLocalizations l, bool online) => ListView(
    key: const PageStorageKey('cpu-reader-scroll'),
    shrinkWrap: widget.embedded,
    primary: false,
    physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
    padding: const EdgeInsets.all(16),
    children: [
      if (!online) ...[
        Text(l.cpu_device_help),
        const SizedBox(height: 12),
      ],
      CpuIdentityPanel(identity: _identity),
      if (_identity != null) OutlinedButton.icon(
        onPressed: _busy ? null : () => _run(_saveReadCard),
        icon: const Icon(Icons.save_outlined), label: Text(l.cpu_dump_save)),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy || !online ? null : () => _run(_scan),
        icon: const Icon(Icons.credit_card),
        label: Text(l.cpu_emv_scan),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy || !online ? null : () => _run(_connect),
        icon: const Icon(Icons.nfc),
        label: Text(l.cpu_identify_only),
      ),
      if (!widget.readOnly) TextButton(
        onPressed: _busy || !_session ? null : () => _run(_disconnect),
        child: Text(l.cpu_disconnect),
      ),
      Text(l.cpu_scan_help, style: Theme.of(context).textTheme.bodySmall),
      if (_summary != null) ...[
        const SizedBox(height: 20),
        CpuEmvSummaryPanel(summary: _summary!),
      ],
      const SizedBox(height: 16),
      Text(l.cpu_advanced_help, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Widget _advancedTab(AppLocalizations l, bool online) => ListView(
    key: const PageStorageKey('cpu-advanced-scroll'),
    padding: const EdgeInsets.all(16),
    children: [
      Text(l.cpu_reader, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(_session ? l.cpu_session_open : l.cpu_session_closed),
      Wrap(spacing: 8, children: [
        OutlinedButton(
          onPressed: _busy || !online ? null : () => _run(_connect),
          child: Text(l.cpu_connect),
        ),
        TextButton(
          onPressed: _busy || !_session ? null : () => _run(_disconnect),
          child: Text(l.cpu_disconnect),
        ),
      ]),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        isExpanded: true,
        decoration: InputDecoration(labelText: l.cpu_templates),
        items: [for (final item in <String, String>{
          'SELECT MF': '00 A4 00 00 02 3F 00',
          'READ BINARY': '00 B0 00 00 10',
          'READ RECORD': '00 B2 01 0C 00',
          'UPDATE BINARY': '00 D6 00 00 01 00',
          'UPDATE RECORD': '00 DC 01 0C 01 00',
        }.entries) DropdownMenuItem(value: item.value, child: Text(item.key))],
        onChanged: _busy ? null : (value) {
          if (value != null) _commands.text = value;
        },
      ),
      const SizedBox(height: 12),
      TextField(
        key: const PageStorageKey('cpu-command-editor-scroll'),
        controller: _commands, enabled: !_busy, minLines: 2, maxLines: 6,
        style: const TextStyle(fontFamily: 'monospace'),
        decoration: InputDecoration(labelText: l.cpu_apdu, helperText: l.cpu_script_help,
          helperMaxLines: 4, border: const OutlineInputBorder()),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l.cpu_follow_status), value: _follow,
        onChanged: _busy ? null : (value) => setState(() => _follow = value!),
      ),
      FilledButton(
        onPressed: _busy || !_session || !online ? null : () => _run(_send),
        child: Text(l.cpu_send),
      ),
      const SizedBox(height: 16),
      ExpansionTile(
        key: const PageStorageKey('cpu-log-expanded'),
        tilePadding: EdgeInsets.zero,
        title: Text(l.cpu_raw_log),
        children: [
          if (_log.isEmpty) Text(l.cpu_log_empty)
          else Align(alignment: Alignment.centerLeft, child: SelectionArea(child: Text(
            _log, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)))),
          Wrap(spacing: 8, children: [
            TextButton(
              onPressed: _log.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _log)),
              child: Text(l.cpu_copy_log),
            ),
            TextButton(
              onPressed: _busy || _log.isEmpty ? null : () => setState(() => _log = ''),
              child: Text(l.cpu_clear_log),
            ),
          ]),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final app = context.watch<ChameleonGUIState>();
    final online = app.connector?.connected == true && widget.enabled;
    if (widget.readOnly) {
      return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16,16,16,0), child: Text(l.cpu_title,
          style: Theme.of(context).textTheme.titleLarge)),
        if (_busy) const LinearProgressIndicator(),
        if (_message.isNotEmpty) Padding(padding: const EdgeInsets.all(16),
          child: Text(_message, style: _messageIsError ? TextStyle(color:Theme.of(context).colorScheme.error) : null)),
        _readerTab(l, online),
      ]));
    }
    return PopScope(canPop: !_busy && !_session,
      onPopInvokedWithResult: (didPop, result) { if (!didPop && !_busy) _exit(); },
      child: Dialog.fullscreen(child: Scaffold(
        appBar: AppBar(title: Text(l.cpu_apdu_tools),
          leading: IconButton(onPressed: _busy ? null : _exit,
            icon: const Icon(Icons.close), tooltip: l.cpu_close)),
        body: Column(children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(_message)),
          Expanded(child: _advancedTab(l, online)),
        ]),
      )),
    );
  }
}
