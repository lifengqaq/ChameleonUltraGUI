import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:flutter/material.dart';

typedef CpuPinChangeRequest = ({
  CpuAuthSettings settings,
  String previous,
  String next,
});

Future<CpuPinChangeRequest?> showCpuPinChange(
  BuildContext context,
  String target,
) => showDialog<CpuPinChangeRequest>(
  context: context,
  builder: (_) => _CpuPinChangeDialog(target),
);

class _CpuPinChangeDialog extends StatefulWidget {
  final String target;
  const _CpuPinChangeDialog(this.target);

  @override
  State<_CpuPinChangeDialog> createState() => _CpuPinChangeDialogState();
}

class _CpuPinChangeDialogState extends State<_CpuPinChangeDialog> {
  final _form = GlobalKey<FormState>();
  final _reference = TextEditingController(),
      _current = TextEditingController(),
      _next = TextEditingController(),
      _confirm = TextEditingController();
  CpuPinEncoding _encoding = CpuPinEncoding.ascii;

  @override
  void dispose() {
    for (final controller in [_reference, _current, _next, _confirm]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final validPin = RegExp(r'^\d{4,12}$');
    Widget pin(
      TextEditingController controller,
      String label,
      String? Function(String) check,
    ) => TextFormField(
      controller: controller,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        if (value == null || !validPin.hasMatch(value))
          return l.cpu_manage_pin_format;
        return check(value);
      },
    );
    return AlertDialog(
      title: Text(l.cpu_manage_change_pin),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.target),
                const SizedBox(height: 8),
                Text(l.cpu_manage_change_pin_help),
                TextFormField(
                  controller: _reference,
                  autofocus: true,
                  maxLength: 2,
                  decoration: InputDecoration(
                    labelText: l.cpu_manage_pin_ref,
                    counterText: '',
                  ),
                  validator: (value) =>
                      value != null &&
                          RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(value)
                      ? null
                      : l.cpu_manage_invalid,
                ),
                DropdownButtonFormField<CpuPinEncoding>(
                  initialValue: _encoding,
                  isExpanded: true,
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
                      child: Text('ISO 9564 format 2'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _encoding = value);
                  },
                ),
                pin(_current, l.cpu_manage_old_pin, (_) => null),
                pin(
                  _next,
                  l.cpu_manage_new_pin,
                  (value) =>
                      _encoding == CpuPinEncoding.ascii &&
                          value.length != _current.text.length
                      ? l.cpu_manage_pin_equal_length
                      : null,
                ),
                pin(
                  _confirm,
                  l.cpu_manage_confirm_pin,
                  (value) =>
                      value == _next.text ? null : l.cpu_manage_pins_differ,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, (
              settings: CpuAuthSettings(
                reference: int.parse(_reference.text, radix: 16),
                pinEncoding: _encoding,
              ),
              previous: _current.text,
              next: _next.text,
            ));
          },
          child: Text(l.ok),
        ),
      ],
    );
  }
}
