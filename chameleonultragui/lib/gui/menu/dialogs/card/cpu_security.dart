import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_auth.dart'
    show CpuSm4ChallengeField;
import 'package:chameleonultragui/helpers/cpu_security.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/sm4.dart';
import 'package:flutter/material.dart';

class CpuSecurityDialog extends StatefulWidget {
  final CpuSecurity? initial;
  const CpuSecurityDialog({super.key, this.initial});
  @override
  State<CpuSecurityDialog> createState() => _CpuSecurityDialogState();
}

class _CpuSecurityDialogState extends State<CpuSecurityDialog> {
  late String _method;
  late int _encoding;
  late CpuSm4Challenge _sm4Challenge;
  late final TextEditingController _pin,
      _key,
      _pinRef,
      _keyRef,
      _algorithm,
      _pinTries,
      _keyTries;
  String? _error;
  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _method = s?.sm4Challenge != null
        ? 'sm4'
        : s?.key.isNotEmpty == true
        ? 'key'
        : 'pin';
    _sm4Challenge = s?.sm4Challenge ?? CpuSm4Challenge.padded8;
    _encoding = s?.pinEncoding ?? 0;
    _pin = TextEditingController(
      text: s?.pin.isNotEmpty == true ? s!.pin : '000000',
    );
    _key = TextEditingController(
      text: s?.key.isNotEmpty == true
          ? s!.key
                .map((v) => v.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase()
          : 'FFFFFFFFFFFFFFFF',
    );
    _pinRef = TextEditingController(
      text: (s?.pinReference ?? 0).toRadixString(16).padLeft(2, '0'),
    );
    _keyRef = TextEditingController(
      text: (s?.keyReference ?? 0).toRadixString(16).padLeft(2, '0'),
    );
    _algorithm = TextEditingController(
      text: (s?.algorithm ?? 0).toRadixString(16).padLeft(2, '0'),
    );
    _pinTries = TextEditingController(
      text: '${s != null && s.pin.isNotEmpty ? s.pinTries : 3}',
    );
    _keyTries = TextEditingController(
      text: '${s != null && s.key.isNotEmpty ? s.keyTries : 3}',
    );
  }

  @override
  void dispose() {
    for (final controller in [
      _pin,
      _key,
      _pinRef,
      _keyRef,
      _algorithm,
      _pinTries,
      _keyTries,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      final sm4 = _method == 'sm4';
      final s = CpuSecurity(
        pin: _method == 'pin' ? _pin.text : '',
        key: _method == 'pin'
            ? []
            : cpuHex(_key.text, min: sm4 ? 16 : 8, max: 16),
        sm4Challenge: sm4 ? _sm4Challenge : null,
        pinReference: int.parse(_pinRef.text, radix: 16),
        keyReference: int.parse(_keyRef.text, radix: 16),
        algorithm: int.parse(_algorithm.text, radix: 16),
        pinEncoding: _encoding,
        pinTries: int.parse(_pinTries.text),
        keyTries: int.parse(_keyTries.text),
      );
      s.encode();
      Navigator.pop(context, s);
    } on FormatException {
      final l = AppLocalizations.of(context)!;
      setState(
        () => _error = _method == 'sm4'
            ? l.cpu_auth_sm4_invalid
            : l.cpu_auth_invalid,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final isKey = _method != 'pin';
    final sm4 = _method == 'sm4';
    return AlertDialog(
      title: Text(l.cpu_security_title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          key: const PageStorageKey('cpu-security-dialog-scroll'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.cpu_security_help),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _method,
                decoration: InputDecoration(labelText: l.cpu_auth_type),
                items: [
                  DropdownMenuItem(value: 'pin', child: const Text('PIN')),
                  const DropdownMenuItem(
                    value: 'key',
                    child: Text('DES / 3DES'),
                  ),
                  const DropdownMenuItem(value: 'sm4', child: Text('SM4')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    if ((value == 'sm4') != (_method == 'sm4')) _key.clear();
                    _method = value;
                    _error = null;
                  });
                },
              ),
              if (_method == 'pin') ...[
                TextField(
                  key: const PageStorageKey('cpu-security-pin'),
                  controller: _pin,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'PIN'),
                ),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  value: _encoding,
                  decoration: InputDecoration(
                    labelText: l.cpu_auth_pin_encoding,
                  ),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('ASCII')),
                    DropdownMenuItem(value: 1, child: Text('BCD / FF')),
                    DropdownMenuItem(
                      value: 2,
                      child: Text('EMV plaintext PIN / format 2'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _encoding = v);
                  },
                ),
                TextField(
                  controller: _pinTries,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'PIN · ${l.cpu_security_retry_limit}',
                  ),
                ),
              ],
              if (isKey) ...[
                if (sm4)
                  CpuSm4ChallengeField(
                    value: _sm4Challenge,
                    onChanged: (value) {
                      if (value != null) setState(() => _sm4Challenge = value);
                    },
                  ),
                TextField(
                  key: const PageStorageKey('cpu-security-key'),
                  controller: _key,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: sm4
                        ? l.cpu_auth_sm4_key
                        : l.cpu_security_key_format,
                  ),
                ),
                TextField(
                  controller: _keyTries,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText:
                        '${sm4 ? 'SM4' : 'DES / 3DES'} · ${l.cpu_security_retry_limit}',
                  ),
                ),
              ],
              ExpansionTile(
                key: const PageStorageKey('cpu-security-refs-expanded'),
                title: Text(l.advanced),
                children: [
                  TextField(
                    key: const PageStorageKey('cpu-security-pin-ref'),
                    controller: _pinRef,
                    decoration: InputDecoration(
                      labelText: 'PIN · ${l.cpu_auth_reference}',
                    ),
                  ),
                  TextField(
                    key: const PageStorageKey('cpu-security-key-ref'),
                    controller: _keyRef,
                    decoration: InputDecoration(
                      labelText:
                          '${sm4 ? 'SM4' : 'DES / 3DES'} · ${l.cpu_auth_reference}',
                    ),
                  ),
                  TextField(
                    key: const PageStorageKey('cpu-security-algorithm'),
                    controller: _algorithm,
                    decoration: InputDecoration(
                      labelText: l.cpu_auth_algorithm,
                    ),
                  ),
                ],
              ),
              Text(l.cpu_security_counter_reset),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        FilledButton(onPressed: _save, child: Text(l.save)),
      ],
    );
  }
}
