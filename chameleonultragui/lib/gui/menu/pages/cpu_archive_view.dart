import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_live_archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class CpuLiveArchiveView extends StatelessWidget {
  const CpuLiveArchiveView({super.key, required this.archive});
  final Map<String, dynamic> archive;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final source = archive['entries'];
    final entries =
        (source is List ? source : const [])
            .whereType<Map>()
            .where((entry) => entry['address'] is String)
            .take(256)
            .toList()
          ..sort(
            (a, b) =>
                (a['address'] as String).compareTo(b['address'] as String),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          l.cpu_archive_save,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(l.cpu_archive_help),
        if (archive['captureLimited'] == true) Text(l.cpu_tree_incomplete),
        for (final entry in entries) _entry(context, l, entry),
      ],
    );
  }

  Widget _entry(BuildContext context, AppLocalizations l, Map entry) {
    final address = entry['address'] as String;
    final ranges = entry['readRanges'];
    final parts = ranges is List
        ? ranges.whereType<Map>().take(512).toList()
        : const <Map>[];
    final label = entry['label'];
    final summary = [
      if (label is String && label.isNotEmpty) label,
      if (entry['selectNotFound'] == true) l.cpu_tree_missing_aid,
      if (parts.isEmpty && entry['kind'] != 'directory') l.cpu_archive_no_data,
    ].join(' · ');
    final icon = Icon(
      entry['kind'] == 'directory'
          ? Icons.folder_outlined
          : Icons.insert_drive_file_outlined,
    );
    final control = entry['fci'];
    final ident =
        entry['fid'] is String &&
            RegExp(r'^[A-F0-9]{4}$').hasMatch(entry['fid'])
        ? 'cpu-${entry['fid']}'
        : 'cpu';
    final subtitle = summary.isEmpty ? null : Text(summary);
    final tile = parts.isEmpty && control is! String
        ? ListTile(
            dense: true,
            leading: icon,
            title: Text(address),
            subtitle: subtitle,
          )
        : ExpansionTile(
            leading: icon,
            title: Text(address),
            subtitle: subtitle,
            children: [
              if (control is String)
                ListTile(
                  dense: true,
                  title: const Text('FCI / FCP'),
                  subtitle: SelectableText(control),
                ),
              for (final part in parts) _range(context, l, part, ident),
            ],
          );
    final depth = '/'.allMatches(address).length.clamp(0, 5);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: depth * 12.0),
      child: tile,
    );
  }

  Widget _range(
    BuildContext context,
    AppLocalizations l,
    Map part,
    String ident,
  ) {
    final record = part['record'], offset = part['offset'];
    final index = record ?? offset;
    final hex = part['data'];
    if (index is! int || hex is! String) return const SizedBox.shrink();
    final label = record != null
        ? l.cpu_manage_record_number
        : l.cpu_manage_offset;
    final heading =
        '$label: $index · SW ${part['status']} · ${l.cpu_manage_bytes(hex.length ~/ 2)}';
    final limited = hex.length > 320;
    return ListTile(
      dense: true,
      title: Text(heading),
      subtitle: SelectableText(limited ? '${hex.substring(0, 320)}…' : hex),
      trailing: IconButton(
        icon: const Icon(Icons.save_alt),
        tooltip: l.cpu_archive_export_bin,
        onPressed: hex.isEmpty
            ? null
            : () async {
                try {
                  final bytes = cpuArchiveRangeData(hex);
                  await FilePicker.saveFile(
                    dialogTitle: l.cpu_archive_export_bin,
                    fileName:
                        '$ident-${record == null ? 'offset' : 'record'}-$index.bin',
                    bytes: bytes,
                  );
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.cpu_manage_unexpected_file)),
                    );
                  }
                }
              },
      ),
    );
  }
}
