import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:chameleonultragui/helpers/sm4.dart';
import 'package:flutter/material.dart';

Future<bool> showCpuAuthentication(
  BuildContext context, {
  required CpuAuthExchange exchange,
  required CpuAuthHistory history,
  CpuAuthSettings initial = const CpuAuthSettings(),
  bool prefillCredential = true,
  String? operation,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CpuAuthenticationDialog(
        exchange: exchange,
        history: history,
        initial: initial,
        prefillCredential: prefillCredential,
        operation: operation,
      ),
    ) ??
    false;

class CpuAuthenticationDialog extends StatefulWidget {
  final CpuAuthExchange exchange;
  final CpuAuthHistory history;
  final CpuAuthSettings initial;
  final bool prefillCredential;
  final String? operation;
  const CpuAuthenticationDialog({
    super.key,
    required this.exchange,
    required this.history,
    this.initial = const CpuAuthSettings(),
    this.prefillCredential = true,
    this.operation,
  });
  @override
  State<CpuAuthenticationDialog> createState() =>
      _CpuAuthenticationDialogState();
}

class _CpuAuthenticationDialogState extends State<CpuAuthenticationDialog> {
  late CpuAuthMethod _method;
  late CpuPinEncoding _encoding;
  late CpuSm4Challenge _sm4Challenge;
  late CpuFmcosChallenge _fmcosChallenge;
  late final TextEditingController _credential, _reference, _algorithm;
  bool _busy = false, _sending = false, _transportFailed = false;
  CpuAuthResult? _result;
  String? _error;
  bool get _fmcos => widget.initial.isFmcos;
  CpuAuthSettings get _settings => CpuAuthSettings(
    method: _method,
    pinEncoding: _encoding,
    sm4Challenge: _sm4Challenge,
    profile: widget.initial.profile,
    fmcosChallenge: _fmcosChallenge,
    reference: int.tryParse(_reference.text, radix: 16) ?? 0,
    algorithm: int.tryParse(_algorithm.text, radix: 16) ?? 0,
  );
  String _suggestedCredential() => !widget.prefillCredential || _fmcos
      ? ''
      : switch (_method) {
          CpuAuthMethod.pin => '000000',
          CpuAuthMethod.des => 'FFFFFFFFFFFFFFFF',
          CpuAuthMethod.tdes => 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
          CpuAuthMethod.sm4 => '',
        };
  @override
  void initState() {
    super.initState();
    _method = widget.initial.method;
    _encoding = widget.initial.pinEncoding;
    _sm4Challenge = widget.initial.sm4Challenge;
    _fmcosChallenge = widget.initial.fmcosChallenge;
    _credential = TextEditingController(text: _suggestedCredential());
    _reference = TextEditingController(
      text: widget.operation == null
          ? widget.initial.reference.toRadixString(16).padLeft(2, '0')
          : '',
    );
    _algorithm = TextEditingController(
      text: widget.initial.algorithm.toRadixString(16).padLeft(2, '0'),
    );
    _result = _reference.text.isEmpty
        ? null
        : widget.history.forSettings(_settings);
  }

  @override
  void dispose() {
    _credential.dispose();
    _reference.dispose();
    _algorithm.dispose();
    super.dispose();
  }

  void _changedReference() {
    setState(() {
      _result = _reference.text.isEmpty
          ? null
          : widget.history.forSettings(_settings);
      _error = null;
    });
  }

  Future<void> _authenticate() async {
    if (_busy || _transportFailed || _result?.blocked == true) return;
    final l = AppLocalizations.of(context)!;
    final settings = _settings;
    try {
      if (!RegExp(r'^[0-9a-fA-F]{1,2}$').hasMatch(_reference.text) ||
          !RegExp(r'^[0-9a-fA-F]{1,2}$').hasMatch(_algorithm.text)) {
        throw const FormatException('Invalid reference');
      }
      final bytes = _method == CpuAuthMethod.pin
          ? cpuAuthPinData(settings, _credential.text)
          : cpuAuthKey(_credential.text, _method, fmcos: _fmcos);
      bytes.fillRange(0, bytes.length, 0);
    } on FormatException {
      setState(
        () => _error = _fmcos
            ? l.cpu_auth_fmcos_invalid
            : _method == CpuAuthMethod.sm4
            ? l.cpu_auth_sm4_invalid
            : l.cpu_auth_invalid,
      );
      return;
    }
    setState(() => _busy = true);
    if (widget.history.forSettings(settings)?.remaining == 1) {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(l.cpu_auth_last_title),
          content: Text(l.cpu_auth_last_warning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
            TextButton(
              key: const ValueKey('cpu-auth-last-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.cpu_auth_continue),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    }
    setState(() {
      _busy = true;
      _sending = true;
      _error = null;
    });
    try {
      final result = await authenticateCpuCard(
        settings,
        _credential.text,
        widget.exchange,
      );
      widget.history.record(settings, result);
      if (!mounted) return;
      if (result.success) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _result = result;
      });
    } on FormatException {
      if (mounted) setState(() => _error = l.cpu_auth_profile_mismatch);
    } catch (_) {
      // Delivery could have succeeded before a timeout: never retry automatically.
      if (mounted)
        setState(() {
          _transportFailed = true;
          _error = l.cpu_auth_transport_unknown;
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _sending = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final errorColor = Theme.of(context).colorScheme.error;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l.cpu_auth_required),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            key: const PageStorageKey('cpu-auth-dialog-scroll'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.operation case final operation?) ...[
                  Text(operation),
                  const SizedBox(height: 8),
                ],
                Text(
                  _fmcos
                      ? l.cpu_auth_fmcos_help
                      : widget.prefillCredential
                      ? l.cpu_auth_help
                      : l.cpu_manage_auth_help,
                ),
                DropdownButtonFormField<CpuAuthMethod>(
                  isExpanded: true,
                  value: _method,
                  decoration: InputDecoration(labelText: l.cpu_auth_type),
                  items: [
                    const DropdownMenuItem(
                      value: CpuAuthMethod.pin,
                      child: Text('PIN'),
                    ),
                    DropdownMenuItem(
                      value: CpuAuthMethod.des,
                      child: Text(l.cpu_auth_des),
                    ),
                    DropdownMenuItem(
                      value: CpuAuthMethod.tdes,
                      child: Text(l.cpu_auth_tdes),
                    ),
                    if (!_fmcos)
                      DropdownMenuItem(
                        value: CpuAuthMethod.sm4,
                        child: Text(l.cpu_auth_sm4),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _method = value;
                            _credential.text = _suggestedCredential();
                            _result = _reference.text.isEmpty
                                ? null
                                : widget.history.forSettings(_settings);
                            _error = null;
                          });
                        },
                ),
                if (_method == CpuAuthMethod.pin && !_fmcos)
                  DropdownButtonFormField<CpuPinEncoding>(
                    isExpanded: true,
                    value: _encoding,
                    decoration: InputDecoration(
                      labelText: l.cpu_auth_pin_encoding,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: CpuPinEncoding.ascii,
                        child: Text('ASCII'),
                      ),
                      DropdownMenuItem(
                        value: CpuPinEncoding.bcd,
                        child: Text('BCD / FF padding'),
                      ),
                      DropdownMenuItem(
                        value: CpuPinEncoding.iso9564,
                        child: Text('EMV plaintext PIN / format 2'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null)
                              setState(() => _encoding = value);
                          },
                  ),
                if (_method == CpuAuthMethod.sm4) ...[
                  CpuSm4ChallengeField(
                    value: _sm4Challenge,
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null)
                              setState(() {
                                _sm4Challenge = value;
                                _error = null;
                              });
                          },
                  ),
                  Text(l.cpu_auth_sm4_help),
                ],
                if (_fmcos && _method != CpuAuthMethod.pin)
                  DropdownButtonFormField<CpuFmcosChallenge>(
                    isExpanded: true,
                    initialValue: _fmcosChallenge,
                    decoration: InputDecoration(
                      labelText: l.cpu_auth_fmcos_challenge,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: CpuFmcosChallenge.padded4,
                        child: Text(l.cpu_auth_fmcos_challenge_four),
                      ),
                      DropdownMenuItem(
                        value: CpuFmcosChallenge.raw8,
                        child: Text(l.cpu_auth_fmcos_challenge_eight),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null)
                              setState(() {
                                _fmcosChallenge = value;
                                _error = null;
                              });
                          },
                  ),
                TextField(
                  key: const PageStorageKey('cpu-auth-reference'),
                  controller: _reference,
                  enabled: !_busy,
                  onChanged: (_) => _changedReference(),
                  decoration: InputDecoration(labelText: l.cpu_auth_reference),
                ),
                if (_method != CpuAuthMethod.pin && !_fmcos)
                  TextField(
                    key: const PageStorageKey('cpu-auth-algorithm'),
                    controller: _algorithm,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: l.cpu_auth_algorithm,
                    ),
                  ),
                TextField(
                  key: const PageStorageKey('cpu-auth-credential'),
                  controller: _credential,
                  enabled: !_busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: switch (_method) {
                      CpuAuthMethod.pin =>
                        _fmcos ? l.cpu_auth_fmcos_pin : 'PIN',
                      CpuAuthMethod.sm4 => l.cpu_auth_sm4_key,
                      _ => l.cpu_auth_key,
                    },
                  ),
                ),
                if (_result != null && !_result!.success) ...[
                  Text(
                    'SW ${_result!.status.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                  ),
                  if (_result!.attempted || _result!.blocked)
                    Text(
                      _result!.blocked
                          ? l.cpu_auth_blocked
                          : _result!.remaining == null
                          ? l.cpu_auth_tries_unknown
                          : '${l.cpu_auth_tries}: ${_result!.remaining}',
                      key: const ValueKey('cpu-auth-remaining'),
                      style: TextStyle(
                        color: _result!.blocked || _result!.remaining == 1
                            ? errorColor
                            : null,
                      ),
                    ),
                ],
                if (_error != null)
                  Text(_error!, style: TextStyle(color: errorColor)),
                if (_sending) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(
              widget.operation == null ? l.cancel : l.cpu_manage_without_key,
            ),
          ),
          FilledButton(
            key: const ValueKey('cpu-auth-submit'),
            onPressed: _busy || _transportFailed || _result?.blocked == true
                ? null
                : _authenticate,
            child: Text(
              widget.operation != null
                  ? l.cpu_manage_auth_retry
                  : _result == null
                  ? l.cpu_authenticate
                  : l.cpu_auth_continue,
            ),
          ),
        ],
      ),
    );
  }
}

class CpuSm4ChallengeField extends StatelessWidget {
  final CpuSm4Challenge value;
  final ValueChanged<CpuSm4Challenge?>? onChanged;

  const CpuSm4ChallengeField({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return DropdownButtonFormField<CpuSm4Challenge>(
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(labelText: l.cpu_auth_sm4_challenge),
      items: [
        DropdownMenuItem(
          value: CpuSm4Challenge.padded8,
          child: Text(l.cpu_auth_sm4_padded),
        ),
        DropdownMenuItem(
          value: CpuSm4Challenge.raw16,
          child: Text(l.cpu_auth_sm4_raw),
        ),
      ],
      onChanged: onChanged,
    );
  }
}
