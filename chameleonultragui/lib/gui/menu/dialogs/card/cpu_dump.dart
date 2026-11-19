import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_auth.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:chameleonultragui/helpers/cpu_dump.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

Future<CardSave?> showCpuDumpDialog(
  BuildContext context,
  CardData identity, {
  String name = '',
  List<CpuApduPair> capture = const [],
}) => showDialog<CardSave>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      CpuDumpDialog(identity: identity, name: name, capture: capture),
);

class CpuDumpDialog extends StatefulWidget {
  final CardData identity;
  final String name;
  final List<CpuApduPair> capture;
  const CpuDumpDialog({
    super.key,
    required this.identity,
    this.name = '',
    this.capture = const [],
  });
  @override
  State<CpuDumpDialog> createState() => _CpuDumpDialogState();
}

class _CpuDumpDialogState extends State<CpuDumpDialog> {
  late final TextEditingController _name;
  final _paths = TextEditingController(text: '2F00');
  final _aid = TextEditingController();
  bool _full = false, _busy = false;
  String _family = 'generic';
  String? _error;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: widget.name.isEmpty
          ? 'CPU ${bytesToHexSpace(widget.identity.uid)}'
          : widget.name,
    );
    if (cpuCaptureLooksLikeEmv(widget.capture)) _family = 'emv';
  }

  @override
  void dispose() {
    _name.dispose();
    _paths.dispose();
    _aid.dispose();
    super.dispose();
  }

  CardSave _card(List<Uint8List> data, Map<String, dynamic> dump) => CardSave(
    uid: bytesToHexSpace(widget.identity.uid),
    name: _name.text.trim(),
    tag: TagType.hf14a4,
    sak: widget.identity.sak,
    atqa: widget.identity.atqa,
    ats: widget.identity.ats,
    data: data,
    extraData: CardSaveExtra(cpuApplication: _family, cpuDump: dump),
  );

  Future<void> _save() async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = l.cpu_dump_name_required);
      return;
    }
    if (!_full) {
      Navigator.pop(context, _card([], {}));
      return;
    }
    List<CpuDumpTarget> targets;
    try {
      final aid = cpuHex(_aid.text, max: 16);
      if (aid.isNotEmpty && aid.length < 5) throw const FormatException('AID');
      targets = _family == 'emv'
          ? []
          : parseCpuDumpPaths(_paths.text, aid: aid);
    } on FormatException {
      setState(() => _error = l.cpu_dump_paths_invalid);
      return;
    }
    final app = context.read<ChameleonGUIState>();
    if (app.connector?.connected != true ||
        app.connector?.device != ChameleonDevice.ultra ||
        app.communicator == null) {
      setState(() => _error = l.device_required);
      return;
    }
    final device = app.communicator!;
    setState(() {
      _busy = true;
      _error = null;
    });
    var sessionOpen = false;
    try {
      await device.setReaderDeviceMode(true);
      final capture = List<CpuApduPair>.of(widget.capture);
      if (_family == 'emv') {
        if (capture.isEmpty) {
          final scanned = parseCpuEmvScan(await device.hf14a4EmvScan());
          if (!listEquals(scanned.$1.uid, widget.identity.uid))
            throw StateError(l.cpu_dump_card_changed);
          capture.addAll(scanned.$2);
        }
        if (capture.isEmpty) {
          setState(() => _error = l.cpu_dump_emv_no_responses);
          return;
        }
        targets = cpuEmvReadTargets(capture);
      }
      final identity = await device.hf14a4OpenSession();
      sessionOpen = true;
      if (!listEquals(identity.uid, widget.identity.uid))
        throw StateError(l.cpu_dump_card_changed);
      final history = cpuAuthHistoryForCard(identity.uid, identity.ats);
      final reader = CpuDumpReader(
        exchange: device.hf14a4ReaderApdu,
        authenticate: () async {
          if (!mounted) return false;
          return showCpuAuthentication(
            context,
            exchange: device.hf14a4ReaderApdu,
            history: history,
            initial: _family == 'emv'
                ? const CpuAuthSettings(
                    reference: 0x80,
                    pinEncoding: CpuPinEncoding.iso9564,
                  )
                : const CpuAuthSettings(),
          );
        },
      );
      final result = targets.isEmpty
          ? CpuDumpResult()
          : await reader.read(targets);
      if (_family == 'emv' && targets.isEmpty) {
        result.failures.add({'reason': cpuEmvReadPlanIssue(capture).name});
      }
      if (sessionOpen) {
        await device.hf14a4CloseSession();
        sessionOpen = false;
      }
      if (!mounted) return;
      if (result.files.isEmpty && capture.isEmpty) {
        setState(() => _error = l.cpu_dump_no_files);
        return;
      }
      final filesystem = result.deviceFilesystem();
      final dump = result.toJson();
      dump['archiveOnly'] = filesystem == null;
      dump['application'] = _family;
      if (_family == 'emv') {
        final issue = cpuEmvReadPlanIssue(capture);
        dump['emvReadPlanIssue'] = issue.name;
        dump['emvFailedStatusWord'] = cpuEmvReadPlanFailureStatus(
          capture,
          issue,
        );
      }
      dump['capturedResponses'] = [
        for (final p in capture)
          {
            'command': bytesToHexSpace(p.command),
            'response': bytesToHexSpace(p.response),
          },
      ];
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.cpu_dump_review),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${l.cpu_dump_files_read}: ${result.files.length}'),
                Text('${l.cpu_dump_files_failed}: ${result.failures.length}'),
                if (capture.isNotEmpty)
                  Text('${l.cpu_dump_capture_count}: ${capture.length}'),
                Text(
                  result.completeForPlan
                      ? l.cpu_dump_plan_complete
                      : l.cpu_dump_partial,
                ),
                Text(l.cpu_dump_not_clone),
                if (result.files.any((f) => f.authenticationRequired))
                  Text(l.cpu_dump_protection_help),
                if (filesystem == null) Text(l.cpu_dump_archive_only),
                for (final failure in result.failures)
                  if (failure['reason'] != null)
                    Builder(
                      builder: (context) {
                        if (failure['reason'] == 'read_limit_reached') {
                          return Text(l.cpu_dump_read_limit);
                        }
                        final issue = CpuEmvReadPlanIssue.values.firstWhere(
                          (value) => value.name == failure['reason'],
                          orElse: () => CpuEmvReadPlanIssue.noResponses,
                        );
                        final status = cpuEmvReadPlanFailureStatus(
                          capture,
                          issue,
                        );
                        return Text(
                          '${_emvFailureText(l, issue.name)}'
                          '${status == null ? '' : ' · SW ${status.toRadixString(16).padLeft(4, '0').toUpperCase()}'}',
                        );
                      },
                    ),
                for (final failure in result.failures)
                  if (failure['path'] != null)
                    Text(
                      l.cpu_dump_target_failed(
                        failure['path'].toString(),
                        _formatStatusWord(failure['status'] as int),
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.save),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted)
        Navigator.pop(
          context,
          _card(filesystem == null ? [] : [filesystem.encode()], dump),
        );
    } on CpuCommandError catch (error) {
      if (mounted) setState(() => _error = 'SW/Device ${error.toString()}');
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message.toString());
    } catch (_) {
      if (mounted) setState(() => _error = l.cpu_dump_failed);
    } finally {
      if (sessionOpen) {
        try {
          await device.hf14a4CloseSession();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  String _emvFailureText(AppLocalizations l, String reason) => switch (reason) {
    'noResponses' => l.cpu_dump_emv_no_responses,
    'directorySelectionFailed' => l.cpu_dump_emv_directory_failed,
    'applicationNotSelected' => l.cpu_dump_emv_application_missing,
    'applicationSelectionFailed' => l.cpu_dump_emv_application_failed,
    'gpoNotAttempted' => l.cpu_dump_emv_gpo_missing,
    'gpoFailed' => l.cpu_dump_emv_gpo_failed,
    'noUsableAfl' => l.cpu_dump_emv_no_afl,
    'read_limit_reached' => l.cpu_dump_read_limit,
    _ => l.cpu_dump_emv_unknown,
  };

  String _formatStatusWord(int value) =>
      value.toRadixString(16).padLeft(4, '0').toUpperCase();
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l.cpu_dump_save),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            key: const PageStorageKey('cpu-dump-dialog-scroll'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: l.name),
                ),
                DropdownButtonFormField<bool>(
                  isExpanded: true,
                  value: _full,
                  decoration: InputDecoration(labelText: l.cpu_dump_scope),
                  items: [
                    DropdownMenuItem(
                      value: false,
                      child: Text(l.cpu_dump_uid_only),
                    ),
                    DropdownMenuItem(value: true, child: Text(l.cpu_dump_full)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) setState(() => _full = value);
                        },
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _family,
                  decoration: InputDecoration(
                    labelText: l.cpu_application_type,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'generic',
                      child: Text(l.cpu_application_generic),
                    ),
                    DropdownMenuItem(
                      value: 'emv',
                      child: Text(l.cpu_application_emv),
                    ),
                    DropdownMenuItem(
                      value: 'ndef',
                      child: Text(l.cpu_application_ndef),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null)
                            setState(() {
                              _family = value;
                              if (value == 'ndef') {
                                _aid.text = 'D2760000850101';
                                _paths.text = 'E103,E104';
                              } else if (value == 'generic') {
                                _aid.clear();
                                _paths.text = '2F00';
                              }
                            });
                        },
                ),
                if (widget.capture.isNotEmpty)
                  Text(l.cpu_dump_capture_classification_help),
                if (_full) ...[
                  Text(
                    _family == 'emv'
                        ? l.cpu_dump_emv_help
                        : l.cpu_dump_plan_help,
                  ),
                  if (_family != 'emv')
                    TextField(
                      key: const PageStorageKey('cpu-dump-aid-editor'),
                      controller: _aid,
                      enabled: !_busy,
                      decoration: InputDecoration(labelText: l.cpu_dump_aid),
                    ),
                  if (_family != 'emv')
                    TextField(
                      key: const PageStorageKey('cpu-dump-paths-editor'),
                      controller: _paths,
                      enabled: !_busy,
                      minLines: 2,
                      maxLines: 5,
                      decoration: InputDecoration(labelText: l.cpu_dump_paths),
                    ),
                  Text(l.cpu_auth_on_demand_help),
                ],
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(onPressed: _busy ? null : _save, child: Text(l.save)),
        ],
      ),
    );
  }
}
