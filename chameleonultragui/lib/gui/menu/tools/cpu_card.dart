import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/cpu_emv.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_emv_summary.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/hf14a4_slot.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class CpuCardMenu extends StatefulWidget {
  const CpuCardMenu({super.key});
  @override
  State<CpuCardMenu> createState() => _CpuCardMenuState();
}

class _CpuCardMenuState extends State<CpuCardMenu> {
  final _commands = TextEditingController();
  final _profile = TextEditingController();
  CardData? _identity;
  final _capture = <CpuApduPair>[];
  bool _busy = false, _session = false, _follow = true, _messageIsError = false;
  CpuEmvSummary? _summary;
  String _log = '', _message = '';
  int _slot = 0;
  String? _stored;

  @override
  void dispose() {
    _commands.dispose();
    _profile.dispose();
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
        'Install firmware with ISO-DEP session/table support (6007/6008)',
      );
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
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
      _capture.add(pair);
      _append(
        '> ${bytesToHexSpace(command)}\n< ${bytesToHexSpace(response)}\nSW ${pair.statusWord.toRadixString(16).padLeft(4, '0').toUpperCase()} · ${cpuStatusText(l, pair.statusWord)}',
      );
      if (pair.statusWord != 0x9000)
        break; // Stop scripts on the first card error.
    }
  }

  void _captureProfile() {
    final identity = _identity;
    if (identity == null) throw StateError('Select a card or scan EMV first');
    final pairs = [
      for (final pair in _capture)
        CpuApduPair(
          Uint8List.fromList(pair.command.take(16).toList()),
          pair.response,
        ),
    ];
    validateCpuRules(pairs);
    _profile.text = cpuProfileJson(
      identity, pairs, name: _summary?.applicationLabel ?? 'CPU card',
    );
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

  Future<void> _upload() async {
    final card = cpuProfileFromJson(
      _profile.text,
    ); // Validate before touching a slot.
    final device = _device();
    await _requireFirmware(device);
    await device.setReaderDeviceMode(false);
    if (mounted) setState(() => _session = false);
    await device.enableSlot(_slot, TagFrequency.hf, false);
    await device.activateSlot(_slot);
    await device.setSlotType(_slot, TagType.hf14a4);
    await device.setDefaultDataToSlot(_slot, TagType.hf14a4);
    await writeHf14a4SlotIdentity(device, card);
    await device.setSlotTagName(_slot, card.name, TagFrequency.hf);
    await device.enableSlot(_slot, TagFrequency.hf, true);
    await device.saveSlotData();
    if (mounted) {
      context.read<ChameleonGUIState>().changesMade();
      setState(() => _message = AppLocalizations.of(context)!.cpu_done);
    }
  }

  Future<void> _readSlot() async {
    final device = _device();
    await _requireFirmware(device);
    await device.setReaderDeviceMode(false);
    if (mounted) setState(() => _session = false);
    await device.activateSlot(_slot);
    final card = await readHf14a4SlotIdentity(device, 'CPU slot ${_slot + 1}');
    _profile.text = cpuProfileJson(
      CardData(
        uid: hexToBytes(card.uid),
        atqa: card.atqa,
        sak: card.sak,
        ats: card.ats,
      ),
      cpuRulesFromData(card.data),
      name: card.name,
    );
  }

  void _save() {
    final card = cpuProfileFromJson(_profile.text);
    final app = context.read<ChameleonGUIState>();
    final cards = app.sharedPreferencesProvider.getCards();
    cards.add(card);
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

  Widget _identityCard(AppLocalizations l) {
    final identity = _identity;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.contactless_outlined),
              const SizedBox(width: 10),
              Expanded(child: Text(
                identity == null ? l.cpu_place_card : l.cpu_card_identified,
                style: Theme.of(context).textTheme.titleMedium,
              )),
            ]),
            const SizedBox(height: 10),
            if (identity == null)
              Text(l.cpu_place_help)
            else ...[
              CpuInfoRow(label: 'UID', value: bytesToHexSpace(identity.uid)),
              Text(l.cpu_type_a, style: Theme.of(context).textTheme.bodySmall),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(l.cpu_radio_details),
                children: [
                  CpuInfoRow(label: 'ATQA', value: bytesToHexSpace(identity.atqa)),
                  CpuInfoRow(label: 'SAK', value: identity.sak.toRadixString(16).padLeft(2, '0').toUpperCase()),
                  CpuInfoRow(label: 'ATS', value: bytesToHexSpace(identity.ats)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _readerTab(AppLocalizations l, bool online) => ListView(
    key: const PageStorageKey('cpu-reader'),
    padding: const EdgeInsets.all(16),
    children: [
      if (!online) ...[
        Text(l.cpu_device_help),
        const SizedBox(height: 12),
      ],
      _identityCard(l),
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
      TextButton(
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

  Widget _simulationTab(AppLocalizations l, bool online) {
    final app = context.watch<ChameleonGUIState>();
    final cards = app.sharedPreferencesProvider.getCards()
        .where((card) => card.tag == TagType.hf14a4).toList();
    var profileTitle = l.cpu_no_profile;
    var validProfile = false;
    var count = 0;
    try {
      final profile = cpuProfileFromJson(_profile.text);
      profileTitle = profile.name;
      count = profile.data.length ~/ 2;
      validProfile = true;
    } catch (_) {
      if (_profile.text.trim().isNotEmpty) profileTitle = l.cpu_profile_invalid;
    }
    return ListView(
      key: const PageStorageKey('cpu-simulation'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(l.cpu_static_title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(l.cpu_static_help),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _busy || _identity == null || _capture.isEmpty ? null : () => _run(() async {
            _captureProfile();
            setState(() => _message = l.cpu_done);
          }),
          icon: const Icon(Icons.move_to_inbox_outlined),
          label: Text(l.cpu_capture),
        ),
        if (cards.isNotEmpty) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: _stored,
            decoration: InputDecoration(labelText: l.cpu_load_saved),
            items: [for (final card in cards)
              DropdownMenuItem(value: card.id, child: Text(card.name))],
            onChanged: _busy ? null : (id) => _run(() async {
              if (id == null) return;
              final card = cards.firstWhere((card) => card.id == id);
              _profile.text = cpuProfileJson(
                CardData(uid: hexToBytes(card.uid), atqa: card.atqa,
                  sak: card.sak, ats: card.ats),
                cpuRulesFromData(card.data), name: card.name,
              );
              setState(() => _stored = id);
            }),
          ),
        ],
        const SizedBox(height: 16),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(profileTitle, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(validProfile ? '${l.cpu_rule_count}: $count' : l.cpu_profile_start),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          value: _slot,
          decoration: InputDecoration(labelText: l.cpu_slot),
          items: [for (var i = 0; i < 8; i++)
            DropdownMenuItem(value: i, child: Text('${i + 1}'))],
          onChanged: _busy ? null : (value) => setState(() => _slot = value!),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy || !online || !validProfile ? null : () => _run(_upload),
          icon: const Icon(Icons.upload_outlined),
          label: Text(l.cpu_upload),
        ),
        Wrap(spacing: 8, children: [
          TextButton(
            onPressed: _busy || !validProfile ? null : () => _run(() async => _save()),
            child: Text(l.cpu_save),
          ),
          TextButton(
            onPressed: _busy || !online ? null : () => _run(_readSlot),
            child: Text(l.cpu_read_slot),
          ),
        ]),
        const SizedBox(height: 8),
        Text(l.cpu_profile_edit_hint, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _advancedTab(AppLocalizations l, bool online) => ListView(
    key: const PageStorageKey('cpu-advanced'),
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
        tilePadding: EdgeInsets.zero,
        title: Text(l.cpu_raw_log),
        children: [
          if (_log.isEmpty) Text(l.cpu_log_empty)
          else Align(alignment: Alignment.centerLeft, child: SelectableText(
            _log, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
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
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(l.cpu_profile_json),
        children: [
          Text(l.cpu_profile_help),
          const SizedBox(height: 12),
          TextField(
            controller: _profile, enabled: !_busy, minLines: 6, maxLines: 16,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(labelText: 'JSON', border: OutlineInputBorder()),
          ),
          TextButton(
            onPressed: _profile.text.trim().isEmpty ? null : () => Clipboard.setData(ClipboardData(text: _profile.text)),
            child: Text(l.cpu_copy_json),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final app = context.watch<ChameleonGUIState>();
    final online = app.connector?.connected == true;
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy && !_session,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_busy) _exit();
      },
      child: Dialog.fullscreen(
        child: DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                onPressed: _busy ? null : _exit,
                icon: const Icon(Icons.close), tooltip: l.cpu_close,
              ),
              title: Text(l.cpu_title),
              actions: [if (_busy) const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))),
              ],
              bottom: TabBar(tabs: [
                Tab(text: l.cpu_tab_read), Tab(text: l.cpu_tab_emulate),
                Tab(text: l.cpu_tab_advanced),
              ]),
            ),
            body: SafeArea(
              top: false,
              child: Column(children: [
                if (_message.isNotEmpty) Container(
                  width: double.infinity,
                  color: _messageIsError ? colors.errorContainer : colors.secondaryContainer,
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(children: [
                    Icon(_messageIsError ? Icons.error_outline : Icons.info_outline),
                    const SizedBox(width: 10),
                    Expanded(child: SelectableText(_message)),
                    IconButton(onPressed: () => setState(() => _message = ''),
                      icon: const Icon(Icons.close), tooltip: l.cpu_close),
                  ]),
                ),
                Expanded(child: TabBarView(children: [
                  _readerTab(l, online), _simulationTab(l, online),
                  _advancedTab(l, online),
                ])),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
