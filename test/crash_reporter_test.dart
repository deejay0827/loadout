// FILE: test/crash_reporter_test.dart
//
// Unit tests for `lib/services/crash_reporter.dart`. Covers the
// disabled-by-default no-op path (every public method should swallow
// silently when `initialize` hasn't been called or the platform
// doesn't support Crashlytics) so the rest of the app can call
// `setKey` / `log` / `recordError` without guarding every call site
// behind a "Crashlytics is wired" check.
//
// We don't exercise the actually-enabled path here — Firebase
// Crashlytics needs a real Firebase project initialised on the
// device, which `flutter_test` doesn't provide. The boundary widget
// test (`app_error_boundary_test.dart`) covers the in-tree
// integration end-to-end with the disabled path.

import 'package:flutter_test/flutter_test.dart';

import 'package:loadout/services/crash_reporter.dart';

void main() {
  group('CrashReporter (disabled path)', () {
    setUp(() {
      // Reset to the default disabled state before every test so
      // tests don't leak state through the singleton.
      CrashReporter.instance.debugSetEnabled(false);
    });

    test('isEnabled is false by default', () {
      expect(CrashReporter.instance.isEnabled, isFalse);
    });

    test('setKey is a no-op when disabled', () async {
      // Simply asserting we don't throw — there's nothing observable
      // when the call is no-op'd. The contract is "safe to call
      // anywhere", and that contract holds iff this completes
      // without exception.
      await CrashReporter.instance.setKey('test_key', 'test_value');
      await CrashReporter.instance.setKey('count', 42);
      await CrashReporter.instance.setKey('flag', true);
    });

    test('log is a no-op when disabled (only debug echo)', () {
      CrashReporter.instance.log('test breadcrumb');
      CrashReporter.instance.log('a second one');
      // No assertion; calling without exception is the contract.
    });

    test('recordError is a no-op when disabled', () async {
      await CrashReporter.instance.recordError(
        Exception('test error'),
        StackTrace.current,
        reason: 'unit test',
      );
      await CrashReporter.instance.recordError(
        StateError('another'),
        null,
        fatal: false,
      );
    });

    test('recordError with extras does not throw when disabled', () async {
      await CrashReporter.instance.recordError(
        Exception('with extras'),
        StackTrace.current,
        reason: 'extras path',
        extras: {
          'firearm_id': 42,
          'caliber': '.308 Win',
          'has_atmosphere': true,
        },
      );
    });

    test('isCrashlyticsSupportedPlatform returns a stable bool', () {
      // The host of `flutter test` is always macOS / Linux on the
      // engineer's box and CI, both of which are NOT supported.
      // Run from real iOS / Android device tests this would flip
      // to true. The test is mostly a smoke test that the helper
      // doesn't crash.
      final supported = isCrashlyticsSupportedPlatform();
      expect(supported, isA<bool>());
    });
  });

  group('CrashReporter (enabled flag toggle)', () {
    setUp(() {
      CrashReporter.instance.debugSetEnabled(false);
    });

    test('debugSetEnabled flips isEnabled', () {
      expect(CrashReporter.instance.isEnabled, isFalse);
      CrashReporter.instance.debugSetEnabled(true);
      expect(CrashReporter.instance.isEnabled, isTrue);
      CrashReporter.instance.debugSetEnabled(false);
      expect(CrashReporter.instance.isEnabled, isFalse);
    });

    // We don't run setKey / log / recordError on `enabled = true` in
    // unit tests because those would try to talk to a real Firebase
    // project. The integration is covered by the app_error_boundary
    // widget test, which keeps the reporter disabled and verifies
    // the boundary still catches + renders the fallback.
  });
}
