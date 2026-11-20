import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/tools/cpu_card_manager.dart';
import 'package:chameleonultragui/helpers/cpu_live_archive.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart' show bytesToHexSpace;
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Connection extends AbstractSerial {
  _Connection() : super(log: Logger()) {
    connected = true;
    device = ChameleonDevice.ultra;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _directoryFci = '6F15840E315041592E5359532E4444463031A5038801019000';
const _directoryRecord = '701361114F09A00000000386980791509450BA4FBB';

class _Card extends ChameleonCommunicator {
  _Card([List<(String, String)>? operations])
    : script =
          operations ??
          [
            ..._pseScan,
            ('00B2010C00', '${_directoryRecord}9000'),
            (
              '00A4040009A0000000038698079100',
              '6F0B8409A000000003869807919000',
            ),
          ],
      super(Logger());

  static const _pseScan = <(String, String)>[
    ('00A40000023F0000', _directoryFci),
    ('00B2010C00', '${_directoryRecord}9000'),
    ('00B2020C00', '6A83'),
    ('00A404000E325041592E5359532E444446303100', '6A82'),
    ('00A4040007D276000085010100', '6A82'),
    ('00A40000023F0000', _directoryFci),
  ];
  static const _emptyPseScan = <(String, String)>[
    ('00A40000023F0000', _directoryFci),
    ('00B2010C00', '6A82'),
    ('00A404000E325041592E5359532E444446303100', '6A82'),
    ('00A4040007D276000085010100', '6A82'),
    ('00A40000023F0000', _directoryFci),
  ];
  final List<(String, String)> script;
  int exchanges = 0;

  @override
  Future<List<int>> getDeviceCapabilities() async => [6011];

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<(CardData, Uint8List)> hf14a4OpenManagedSession() async => (
    CardData(
      uid: cpuHex('01020304'),
      atqa: cpuHex('0004'),
      sak: 0x20,
      ats: cpuHex('0208'),
    ),
    cpuHex('00000001'),
  );

  @override
  Future<void> hf14a4CloseManagedSession(Uint8List id) async {}

  @override
  Future<Uint8List> hf14a4ManagedApdu(Uint8List id, Uint8List apdu) async {
    expect(exchanges, lessThan(script.length), reason: 'Unexpected APDU');
    final (command, reply) = script[exchanges++];
    expect(apdu, cpuHex(command));
    return cpuHex(reply);
  }
}

Future<AppLocalizations> _openExplorer(WidgetTester tester, _Card card) async {
  await tester.binding.setSurfaceSize(const Size(1180, 690));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final app = ChameleonGUIState(SharedPreferencesProvider())
    ..communicator = card
    ..connector = _Connection();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CpuCardManager(),
      ),
    ),
  );
  final l = AppLocalizations.of(tester.element(find.byType(CpuCardManager)))!;
  await tester.tap(find.text(l.cpu_manage_connect));
  await tester.pumpAndSettle();
  return l;
}

