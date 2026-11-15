import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_card.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_emv_summary.dart';
import 'package:chameleonultragui/helpers/cpu_emv.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic data with the same TLV structure as a PBOC GPO response.
List<int> _tlv(int tag, List<int> value) => [
  if (tag > 0xFF) tag >> 8,
  tag & 0xFF,
  if (value.length >= 128) 0x81,
  value.length,
  ...value,
];
CpuApduPair _pair(String command, List<int> response) => CpuApduPair(
  cpuHex(command), Uint8List.fromList([...response, 0x90, 0]),
);
List<int> _directoryResponse() {
  final application = [
    ..._tlv(0x4F, cpuHex('A000000333010101')),
    ..._tlv(0x50, 'PBOC DEBIT'.codeUnits),
  ];
  return _tlv(0x6F, _tlv(0xA5, _tlv(0xBF0C, _tlv(0x61, application))));
}
List<CpuApduPair> _sample() => [
  _pair('00A404000E325041592E5359532E444446303100', _directoryResponse()),
  _pair('00A4040008A00000033301010100', _tlv(0x6F, [
    ..._tlv(0x84, cpuHex('A000000333010101')),
    ..._tlv(0xA5, _tlv(0x50, 'PBOC DEBIT'.codeUnits)),
  ])),
  _pair('80A8000002830000', _tlv(0x77, [
    ..._tlv(0x82, [0x7C, 0]),
    ..._tlv(0x9F36, [0, 0x4C]),
    ..._tlv(0x57, cpuHex('6212340000000001234D3012220' '00000000000')),
    ..._tlv(0x9F26, List.filled(8, 0)),
    ..._tlv(0x9F27, [0x80]),
    ..._tlv(0x5F20, List.filled(26, 0x20)),
  ])),
];

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets('RF status uses an actionable localized message', (tester) async {
    await tester.pumpWidget(_app(Builder(builder: (context) => Text(
      cpuCommandErrorText(AppLocalizations.of(context)!, CpuCommandError(6005, 1)),
    )), locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('未检测到卡片。请贴紧 Ultra 高频天线后重试。'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('0x1'), findsNothing);
  });

  test('PBOC format 2 summary masks PAN and recognizes GPO without AFL', () {
    final result = summarizeCpuEmv(_sample());
    expect(result.applicationLabel, 'PBOC DEBIT');
    expect(result.aid!.toUpperCase(), 'A000000333010101');
    expect(result.maskedPan, '621234 ${''.padLeft(9, '•')} 1234');
    expect(result.maskedPan, isNot(contains('6212340000000001234')));
    expect(result.expiry, '12/30');
    expect(result.cardholder, isNull);
    expect(result.transactionCounter, 76);
    expect(result.gpoReturnedData, isTrue);
    expect(result.hasAfl, isFalse);
    expect(result.hasCardError, isFalse);
    expect(result.hasMalformedData, isFalse);
    expect(result.steps.map((step) => step.kind), [
      CpuEmvStepKind.directory, CpuEmvStepKind.application, CpuEmvStepKind.processing,
    ]);
  });

  test('format 1 GPO includes AIP and AFL rather than a card number', () {
    final result = summarizeCpuEmv([
      _pair('80A8000002830000', cpuHex('80067C0008010100')),
    ]);
    expect(result.hasAfl, isTrue);
    expect(result.hasMalformedData, isFalse);
    expect(result.maskedPan, isNull);
  });

  test('status meanings do not claim the whole card rejects every read', () {
    expect(cpuStatusMeaning(0x6A86), CpuStatusMeaning.parameters);
    expect(cpuStatusMeaning(0x6D00), CpuStatusMeaning.instruction);
    expect(cpuStatusMeaning(0x9000), CpuStatusMeaning.success);
    final result = summarizeCpuEmv([
      CpuApduPair(cpuHex('00A40000023F00'), cpuHex('6A86')),
      CpuApduPair(cpuHex('00B0000010'), cpuHex('6D00')),
    ]);
    expect(result.hasCardError, isTrue);
    expect(result.applicationLabel, isNull);
    expect(result.maskedPan, isNull);
  });

  test('malformed response is isolated and previous selection remains usable', () {
    for (final malformed in [
      '7781', '7780', '77055A04AA', '9F81810100', '77059403080101',
    ]) {
      final result = summarizeCpuEmv([
        _sample()[1], _pair('80A8000002830000', cpuHex(malformed)),
      ]);
      expect(result.applicationLabel, 'PBOC DEBIT');
      expect(result.steps.last.malformedData, isTrue, reason: malformed);
      expect(result.maskedPan, isNull, reason: malformed);
    }
  });

  test('constructed TLV recursion and invalid dates are bounded', () {
    var nested = _tlv(0x5A, cpuHex('6212340000000123'));
    for (var n = 0; n < 10; n++) {
      nested = _tlv(0x77, nested);
    }
    expect(summarizeCpuEmv([_pair('80A8000002830000', nested)])
      .hasMalformedData, isTrue);
    final result = summarizeCpuEmv([
      _pair('80A8000002830000', _tlv(0x77, _tlv(0x5F24, cpuHex('301301')))),
    ]);
    expect(result.expiry, isNull);
  });

  testWidgets('summary is readable on a narrow handset without exposing raw PAN', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: CpuEmvSummaryPanel(summary: summarizeCpuEmv(_sample())),
    )));
    await tester.pumpAndSettle();
    expect(find.text('PBOC DEBIT'), findsOneWidget);
    expect(find.text('6212340000000001234'), findsNothing);
    expect(find.text('9000 · Success'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese summary wraps at increased text size', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
      child: SingleChildScrollView(padding: const EdgeInsets.all(12),
        child: CpuEmvSummaryPanel(summary: summarizeCpuEmv(_sample()))),
    ), locale: const Locale('zh')));
    await tester.pumpAndSettle();
    expect(find.text('应用名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read page starts with no editor or fabricated simulation profile', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesProvider();
    await prefs.load();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: ChameleonGUIState(prefs), child: _app(const CpuCardMenu()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Read'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('JSON'), findsNothing);
    await tester.tap(find.text('Emulate'));
    await tester.pumpAndSettle();
    expect(find.text('No emulation profile yet'), findsOneWidget);
    expect(find.text('CPU card'), findsNothing);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('JSON'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}