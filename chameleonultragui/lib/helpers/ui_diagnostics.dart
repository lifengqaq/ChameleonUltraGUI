import 'dart:ui' show PlatformDispatcher;
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/foundation.dart';

/// Retain framework failures in the existing local Debug log in release builds.
/// The original handlers remain responsible for normal error presentation.
void installUiDiagnostics(SharedPreferencesProvider preferences) {
  var count = 0;
  void record(String kind, Object error, StackTrace? stack) {
    if (count >= 24) return;
    count++;
    final entry = '${DateTime.now().toIso8601String()} $kind\n$error\n${stack ?? ''}';
    try { preferences.addLogLine(entry.length > 10000 ? entry.substring(0,10000) : entry); }
    catch (_) { /* Logging must not trigger another framework error. */ }
  }
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    record('FLUTTER_UI', details.exception, details.stack);
    previousFlutter?.call(details);
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error,stack) {
    record('FLUTTER_ASYNC', error, stack);
    return previousPlatform?.call(error,stack) ?? false;
  };
}