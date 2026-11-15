import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter/material.dart';

class CpuFilesystemEditor extends StatelessWidget {
  final CpuFileSystem filesystem;
  final ValueChanged<CpuFileSystem>? onChanged;
  const CpuFilesystemEditor({super.key, required this.filesystem, this.onChanged});

  Future<void> _edit(BuildContext context, int index, {int? newType}) async {
    final fs = await showDialog<CpuFileSystem>(context: context,
      builder: (_) => _FileDialog(filesystem: filesystem, index: index, newType: newType));
    if (fs != null) onChanged?.call(fs);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l.cpu_files_title, style: Theme.of(context).textTheme.titleMedium),
      Text('${filesystem.encode().length} / 3252 B · ${filesystem.nodes.length} / 16'),
      const SizedBox(height: 8),
      for (var i = 0; i < filesystem.nodes.length; i++) Builder(builder: (context) {
        final node = filesystem.nodes[i];
        var depth = 0, parent = node.parent;
        while (parent != 255) { depth++; parent = filesystem.nodes[parent].parent; }
        return ListTile(
          contentPadding: EdgeInsets.only(left: depth * 12.0),
          leading: Icon(node.type == 0 ? Icons.folder_outlined : Icons.description_outlined),
          title: Text('${node.fid.toRadixString(16).padLeft(4, '0').toUpperCase()} · ${['DF','EF BINARY','EF RECORDS'][node.type]}'),
          subtitle: Text(node.type == 0 ? (node.aid.isEmpty ? l.cpu_files_directory : 'AID ${bytesToHexSpace(node.aid)}')
              : '${node.data.length} B${node.sfi == 0 ? '' : ' · SFI ${node.sfi}'}${node.type == 2 ? ' · ${node.recordLength} B/record' : ''}'),
          trailing: onChanged == null ? null : const Icon(Icons.edit_outlined),
          onTap: onChanged == null ? null : () => _edit(context, i),
        );
      }),
      Wrap(spacing: 8, children: [for (var type = 0; type < 3; type++) OutlinedButton.icon(
        onPressed: onChanged == null || filesystem.nodes.length >= 16 ? null
            : () => _edit(context, filesystem.nodes.length, newType: type),
        icon: Icon(type == 0 ? Icons.create_new_folder_outlined : Icons.note_add_outlined),
        label: Text([l.cpu_files_add_df,l.cpu_files_add_binary,l.cpu_files_add_records][type]),
      )]),
      const SizedBox(height: 8),
      Text(l.cpu_files_persist_help, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _FileDialog extends StatefulWidget {
  final CpuFileSystem filesystem;
  final int index;
  final int? newType;
  const _FileDialog({required this.filesystem, required this.index, this.newType});
  @override
  State<_FileDialog> createState() => _FileDialogState();
}

class _FileDialogState extends State<_FileDialog> {
  late final TextEditingController _fid, _aid, _sfi, _record, _data, _fci;
  late int _parent, _type;
  late bool _read, _write;
  late int _readAuth, _writeAuth;
  String? _error;
  bool get _root => widget.index == 0;
  @override
  void initState() {
    super.initState();
    final node = widget.newType == null ? widget.filesystem.nodes[widget.index]
        : CpuFileNode(parent: 0, type: widget.newType!, fid: 0x1000 + widget.index,
            access: widget.newType == 0 ? 0 : 1, recordLength: widget.newType == 2 ? 4 : 0);
    _fid = TextEditingController(text: node.fid.toRadixString(16).padLeft(4, '0').toUpperCase());
    _aid = TextEditingController(text: bytesToHexSpace(node.aid));
    _sfi = TextEditingController(text: '${node.sfi}');
    _record = TextEditingController(text: '${node.recordLength}');
    _data = TextEditingController(text: bytesToHexSpace(node.data));
    _fci = TextEditingController(text: bytesToHexSpace(node.fci));
    _parent = node.parent; _type = node.type;
    _read = (node.access & 1) != 0; _write = (node.access & 2) != 0;
    _readAuth = node.access & 4 != 0 ? 1 : node.access & 16 != 0 ? 2 : 0;
    _writeAuth = node.access & 8 != 0 ? 1 : node.access & 32 != 0 ? 2 : 0;
  }
  @override
  void dispose() {
    for (final c in [_fid,_aid,_sfi,_record,_data,_fci]) { c.dispose(); }
    super.dispose();
  }
  void _save() {
    try {
      final fid = cpuHex(_fid.text, min: 2, max: 2);
      final node = CpuFileNode(parent: _parent, type: _type, fid: fid[0] << 8 | fid[1],
        sfi: _type == 0 ? 0 : int.parse(_sfi.text),
        access: _type == 0 ? 0 : (_read ? 1 : 0) | (_write ? 2 : 0) |
          (_read && _readAuth == 1 ? 4 : 0) | (_read && _readAuth == 2 ? 16 : 0) |
          (_write && _writeAuth == 1 ? 8 : 0) | (_write && _writeAuth == 2 ? 32 : 0),
        recordLength: _type == 2 ? int.parse(_record.text) : 0,
        aid: _type == 0 ? cpuHex(_aid.text, max: 16) : [],
        fci: cpuHex(_fci.text, max: 240), data: _type == 0 ? [] : cpuHex(_data.text, max: 3252));
      final nodes = [...widget.filesystem.nodes];
      if (widget.newType == null) { nodes[widget.index] = node; } else { nodes.add(node); }
      final fs = CpuFileSystem(nodes, security: widget.filesystem.security); fs.encode();
      Navigator.pop(context, fs);
    } on FormatException catch (e) { setState(() => _error = e.message); }
  }
  void _delete() {
    final nodes = [...widget.filesystem.nodes]..removeAt(widget.index);
    final fs = CpuFileSystem([for (final n in nodes) CpuFileNode(
      parent: n.parent != 255 && n.parent > widget.index ? n.parent - 1 : n.parent,
      type:n.type, fid:n.fid,sfi:n.sfi,access:n.access,recordLength:n.recordLength,
      aid:n.aid,fci:n.fci,data:n.data)], security: widget.filesystem.security);
    fs.encode(); Navigator.pop(context, fs);
  }
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.cpu_files_edit),
      content: SizedBox(width: 480, child: SingleChildScrollView(key: const PageStorageKey('cpu-file-editor-scroll'), child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextField(key:const PageStorageKey('cpu-fid-editor-scroll'),controller:_fid, enabled: !_root, decoration: const InputDecoration(labelText: 'FID (hex)')),
          if (!_root) ...[
            DropdownButtonFormField<int>(value:_parent,isExpanded:true,
              decoration: InputDecoration(labelText:l.cpu_files_parent),
              items:[for (var i=0;i<widget.index;i++) if (widget.filesystem.nodes[i].type == 0)
                DropdownMenuItem(value:i,child:Text('$i · ${widget.filesystem.nodes[i].fid.toRadixString(16).padLeft(4,'0').toUpperCase()}'))],
              onChanged:(v)=>setState(()=>_parent=v!)),
            DropdownButtonFormField<int>(value:_type,isExpanded:true,
              decoration: InputDecoration(labelText:l.cpu_files_type),
              items:[for (var i=0;i<3;i++) DropdownMenuItem(value:i,child:Text(['DF','EF BINARY','EF RECORDS'][i]))],
              onChanged:(v)=>setState(()=>_type=v!)),
          ],
          if (_type == 0 && !_root) TextField(key:const PageStorageKey('cpu-aid-editor-scroll'),controller:_aid,decoration:const InputDecoration(labelText:'AID (hex)')),
          if (_type != 0) ...[
            TextField(key:const PageStorageKey('cpu-sfi-editor-scroll'),controller:_sfi,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'SFI (0–30)')),
            CheckboxListTile(contentPadding:EdgeInsets.zero,title:Text(l.cpu_files_read),value:_read,onChanged:(v)=>setState(()=>_read=v!)),
            CheckboxListTile(contentPadding:EdgeInsets.zero,title:Text(l.cpu_files_write),value:_write,onChanged:(v)=>setState(()=>_write=v!)),
            if (_read) DropdownButtonFormField<int>(value:_readAuth,
              decoration:InputDecoration(labelText:l.cpu_access_read), items:[
                DropdownMenuItem(value:0,child:Text(l.cpu_access_public)),
                if(widget.filesystem.security?.pin.isNotEmpty == true) DropdownMenuItem(value:1,child:Text(l.cpu_access_pin)),
                if(widget.filesystem.security?.key.isNotEmpty == true) DropdownMenuItem(value:2,child:Text(l.cpu_access_key)),
              ],onChanged:(v){if(v!=null)setState(()=>_readAuth=v);}),
            if (_write) DropdownButtonFormField<int>(value:_writeAuth,
              decoration:InputDecoration(labelText:l.cpu_access_write), items:[
                DropdownMenuItem(value:0,child:Text(l.cpu_access_public)),
                if(widget.filesystem.security?.pin.isNotEmpty == true) DropdownMenuItem(value:1,child:Text(l.cpu_access_pin)),
                if(widget.filesystem.security?.key.isNotEmpty == true) DropdownMenuItem(value:2,child:Text(l.cpu_access_key)),
              ],onChanged:(v){if(v!=null)setState(()=>_writeAuth=v);}),
            if (_type == 2) TextField(key:const PageStorageKey('cpu-record-editor-scroll'),controller:_record,keyboardType:TextInputType.number,decoration:InputDecoration(labelText:l.cpu_files_record_length)),
            TextField(key:const PageStorageKey('cpu-data-editor-scroll'),controller:_data,minLines:2,maxLines:5,style:const TextStyle(fontFamily:'monospace'),decoration:InputDecoration(labelText:l.cpu_files_data)),
          ],
          ExpansionTile(key:const PageStorageKey('cpu-fci-expanded'),tilePadding:EdgeInsets.zero,title:Text(l.cpu_files_custom_fci),children:[
            TextField(key:const PageStorageKey('cpu-fci-editor-scroll'),controller:_fci,minLines:2,maxLines:4,decoration:const InputDecoration(labelText:'FCI (hex, without SW1/SW2)')),
          ]),
        ]))),
      actions:[
        if (!_root && widget.newType == null && !widget.filesystem.nodes.any((n)=>n.parent == widget.index))
          TextButton(onPressed:_delete,child:Text(l.cpu_files_delete)),
        TextButton(onPressed:()=>Navigator.pop(context),child:Text(l.cancel)),
        FilledButton(onPressed:_save,child:Text(l.ok)),
      ],
    );
  }
}