void main() {
  testWidgets('creates the first DF under a verified MF with a PSE name', (
    tester,
  ) async {
    const actualMf =
        '6F1A840E315041592E5359532E4444463031620883023F00820238219000';
    final card = _Card([
      ..._Card._emptyPseScan,
      ('00A40000023F0000', _directoryFci),
      ('00A40004023F0000', _directoryFci),
      ('00A40004023F00', '6A86'),
      ('00A4000000', actualMf),
      ('00E000000A62088202382183021100', '9000'),
    ]);
    final l = await _openExplorer(tester, card);
    final ok = find.widgetWithText(FilledButton, l.ok);
    await tester.tap(
      find.widgetWithText(OutlinedButton, l.cpu_manage_new_directory),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
      '3F00',
    );
    await tester.tap(ok);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '1100');
    await tester.tap(ok);
    await tester.pumpAndSettle();
    expect(card.exchanges, card.script.length - 1);
    await tester.tap(ok);
    await tester.pumpAndSettle();
    expect(find.text('FID 1100'), findsOneWidget);
    expect(card.exchanges, card.script.length);
  });

  testWidgets('explains an unverified MF and never creates in the PSE', (
    tester,
  ) async {
    const otherFci = '6F15840E315041592E5359532E4444463031A5038801029000';
    final card = _Card([
      ..._Card._emptyPseScan,
      ('00A40000023F0000', otherFci),
      ('00A40004023F0000', '9000'),
      ('00A40004023F00', '6A86'),
      ('00A4000000', otherFci),
    ]);
    final l = await _openExplorer(tester, card);
    await tester.tap(
      find.widgetWithText(OutlinedButton, l.cpu_manage_new_directory),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, l.ok));
    await tester.pumpAndSettle();
    expect(find.text(l.cpu_manage_master_unverified), findsOneWidget);
    expect(
      find.text(l.cpu_manage_master_alias('1PAY.SYS.DDF01')),
      findsOneWidget,
    );
    expect(find.text(l.cpu_manage_master_need_parent), findsOneWidget);
    expect(find.text(l.cpu_manage_fmcos_open), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(card.exchanges, card.script.length);
  });

  testWidgets(
    'authenticates in the same FMCOS MF only after the confirmed create is rejected',
    (tester) async {
      final card = _Card([
        ..._Card._emptyPseScan,
        ('00A40000023F0000', _directoryFci),
        ('00A40004023F0000', '6A86'),
        ('00A40004023F00', '6A86'),
        ('00A4000000', _directoryFci),
        ('00A40000023F00', _directoryFci),
        ('80E011000D380200F0F195FFFF5445535431', '6982'),
        ('0084000004', 'BB83BFF39000'),
        ('008200010874B0047DD681D96C', '9000'),
        ('80E011000D380200F0F195FFFF5445535431', '9000'),
        ('00A40000023F00', _directoryFci),
        ('00A40000021100', '6F0984055445535431A5009000'),
      ]);
      final l = await _openExplorer(tester, card);
      final ok = find.widgetWithText(FilledButton, l.ok);
      await tester.tap(find.byTooltip(l.cpu_tree_root));
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_master_unverified), findsOneWidget);
      await tester.tap(
        find.widgetWithText(OutlinedButton, l.cpu_manage_fmcos_open),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_fmcos_selected), findsOneWidget);
      final afterSelect = card.exchanges;
      await tester.tap(
        find.widgetWithText(OutlinedButton, l.cpu_manage_new_directory),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(l.cpu_manage_fmcos_create),
        ),
        findsOneWidget,
      );
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(card.exchanges, afterSelect);
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_auth_fmcos_help), findsOneWidget);
      expect(card.exchanges, afterSelect + 1);
      final id = find.byKey(const PageStorageKey('cpu-auth-reference'));
      final key = find.byKey(const PageStorageKey('cpu-auth-credential'));
      expect(tester.widget<TextField>(id).controller!.text, isEmpty);
      expect(tester.widget<TextField>(key).controller!.text, isEmpty);
      await tester.enterText(id, '01');
      // Public test vector from the FMCOS 2.0 manual, not a card credential.
      await tester.enterText(key, '0102030405060708');
      await tester.tap(find.byKey(const ValueKey('cpu-auth-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FID 1100'));
      await tester.pumpAndSettle();
      expect(card.exchanges, card.script.length);
      expect(find.text('3F00/1100 · AID 54 45 53 54 31'), findsOneWidget);
    },
  );

  testWidgets(
    'queries City Union balance separately and displays a real zero',
    (tester) async {
      final card = _Card([
        ..._Card._pseScan,
        ('00A4040009A0000000038698070100', '6F0B8409A000000003869807019000'),
        ('805C000204', '000000009000'),
        ('805C000204', '000030399000'),
        ('805C000204', '6A81'),
        ('805C000204', '0000009000'),
        (
          '00B0950000',
          '0000200000000000000100000000000000000000202411202034112000009000',
        ),
        ('00A4040009A0000000038698079100', '6F0B8409A000000003869807919000'),
      ]);
      final l = await _openExplorer(tester, card);
      await tester.tap(find.byTooltip(l.cpu_tree_manual));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.cpu_manage_select_aid));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'A00000000386980701');
      await tester.tap(find.widgetWithText(FilledButton, l.ok));
      await tester.pumpAndSettle();
      expect(card.exchanges, _Card._pseScan.length + 1);
      expect(find.text(l.cpu_manage_purse_amount('0.00')), findsNothing);
      final refresh = find.byTooltip(l.cpu_manage_purse_refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_purse_amount('0.00')), findsOneWidget);

      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_purse_amount('123.45')), findsOneWidget);

      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.textContaining('SW 6A81'), findsOneWidget);
      expect(find.text(l.cpu_manage_purse_amount('0.00')), findsNothing);
      expect(find.text(l.cpu_manage_purse_amount('123.45')), findsNothing);

      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_purse_bad_response), findsOneWidget);

      await tester.tap(find.text(l.cpu_transit_read_info));
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_transit_info), findsOneWidget);
      expect(find.text('2024-11-20'), findsOneWidget);
      expect(find.text('2034-11-20'), findsOneWidget);

      await tester.tap(find.text('AID A00000000386980791'));
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_purse_balance), findsNothing);
      expect(card.exchanges, card.script.length);
    },
  );

  testWidgets(
    'reads a passbook from the PSE parent of a catalog record without selecting MF',
    (tester) async {
      const mfFcp = '62088202382183023F009000';
      const pse = '00A404000E315041592E5359532E444446303100';
      final card = _Card([
        ('00A40000023F0000', mfFcp),
        ('00A40200022F0000', '6A82'),
        (pse, _directoryFci),
        ('00B2010C00', '${_directoryRecord}9000'),
        ('00B2020C00', '6A83'),
        ('00A404000E325041592E5359532E444446303100', '6A82'),
        ('00A4040007D276000085010100', '6A82'),
        ('00A40000023F0000', mfFcp),
        (pse, _directoryFci),
        ('00B2010C00', '${_directoryRecord}9000'),
        ('805C000104', '6982'),
        ('0020000203123456', '9000'),
        ('805C000104', '000030399000'),
        ('00A40000023F0000', mfFcp),
      ]);
      final l = await _openExplorer(tester, card);
      await tester.tap(find.text(l.cpu_tree_record_file));
      await tester.pumpAndSettle();
      expect(card.exchanges, 10);
      await tester.tap(
        find.widgetWithText(OutlinedButton, l.cpu_manage_balance_action),
      );
      await tester.pumpAndSettle();
      final scope = l.cpu_manage_balance_scope(
        'PSE · AID 315041592E5359532E4444463031',
      );
      expect(find.text(scope), findsOneWidget);
      await tester.tap(
        find.widgetWithText(OutlinedButton, l.cpu_manage_balance_passbook),
      );
      await tester.pumpAndSettle();
      expect(card.exchanges, 11);
      expect(find.text(l.cpu_auth_fmcos_pin), findsOneWidget);
      await tester.enterText(
        find.byKey(const PageStorageKey('cpu-auth-reference')),
        '02',
      );
      await tester.enterText(
        find.byKey(const PageStorageKey('cpu-auth-credential')),
        '123456',
      );
      await tester.tap(find.byKey(const ValueKey('cpu-auth-submit')));
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_balance_minor(12345)), findsOneWidget);
      expect(find.text(scope), findsOneWidget);
      await tester.tap(find.text('MF'));
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_manage_balance_minor(12345)), findsNothing);
      expect(card.exchanges, card.script.length);
    },
  );

  testWidgets(
    'saves the discovered directory and raw records after RF is closed',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = SharedPreferencesProvider();
      await prefs.load();
      final card = _Card(_Card._pseScan);
      final l = await _openExplorer(tester, card);
      await tester.tap(find.text(l.cpu_disconnect));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.cpu_archive_save));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.cpu_archive_to_library));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, l.save));
      await tester.pumpAndSettle();

      final stored = prefs.getCards().single;
      expect(stored.data, isEmpty);
      final archive = stored.extraData.cpuDump;
      expect(archive['format'], cpuLiveArchiveFormat);
      expect(archive['archiveOnly'], isTrue);
      expect(archive['universalComplete'], isFalse);
      final entries = (archive['entries'] as List).cast<Map>();
      final catalog = entries.singleWhere((entry) => entry['sfi'] == 1);
      expect(catalog['readRanges'], [
        {'record': 1, 'status': '9000', 'data': _directoryRecord},
      ]);
      final app = entries.singleWhere(
        (entry) => entry['aid'] == 'A00000000386980791',
      );
      expect(app['readRanges'], isEmpty);
      expect(card.exchanges, _Card._pseScan.length);
    },
  );

  testWidgets(
    'context gestures only open the menu; file selection previews its malformed record',
    (tester) async {
      final card = _Card();
      final l = await _openExplorer(tester, card);
      expect(card.exchanges, 6);
      final file = find.text(l.cpu_tree_record_file);
      final menu = find.text(l.cpu_tree_open_entry);

      await tester.tap(
        file,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      expect(card.exchanges, 6);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(menu, findsNothing);

      final press = await tester.startGesture(tester.getCenter(file));
      await tester.pump(const Duration(milliseconds: 650));
      expect(menu, findsNothing);
      await press.up();
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      expect(card.exchanges, 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(file);
      await tester.pumpAndSettle();
      expect(card.exchanges, 7);
      expect(find.text(l.cpu_tree_record_title(1)), findsOneWidget);
      expect(
        find.text(l.cpu_tree_record_length_error('50', 15, 20, 4)),
        findsOneWidget,
      );
      expect(
        find.text(bytesToHexSpace(cpuHex(_directoryRecord))),
        findsOneWidget,
      );
      final read = find.widgetWithText(
        OutlinedButton,
        l.cpu_manage_read_record,
      );
      expect(read, findsOneWidget);
      expect(
        tester.getTopLeft(read).dx,
        greaterThan(tester.getTopLeft(file).dx),
      );
      expect(
        tester.getTopLeft(read).dy,
        greaterThan(
          tester.getTopLeft(find.text(l.cpu_tree_record_title(1))).dy,
        ),
      );

      await tester.tap(find.text('AID A00000000386980791'));
      await tester.pumpAndSettle();
      expect(card.exchanges, card.script.length);
      expect(read, findsNothing);
      expect(
        find.widgetWithText(OutlinedButton, l.cpu_manage_open_ef),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing directory entry can be replaced by a known path for creating and writing',
    (tester) async {
      final card = _Card([
        ..._Card._pseScan,
        ('00A4040009A0000000038698079100', '6A82'),
        ('00A4040009A00000000386980791', '6A82'),
        ('00A4040409A0000000038698079100', '6A86'),
        ('00A4040C09A00000000386980791', '6A82'),
        ('00A4080402100100', '620882023821830210019000'),
        ('00E000000A62088202382183021100', '9000'),
        ('00A40804041001100200', '620C8202012183021002800200209000'),
        ('00D6000002AA55', '9000'),
      ]);
      final l = await _openExplorer(tester, card);
      final ok = find.widgetWithText(FilledButton, l.ok);
      await tester.tap(find.text('AID A00000000386980791'));
      await tester.pumpAndSettle();
      expect(find.textContaining(l.cpu_tree_missing_aid), findsOneWidget);
      await tester.tap(find.text(l.cpu_manage_open_known_fid));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '1001');
      await tester.tap(ok);
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(OutlinedButton, l.cpu_manage_new_directory),
      );
      await tester.pumpAndSettle();
      expect(find.text(l.cpu_files_add_df), findsWidgets);
      await tester.enterText(find.byType(TextFormField).first, '1100');
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(card.exchanges, 11, reason: 'No write before confirmation');
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(find.text('FID 1100'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(OutlinedButton, l.cpu_manage_write_file),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '3F00/1001/1002');
      await tester.tap(ok);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, 'AA 55');
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(
        card.exchanges,
        13,
        reason: 'Selecting and editing the data must not write it',
      );
      await tester.tap(ok);
      await tester.pumpAndSettle();
      expect(card.exchanges, card.script.length);
      expect(find.textContaining('SW 9000'), findsOneWidget);
    },
  );
}
