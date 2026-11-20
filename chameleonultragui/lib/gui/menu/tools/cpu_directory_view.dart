import 'dart:math' as math;

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_card_access.dart';
import 'package:chameleonultragui/helpers/cpu_directory.dart';
import 'package:flutter/material.dart';

class CpuDirectoryView extends StatefulWidget {
  final CpuDirectoryTree tree;
  final CpuFileAddress? selected;
  final ValueChanged<CpuDirectoryEntry>? onOpen;
  final void Function(CpuDirectoryEntry, Offset)? onContextMenu;
  const CpuDirectoryView({
    super.key,
    required this.tree,
    this.selected,
    this.onOpen,
    this.onContextMenu,
  });

  @override
  State<CpuDirectoryView> createState() => _CpuDirectoryViewState();
}

class _CpuDirectoryViewState extends State<CpuDirectoryView> {
  final _expanded = <String, bool>{};

  List<Widget> _rows(AppLocalizations l, CpuFileAddress? parent, int depth) => [
    for (final entry in widget.tree.childrenOf(parent))
      ..._entry(l, entry, depth),
  ];

  List<Widget> _entry(AppLocalizations l, CpuDirectoryEntry entry, int depth) {
    final address = entry.address;
    final id = address.display;
    final children = widget.tree.childrenOf(address);
    final expanded = _expanded[id] ?? depth < 2;
    final kind = entry.kind == CpuLiveFileKind.directory
        ? 'DF'
        : entry.kind == CpuLiveFileKind.record
        ? 'EF · ${l.cpu_manage_record_kind}'
        : 'EF';
    final title = entry.label.isEmpty ? address.entryLabel : entry.label;
    final size = entry.capacity;
    final details = [
      entry.isMaster ? '3F00' : kind,
      if (!entry.isMaster && entry.label.isNotEmpty) address.entryLabel,
      if (address.aid == null && entry.applicationAid != null)
        'AID ${cpuAidHex(entry.applicationAid!)}',
      if (size != null) l.cpu_tree_capacity(size),
    ].join(' · ');
    return [
      GestureDetector(
        key: ValueKey('cpu-directory:$id'),
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: widget.onContextMenu == null
            ? null
            : (details) => widget.onContextMenu!(entry, details.globalPosition),
        onLongPressStart: widget.onContextMenu == null
            ? null
            : (details) => widget.onContextMenu!(entry, details.globalPosition),
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsetsDirectional.only(
            start: 8.0 + 18 * math.min(depth, 4),
          ),
          leading: Icon(
            entry.isDirectory
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
          ),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
          selected: widget.selected?.display == id,
          onTap: widget.onOpen == null ? null : () => widget.onOpen!(entry),
          trailing: children.isEmpty
              ? null
              : IconButton(
                  tooltip: expanded ? l.cpu_tree_collapse : l.cpu_tree_expand,
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _expanded[id] = !expanded),
                ),
        ),
      ),
      if (expanded)
        for (final child in children) ..._entry(l, child, depth + 1),
    ];
  }

  @override
  Widget build(BuildContext context) =>
      Column(children: _rows(AppLocalizations.of(context)!, null, 0));
}
