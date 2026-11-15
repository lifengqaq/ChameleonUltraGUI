import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_card.dart';
import 'package:chameleonultragui/gui/menu/pages/cpu_data_editor.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_emv_summary.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_filesystem.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/iso7816_fs.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Finder _scrollable(Finder parent) => find.descendant(
  of: parent, matching: find.byType(Scrollable),
).first;

void main() {
  testWidgets('radio expansion and scroll restore independently after rereading', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bucket = PageStorageBucket();
    const scrollKey = PageStorageKey('read-page-scroll');
    var visible = true;
    var identity = CardData(uid: cpuHex('CB2E2033'), atqa: cpuHex('0400'),
      sak: 0x20, ats: cpuHex('0D7880A002808660907319A500'));
    late StateSetter update;
    await tester.pumpWidget(_app(PageStorage(bucket: bucket,
      child: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return visible ? ListView(key: scrollKey, children: [
          CpuIdentityPanel(identity: identity),
          const SizedBox(height: 1200),
        ]) : const SizedBox.shrink();
      }),
    )));
    await tester.pumpAndSettle();
    final radioTitle = find.text(AppLocalizations.of(
      tester.element(find.byType(CpuIdentityPanel)))!.cpu_radio_details);
    await tester.tap(radioTitle);
    await tester.pumpAndSettle();
    expect(find.text('ATQA'), findsOneWidget);
    await tester.drag(find.byKey(scrollKey), const Offset(0, -120));
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(_scrollable(find.byKey(scrollKey))).position.pixels;
    expect(offset, greaterThan(0));
    expect(tester.takeException(), isNull);
    update(() => visible = false);
    await tester.pumpAndSettle();
    update(() {
      identity = CardData(uid: cpuHex('07589D5E'), atqa: cpuHex('0400'),
        sak: 0x20, ats: cpuHex('0D7880A002808660907319A500'));
      visible = true;
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('ATQA'), findsOneWidget);
    expect(find.text('07 58 9D 5E'), findsOneWidget);
    expect(tester.state<ScrollableState>(_scrollable(find.byKey(scrollKey))).position.pixels,
      closeTo(offset, 1));
    await tester.binding.setSurfaceSize(const Size(844, 390));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('native JSON expansion and editor scroll survive page reentry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPreferencesProvider();
    await prefs.load();
    final app = ChameleonGUIState(prefs);
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bucket = PageStorageBucket();
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(ChangeNotifierProvider.value(value: app,
      child: _app(PageStorage(bucket: bucket, child: StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return visible ? CpuDataEditor(card: CardSave(uid: '01020304', name: 'CPU data', tag: TagType.hf14a4, data: [CpuFileSystem.example().encode()]), onSave: (_) {}) : const SizedBox.shrink();
        },
      ))),
    ));
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(CpuDataEditor)))!;
    final list = find.byKey(const PageStorageKey('cpu-native-data-scroll'));
    final scrollable = _scrollable(list);
    for (final title in [l.cpu_profile_json]) {
      await tester.scrollUntilVisible(find.text(title), 160, scrollable: scrollable);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(find.text(title)), alignment: 0.4);
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    final editor = find.byKey(const PageStorageKey('cpu-native-json-scroll'));
    await tester.ensureVisible(editor);
    await tester.enterText(editor, List.filled(40, '{"test": true}').join('\n'));
    await tester.pumpAndSettle();
    await tester.drag(editor, const Offset(0, -100));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    update(() => visible = false);
    await tester.pumpAndSettle();
    update(() => visible = true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text(l.cpu_profile_json), 160,
      scrollable: _scrollable(list));
    expect(editor, findsOneWidget);
    expect(find.text(l.cpu_data_json_help), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FCI expansion can reopen after scrolling its multiline editor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(SingleChildScrollView(
      child: CpuFilesystemEditor(filesystem: CpuFileSystem.example(), onChanged: (_) {}),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3F00 · DF'));
    await tester.pumpAndSettle();
    final expansion = find.byKey(const PageStorageKey('cpu-fci-expanded'));
    await tester.ensureVisible(expansion);
    await tester.tap(find.descendant(of: expansion, matching: find.byType(ListTile)).first);
    await tester.pumpAndSettle();
    final editor = find.byKey(const PageStorageKey('cpu-fci-editor-scroll'));
    await tester.ensureVisible(editor);
    await tester.enterText(editor, List.filled(20, '6F 00').join('\n'));
    await tester.pumpAndSettle();
    await tester.drag(editor, const Offset(0, -100));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final title = find.descendant(of: expansion, matching: find.byType(ListTile)).first;
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(editor, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}