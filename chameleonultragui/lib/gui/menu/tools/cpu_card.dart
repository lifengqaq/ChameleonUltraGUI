import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
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
  final _commands = TextEditingController(text: '00 A4 00 00 02 3F 00');
  final _profile = TextEditingController();
  CardData? _identity;
  final _capture = <CpuApduPair>[];
  bool _busy = false, _session = false, _follow = true;
  String _log = '', _message = '';
  int _slot = 0;
  String? _stored;

  @override
  void initState() {
    super.initState();
    _profile.text = cpuProfileJson(
      CardData(
        uid: cpuHex('04010203'),
        atqa: cpuHex('0400'),
        sak: 0x20,
        ats: cpuHex('067580700200'),
      ),
      [],
    );
  }

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
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
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

  Future<void> _connect() async {
    final device = _device();
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
        '> ${bytesToHexSpace(command)}\n< ${bytesToHexSpace(response)}\nSW ${pair.statusWord.toRadixString(16).padLeft(4, '0').toUpperCase()}',
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
    _profile.text = cpuProfileJson(identity, pairs);
  }

  Future<void> _scan() async {
    final device = _device();
    await _requireFirmware(device);
    if (!await device.isReaderDeviceMode())
      await device.setReaderDeviceMode(true);
    if (mounted) setState(() => _session = false);
    final (identity, pairs) = parseCpuEmvScan(await device.hf14a4EmvScan());
    _identity = identity;
    _capture.clear();
    _capture.addAll(pairs);
    for (final pair in pairs) {
      _append(
        '> ${bytesToHexSpace(pair.command)}\n< ${bytesToHexSpace(pair.response)}',
      );
    }
    _captureProfile();
    if (mounted) setState(() => _message = '${pairs.length} APDU');
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final app = context.watch<ChameleonGUIState>();
    final online = app.connector?.connected == true;
    final cards = app.sharedPreferencesProvider
        .getCards()
        .where((card) => card.tag == TagType.hf14a4)
        .toList();
    return PopScope(
      canPop: !_busy && !_session,
      child: AlertDialog(
        title: Text(l.cpu_title),
        content: SizedBox(
          width: 720,
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.cpu_reader,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _busy || !online ? null : () => _run(_connect),
                      child: Text(l.cpu_connect),
                    ),
                    TextButton(
                      onPressed: _busy || !_session
                          ? null
                          : () => _run(_disconnect),
                      child: Text(l.cpu_disconnect),
                    ),
                    TextButton(
                      onPressed: _busy || !online ? null : () => _run(_scan),
                      child: Text(l.cpu_emv_scan),
                    ),
                  ],
                ),
                TextField(
                  controller: _commands,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: l.cpu_apdu,
                    helperText: l.cpu_script_help,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final item in <String, String>{
                      'SELECT MF': '00 A4 00 00 02 3F 00',
                      'READ BINARY': '00 B0 00 00 10',
                      'UPDATE BINARY': '00 D6 00 00 01 00',
                      'READ RECORD': '00 B2 01 0C 00',
                      'UPDATE RECORD': '00 DC 01 0C 01 00',
                    }.entries)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _commands.text = item.value,
                        child: Text(item.key),
                      ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.cpu_follow_status),
                  value: _follow,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _follow = value!),
                ),
                FilledButton(
                  onPressed: _busy || !_session || !online
                      ? null
                      : () => _run(_send),
                  child: Text(l.cpu_send),
                ),
                if (_log.isNotEmpty) ...[
                  SelectableText(
                    _log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: _log)),
                    child: Text(l.cpu_copy_log),
                  ),
                ],
                const Divider(),
                Text(
                  l.cpu_profile,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(l.cpu_profile_help),
                TextButton(
                  onPressed: _busy || _identity == null
                      ? null
                      : () => _run(() async => _captureProfile()),
                  child: Text(l.cpu_capture),
                ),
                if (cards.isNotEmpty)
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _stored,
                    hint: Text(l.cpu_load_saved),
                    items: [
                      for (final card in cards)
                        DropdownMenuItem(
                          value: card.id,
                          child: Text(card.name),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) {
                            final card = cards.firstWhere(
                              (card) => card.id == id,
                            );
                            _run(() async {
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
                              setState(() => _stored = id);
                            });
                          },
                  ),
                TextField(
                  controller: _profile,
                  enabled: !_busy,
                  minLines: 8,
                  maxLines: 16,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(labelText: 'JSON'),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => _run(() async => _save()),
                      child: Text(l.cpu_save),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: _profile.text),
                            ),
                      child: Text(l.cpu_copy_json),
                    ),
                  ],
                ),
                DropdownButton<int>(
                  value: _slot,
                  items: [
                    for (var i = 0; i < 8; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text('${l.cpu_slot} ${i + 1}'),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _slot = value!),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _busy || !online ? null : () => _run(_upload),
                      child: Text(l.cpu_upload),
                    ),
                    TextButton(
                      onPressed: _busy || !online
                          ? null
                          : () => _run(_readSlot),
                      child: Text(l.cpu_read_slot),
                    ),
                  ],
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_message.isNotEmpty) SelectableText(_message),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : _exit, child: Text(l.cpu_close)),
        ],
      ),
    );
  }
}
