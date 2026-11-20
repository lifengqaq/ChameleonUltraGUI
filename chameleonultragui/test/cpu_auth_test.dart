import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/cpu_auth.dart';
import 'package:chameleonultragui/helpers/cpu_auth.dart';
import 'package:chameleonultragui/helpers/iso14443_4.dart';
import 'package:chameleonultragui/helpers/sm4.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);
Future<void> _open(
  WidgetTester tester,
  CpuAuthExchange exchange, {
  CpuAuthHistory? history,
}) async {
  await tester.binding.setSurfaceSize(const Size(500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showCpuAuthentication(
            context,
            exchange: exchange,
            history: history ?? CpuAuthHistory(),
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  test('only 63Cx failure responses supply remaining tries', () {
    for (var n = 0; n < 16; n++) expect(CpuAuthResult(0x63C0 | n).remaining, n);
    for (final status in [0x9000, 0x6300, 0x6982, 0x6A80, 0x6D00])
      expect(CpuAuthResult(status).remaining, isNull);
    expect(const CpuAuthResult(0x63C1, attempted: false).remaining, isNull);
    expect(const CpuAuthResult(0x6983, attempted: false).blocked, isTrue);
    expect(const CpuAuthResult(0x63C0).blocked, isTrue);
  });
  test('PIN encodings and DES/3DES known-answer vectors', () {
    expect(cpuVerifyData('000000', CpuPinEncoding.ascii), [
      48,
      48,
      48,
      48,
      48,
      48,
    ]);
    expect(
      cpuVerifyData('000000', CpuPinEncoding.bcd),
      cpuHex('000000FFFFFFFFFF'),
    );
    expect(
      cpuVerifyData('000000', CpuPinEncoding.iso9564),
      cpuHex('26000000FFFFFFFF'),
    );
    expect(
      cpuEncryptChallenge(
        cpuHex('133457799BBCDFF1'),
        cpuHex('0123456789ABCDEF'),
      ),
      cpuHex('85E813540F0AB405'),
    );
    expect(
      cpuEncryptChallenge(
        cpuHex('0123456789ABCDEFFEDCBA9876543210'),
        cpuHex('0000000000000000'),
      ),
      cpuHex('08D7B4FB629D0885'),
    );
    for (final pin in ['', '123', '0000000000000', 'ABCDEF']) {
      expect(
        () => cpuVerifyData(pin, CpuPinEncoding.ascii),
        throwsFormatException,
      );
    }
  });
  test(
    'PIN authentication sends exactly one supplied VERIFY and no counter query',
    () async {
      final commands = <Uint8List>[];
      final result = await authenticateCpuCard(
        const CpuAuthSettings(),
        '000000',
        (command) async {
          commands.add(command);
          return cpuHex('63C1');
        },
      );
      expect(commands, [cpuHex('0020000006303030303030')]);
      expect(result.remaining, 1);
    },
  );
  test('DES challenge response never transmits a cleartext key', () async {
    final commands = <Uint8List>[];
    final result = await authenticateCpuCard(
      const CpuAuthSettings(method: CpuAuthMethod.des),
      '133457799BBCDFF1',
      (command) async {
        commands.add(command);
        return commands.length == 1
            ? cpuHex('0123456789ABCDEF9000')
            : cpuHex('9000');
      },
    );
    expect(commands, [
      cpuHex('0084000008'),
      cpuHex('008200000885E813540F0AB405'),
    ]);
    expect(result.success, isTrue);
  });
  test(
    'SM4 builds one 16-byte authentication proof for each challenge format',
    () async {
      const key = '0123456789ABCDEFFEDCBA9876543210';
      for (final (format, request, challenge, proof) in [
        (
          CpuSm4Challenge.padded8,
          '0084000008',
          '0123456789ABCDEF9000',
          '0082098010D880B137D5D027CB471F725816B62E07',
        ),
        (
          CpuSm4Challenge.raw16,
          '0084000010',
          '${key}9000',
          '0082098010681EDF34D206965E86B3E94F536E4246',
        ),
      ]) {
        final commands = <Uint8List>[];
        final result = await authenticateCpuCard(
          CpuAuthSettings(
            method: CpuAuthMethod.sm4,
            sm4Challenge: format,
            reference: 0x80,
            algorithm: 0x09,
          ),
          key,
          (command) async {
            commands.add(command);
            return cpuHex(commands.length == 1 ? challenge : '63C1');
          },
        );
        expect(commands, [cpuHex(request), cpuHex(proof)]);
        expect(result.remaining, 1);
      }
    },
  );
  test(
    'SM4 refuses a wrong key length or challenge without sending a proof',
    () async {
      const settings = CpuAuthSettings(
        method: CpuAuthMethod.sm4,
        sm4Challenge: CpuSm4Challenge.raw16,
      );
      final commands = <Uint8List>[];
      Future<Uint8List> exchange(Uint8List command) async {
        commands.add(command);
        return cpuHex('0123456789ABCDEF9000');
      }

      for (final key in [
        '0011223344556677',
        '00112233445566778899AABBCCDDEEFF0011223344556677',
      ]) {
        await expectLater(
          authenticateCpuCard(settings, key, exchange),
          throwsFormatException,
        );
      }
      expect(commands, isEmpty);
      await expectLater(
        authenticateCpuCard(
          settings,
          '0123456789ABCDEFFEDCBA9876543210',
          exchange,
        ),
        throwsFormatException,
      );
      expect(commands, [cpuHex('0084000010')]);
    },
  );
  test(
    'invalid credentials and failed challenges do not submit authentication',
    () async {
      var calls = 0;
      await expectLater(
        authenticateCpuCard(const CpuAuthSettings(), 'xx', (command) async {
          calls++;
          return cpuHex('9000');
        }),
        throwsFormatException,
      );
      expect(calls, 0);
      final result = await authenticateCpuCard(
        const CpuAuthSettings(method: CpuAuthMethod.des),
        'FFFFFFFFFFFFFFFF',
        (command) async {
          calls++;
          return cpuHex('6D00');
        },
      );
      expect(calls, 1);
      expect(result.attempted, isFalse);
    },
  );
  test(
    'counter histories distinguish PIN/key and reference and survive reopening',
    () {
      final history = cpuAuthHistoryForCard([1, 2, 3, 4], [2, 8]);
      const pin = CpuAuthSettings(),
          key = CpuAuthSettings(method: CpuAuthMethod.des),
          other = CpuAuthSettings(reference: 1);
      history.record(pin, const CpuAuthResult(0x63C1));
      expect(history.forSettings(pin)!.remaining, 1);
      expect(history.forSettings(key), isNull);
      expect(history.forSettings(other), isNull);
      expect(
        cpuAuthHistoryForCard([1, 2, 3, 4], [2, 8]).forSettings(pin)!.remaining,
        1,
      );
      history.record(pin, const CpuAuthResult(0x6300));
      expect(history.forSettings(pin)!.remaining, isNull);
      history.clear();
    },
  );
  testWidgets(
    'defaults never authenticate; one remaining is red and requires confirmation',
    (tester) async {
      var calls = 0;
      await _open(tester, (command) async {
        calls++;
        return cpuHex(calls == 1 ? '63C1' : '63C0');
      });
      final credential = tester.widget<TextField>(
        find.byKey(const PageStorageKey('cpu-auth-credential')),
      );
      expect(credential.controller!.text, '000000');
      expect(calls, 0);
      expect(find.byKey(const ValueKey('cpu-auth-remaining')), findsNothing);
      final submit = find.byKey(const ValueKey('cpu-auth-submit'));
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(calls, 1);
      final counter = tester.widget<Text>(
        find.byKey(const ValueKey('cpu-auth-remaining')),
      );
      expect(counter.data, contains('1'));
      expect(
        counter.style!.color,
        Theme.of(tester.element(submit)).colorScheme.error,
      );
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Last authentication attempt'), findsOneWidget);
      expect(calls, 1);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cpu-auth-last-confirm')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unrecognized failure counters stay unknown', (tester) async {
    var calls = 0;
    await _open(tester, (command) async {
      calls++;
      return cpuHex('6300');
    });
    await tester.tap(find.byKey(const ValueKey('cpu-auth-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Remaining attempts unknown'), findsOneWidget);
    expect(find.text('Last authentication attempt'), findsNothing);
    expect(calls, 1);
  });
  testWidgets(
    'a transport timeout disables resubmission instead of guessing retry count',
    (tester) async {
      var calls = 0;
      await _open(tester, (command) async {
        calls++;
        throw TimeoutException('test timeout');
      });
      final submit = find.byKey(const ValueKey('cpu-auth-submit'));
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      expect(find.textContaining('Communication ended'), findsOneWidget);
    },
  );
  testWidgets(
    'DES selection prefills exactly sixteen hex F characters without sending',
    (tester) async {
      var calls = 0;
      await _open(tester, (command) async {
        calls++;
        return cpuHex('9000');
      });
      final method = find.byWidgetPredicate(
        (w) => w is DropdownButtonFormField<CpuAuthMethod>,
      );
      await tester.tap(method);
      await tester.pumpAndSettle();
      await tester.tap(find.text('DES external authentication (8 bytes)').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const PageStorageKey('cpu-auth-credential')),
            )
            .controller!
            .text,
        'FFFFFFFFFFFFFFFF',
      );
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
