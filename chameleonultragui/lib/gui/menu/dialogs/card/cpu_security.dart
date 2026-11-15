import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_security.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:flutter/material.dart';

class CpuSecurityDialog extends StatefulWidget {
  final CpuSecurity? initial;
  const CpuSecurityDialog({super.key, this.initial});
  @override
  State<CpuSecurityDialog> createState() => _CpuSecurityDialogState();
}
class _CpuSecurityDialogState extends State<CpuSecurityDialog> {
  late bool _pinEnabled, _keyEnabled;
  late int _encoding;
  late final TextEditingController _pin, _key, _pinRef, _keyRef, _algorithm, _pinTries, _keyTries;
  String? _error;
  @override
  void initState() {
    super.initState(); final s = widget.initial;
    _pinEnabled = s == null || s.pin.isNotEmpty; _keyEnabled = s != null && s.key.isNotEmpty;
    _encoding = s?.pinEncoding ?? 0;
    _pin=TextEditingController(text: s?.pin.isNotEmpty == true ? s!.pin : '000000');
    _key=TextEditingController(text: s?.key.isNotEmpty == true
      ? s!.key.map((v)=>v.toRadixString(16).padLeft(2,'0')).join().toUpperCase() : 'FFFFFFFFFFFFFFFF');
    _pinRef=TextEditingController(text: (s?.pinReference ?? 0).toRadixString(16).padLeft(2,'0'));
    _keyRef=TextEditingController(text: (s?.keyReference ?? 0).toRadixString(16).padLeft(2,'0'));
    _algorithm=TextEditingController(text: (s?.algorithm ?? 0).toRadixString(16).padLeft(2,'0'));
    _pinTries=TextEditingController(text:'${s != null && s.pin.isNotEmpty ? s.pinTries : 3}');
    _keyTries=TextEditingController(text:'${s != null && s.key.isNotEmpty ? s.keyTries : 3}');
  }
  @override
  void dispose() {
    for (final controller in [_pin,_key,_pinRef,_keyRef,_algorithm,_pinTries,_keyTries]) {
      controller.dispose();
    }
    super.dispose();
  }
  void _save() {
    try {
      final s=CpuSecurity(pin:_pinEnabled ? _pin.text : '',key:_keyEnabled ? cpuHex(_key.text,max:16) : [],
        pinReference:int.parse(_pinRef.text,radix:16),keyReference:int.parse(_keyRef.text,radix:16),
        algorithm:int.parse(_algorithm.text,radix:16),pinEncoding:_encoding,
        pinTries:int.parse(_pinTries.text),keyTries:int.parse(_keyTries.text));
      s.encode(); Navigator.pop(context,s);
    } on FormatException { setState(()=>_error=AppLocalizations.of(context)!.cpu_auth_invalid); }
  }
  @override
  Widget build(BuildContext context) {
    final l=AppLocalizations.of(context)!;
    return AlertDialog(title:Text(l.cpu_security_title),content:SizedBox(width:440,
      child:SingleChildScrollView(key:const PageStorageKey('cpu-security-dialog-scroll'),
        child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Text(l.cpu_security_help),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('PIN'),value:_pinEnabled,
            onChanged:(value)=>setState(()=>_pinEnabled=value)),
          if(_pinEnabled) ...[
            TextField(key:const PageStorageKey('cpu-security-pin'),controller:_pin,obscureText:true,
              decoration:const InputDecoration(labelText:'PIN')),
            DropdownButtonFormField<int>(isExpanded: true, value:_encoding,decoration:InputDecoration(labelText:l.cpu_auth_pin_encoding),
              items:const [DropdownMenuItem(value:0,child:Text('ASCII')),DropdownMenuItem(value:1,child:Text('BCD / FF')),
                DropdownMenuItem(value:2,child:Text('EMV plaintext PIN / format 2'))],
              onChanged:(v){if(v!=null)setState(()=>_encoding=v);}),
            TextField(controller:_pinTries,keyboardType:TextInputType.number,
              decoration:InputDecoration(labelText:'PIN · ${l.cpu_security_retry_limit}')),
          ],
          SwitchListTile(contentPadding:EdgeInsets.zero,title:Text(l.cpu_auth_key),value:_keyEnabled,
            onChanged:(value)=>setState(()=>_keyEnabled=value)),
          if(_keyEnabled) ...[
            TextField(key:const PageStorageKey('cpu-security-key'),controller:_key,obscureText:true,
              decoration:InputDecoration(labelText:l.cpu_security_key_format)),
            TextField(controller:_keyTries,keyboardType:TextInputType.number,
              decoration:InputDecoration(labelText:'DES / 3DES · ${l.cpu_security_retry_limit}')),
          ],
          ExpansionTile(key:const PageStorageKey('cpu-security-refs-expanded'),title:Text(l.advanced),children:[
            TextField(key:const PageStorageKey('cpu-security-pin-ref'),controller:_pinRef,
              decoration:InputDecoration(labelText:'PIN · ${l.cpu_auth_reference}')),
            TextField(key:const PageStorageKey('cpu-security-key-ref'),controller:_keyRef,
              decoration:InputDecoration(labelText:'DES / 3DES · ${l.cpu_auth_reference}')),
            TextField(key:const PageStorageKey('cpu-security-algorithm'),controller:_algorithm,
              decoration:InputDecoration(labelText:l.cpu_auth_algorithm)),
          ]),
          Text(l.cpu_security_counter_reset),
          if(_error!=null)Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
        ]))),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:Text(l.cancel)),
        FilledButton(onPressed:_save,child:Text(l.save))]);
  }
}