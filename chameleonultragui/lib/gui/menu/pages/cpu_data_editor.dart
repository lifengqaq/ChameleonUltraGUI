import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_security.dart';
import 'package:chameleonultragui/helpers/cpu_security.dart';

import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/pages/cpu_archive_view.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_filesystem.dart';
import 'package:chameleonultragui/helpers/cpu_live_archive.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';

/// The native card/slot data editor. Identity belongs to CardEditMenu instead.
class CpuDataEditor extends StatefulWidget {
  final CardSave card;
  final ValueChanged<CardSave> onSave;
  const CpuDataEditor({super.key, required this.card, required this.onSave});
  @override
  State<CpuDataEditor> createState() => _CpuDataEditorState();
}

class _CpuDataEditorState extends State<CpuDataEditor> {
  CpuFileSystem? _filesystem;
  late final TextEditingController _json;
  String? _error;
  bool _jsonEdited = false;

  @override
  void initState() {
    super.initState();
    final image = cpuFilesystemFromData(widget.card.data);
    if (image != null) {
      _filesystem = CpuFileSystem.decode(image);
    } else if (widget.card.data.isEmpty &&
        widget.card.extraData.cpuDump['archiveOnly'] != true) {
      _filesystem = CpuFileSystem([
        CpuFileNode(parent: 255, type: 0, fid: 0x3F00),
      ]);
    }
    _json = TextEditingController(text: cpuSavedProfileJson(widget.card));
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _save() {
    try {
      if (_filesystem?.hasLegacyMixedAuthentication == true) {
        setState(
          () =>
              _error = AppLocalizations.of(context)!.cpu_security_mixed_warning,
        );
        return;
      }
      final result = CardSave.fromJson(widget.card.toJson());
      result.data = _jsonEdited
          ? cpuProfileFromJson(_json.text).data
          : _filesystem != null
          ? <Uint8List>[_filesystem!.encode()]
          : widget.card.data;
      if (result.data.isNotEmpty && result.extraData.cpuDump.isNotEmpty) {
        result.extraData.cpuDump['archiveOnly'] = false;
        result.extraData.cpuDump['emulationSubsetEdited'] = true;
      }
      // Basic identity, card id, folder and other metadata are never read from JSON.
      widget.onSave(result);
      Navigator.of(context).pop();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _change(CpuFileSystem value) {
    try {
      final card = CardSave.fromJson(widget.card.toJson())
        ..data = [value.encode()];
      setState(() {
        _filesystem = value;
        _json.text = cpuSavedProfileJson(card);
        _jsonEdited = false;
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final archive = widget.card.extraData.cpuDump;
    final isLiveArchive = archive['format'] == cpuLiveArchiveFormat;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.cpu_data_title),
        actions: [
          if (isLiveArchive)
            IconButton(
              tooltip: l.cpu_archive_export_json,
              icon: const Icon(Icons.save_alt),
              onPressed: () async {
                try {
                  await saveTag(widget.card, context, false);
                } catch (_) {
                  if (context.mounted)
                    setState(() => _error = l.cpu_manage_unexpected_file);
                }
              },
            ),
          TextButton(onPressed: _save, child: Text(l.save)),
        ],
      ),
      body: ListView(
        key: const PageStorageKey('cpu-native-data-scroll'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.card.name, style: Theme.of(context).textTheme.titleLarge),
          Text(l.cpu_data_identity_help),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          if (widget.card.extraData.cpuDump.isNotEmpty) ...[
            Text(l.cpu_dump_not_clone),
            if (widget.card.extraData.cpuDump['archiveOnly'] == true)
              Text(l.cpu_dump_archive_only),
          ],
          if (isLiveArchive) CpuLiveArchiveView(archive: archive),
          if (_filesystem != null)
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.lock_outline),
                  label: Text(l.cpu_security_title),
                  onPressed: () async {
                    final security = await showDialog<CpuSecurity>(
                      context: context,
                      builder: (_) =>
                          CpuSecurityDialog(initial: _filesystem!.security),
                    );
                    if (security != null && mounted) {
                      final previous = _filesystem!;
                      final oldPin = previous.security?.pin.isNotEmpty == true;
                      final oldKey = previous.security?.key.isNotEmpty == true;
                      final newPin = security.pin.isNotEmpty;
                      final changesMethod =
                          previous.security != null &&
                          (oldPin != newPin ||
                              oldKey != !newPin ||
                              previous.security!.sm4Challenge !=
                                  security.sm4Challenge);
                      if (changesMethod) {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(l.cpu_security_title),
                            content: Text(l.cpu_security_change_method),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: Text(l.cancel),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: Text(l.ok),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true || !mounted) return;
                      }
                      _change(previous.withAuthentication(security));
                    }
                  },
                ),
                if (_filesystem!.security != null)
                  TextButton(
                    onPressed: () {
                      if (_filesystem!.nodes.any((n) => n.access & 60 != 0)) {
                        setState(() => _error = l.cpu_security_remove_guard);
                        return;
                      }
                      _change(CpuFileSystem(_filesystem!.nodes));
                    },
                    child: Text(l.cpu_security_remove),
                  ),
              ],
            ),
          if (_filesystem?.hasLegacyMixedAuthentication == true)
            Text(
              l.cpu_security_mixed_warning,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else if (_filesystem != null)
            CpuFilesystemEditor(filesystem: _filesystem!, onChanged: _change)
          else ...[
            Text(l.cpu_legacy_data_help),
            OutlinedButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l.cpu_files_new),
                    content: Text(l.cpu_replace_data_warning),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(l.cancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(l.ok),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && mounted)
                  _change(
                    CpuFileSystem([
                      CpuFileNode(parent: 255, type: 0, fid: 0x3F00),
                    ]),
                  );
              },
              child: Text(l.cpu_files_new),
            ),
          ],
          const SizedBox(height: 16),
          ExpansionTile(
            key: const PageStorageKey('cpu-native-json-expanded'),
            title: Text(l.cpu_profile_json),
            children: [
              Text(l.cpu_data_json_help),
              TextField(
                key: const PageStorageKey('cpu-native-json-scroll'),
                controller: _json,
                minLines: 6,
                maxLines: 16,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                onChanged: (_) => _jsonEdited = true,
                decoration: const InputDecoration(labelText: 'JSON'),
              ),
              TextButton(
                onPressed: () {
                  try {
                    final card = cpuProfileFromJson(_json.text);
                    final image = cpuFilesystemFromData(card.data);
                    if (image == null)
                      throw FormatException(l.cpu_legacy_data_help);
                    _change(CpuFileSystem.decode(image));
                  } on FormatException catch (error) {
                    setState(() => _error = error.message);
                  }
                },
                child: Text(l.cpu_data_apply_json),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
