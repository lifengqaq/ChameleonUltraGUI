import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_emv.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:flutter/material.dart';

String cpuCommandErrorText(AppLocalizations l, CpuCommandError error) =>
    switch (error.status) {
      null => l.cpu_error_no_response,
      0x01 => l.cpu_error_no_card,
      0x04 => l.cpu_error_collision,
      0x08 => l.cpu_error_ats,
      0x02 || 0x03 || 0x05 || 0x07 => l.cpu_error_rf,
      0x60 => l.cpu_error_parameters,
      0x66 => l.cpu_error_mode,
      0x67 || 0x69 => l.cpu_error_firmware,
      0x72 => l.cpu_error_slot,
      _ => l.cpu_error_device,
    };

String cpuStatusText(AppLocalizations l, int status) =>
    switch (cpuStatusMeaning(status)) {
      CpuStatusMeaning.success => l.cpu_status_success,
      CpuStatusMeaning.parameters => l.cpu_status_parameters,
      CpuStatusMeaning.instruction => l.cpu_status_instruction,
      CpuStatusMeaning.notFound => l.cpu_status_not_found,
      CpuStatusMeaning.authentication => l.cpu_status_authentication,
      CpuStatusMeaning.conditions => l.cpu_status_conditions,
      CpuStatusMeaning.length => l.cpu_status_length,
      CpuStatusMeaning.other => l.cpu_status_other,
    };

String _stepText(AppLocalizations l, CpuEmvStepKind kind) => switch (kind) {
  CpuEmvStepKind.directory => l.cpu_step_directory,
  CpuEmvStepKind.application => l.cpu_step_application,
  CpuEmvStepKind.processing => l.cpu_step_processing,
  CpuEmvStepKind.record => l.cpu_step_record,
  CpuEmvStepKind.other => l.cpu_step_other,
};

class CpuInfoRow extends StatelessWidget {
  final String label;
  final String value;
  const CpuInfoRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

/// Kept separate from the device controller so the summary can be rendered and
/// tested without connecting hardware or loading saved profiles.
class CpuEmvSummaryPanel extends StatelessWidget {
  final CpuEmvSummary summary;
  const CpuEmvSummaryPanel({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  summary.hasCardError || summary.hasMalformedData
                      ? Icons.info_outline
                      : Icons.check_circle_outline,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    summary.hasCardError || summary.hasMalformedData
                        ? l.cpu_emv_partial
                        : l.cpu_emv_result,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (summary.applicationLabel != null)
              CpuInfoRow(label: l.cpu_application, value: summary.applicationLabel!),
            if (summary.aid != null)
              CpuInfoRow(label: 'AID', value: summary.aid!),
            if (summary.maskedPan != null)
              CpuInfoRow(label: l.cpu_card_number, value: summary.maskedPan!),
            if (summary.expiry != null)
              CpuInfoRow(label: l.cpu_expiry, value: summary.expiry!),
            if (summary.cardholder != null)
              CpuInfoRow(label: l.cpu_cardholder, value: summary.cardholder!),
            if (summary.transactionCounter != null)
              CpuInfoRow(label: 'ATC', value: '${summary.transactionCounter}'),
            Text(l.cpu_emv_data_help, style: theme.textTheme.bodySmall),
            const Divider(height: 28),
            Text(l.cpu_read_steps, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final step in summary.steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      step.status == 0x9000 && !step.malformedData
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                      size: 19,
                      color: step.status == 0x9000
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_stepText(l, step.kind)),
                          Text(
                            '${step.status.toRadixString(16).padLeft(4, '0').toUpperCase()} · ${cpuStatusText(l, step.status)}',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (step.malformedData)
                            Text(l.cpu_tlv_error, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (summary.gpoReturnedData && !summary.hasAfl && !summary.hasMalformedData) ...[
              const SizedBox(height: 12),
              Text(l.cpu_no_afl, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
class CpuIdentityPanel extends StatelessWidget {
  final CardData? identity;
  const CpuIdentityPanel({super.key, this.identity});
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final identity = this.identity;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.contactless_outlined),
              const SizedBox(width: 10),
              Expanded(child: Text(
                identity == null ? l.cpu_place_card : l.cpu_card_identified,
                style: Theme.of(context).textTheme.titleMedium,
              )),
            ]),
            const SizedBox(height: 10),
            if (identity == null)
              Text(l.cpu_place_help)
            else ...[
              CpuInfoRow(label: 'UID', value: bytesToHexSpace(identity.uid)),
              Text(l.cpu_type_a, style: Theme.of(context).textTheme.bodySmall),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(l.cpu_radio_details),
                children: [
                  CpuInfoRow(label: 'ATQA', value: bytesToHexSpace(identity.atqa)),
                  CpuInfoRow(label: 'SAK', value: identity.sak.toRadixString(16).padLeft(2, '0').toUpperCase()),
                  CpuInfoRow(label: 'ATS', value: bytesToHexSpace(identity.ats)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
