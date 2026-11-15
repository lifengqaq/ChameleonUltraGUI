import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/cpu_emv.dart';
import 'package:flutter/material.dart';

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