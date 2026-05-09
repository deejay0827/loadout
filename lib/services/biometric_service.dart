// FILE: lib/services/biometric_service.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Wraps the platform's local biometric authentication (Face ID / Touch
// ID on iOS, fingerprint on Android, Windows Hello on desktop) and
// surfaces it to the LoadOut UI as a small reactive service.
//
// Biometric in LoadOut is a **local unlock gate**, not a sign-in
// method. Firebase Auth already keeps the user signed in across app
// launches via a refresh token cached in the platform's secure
// storage; once a user successfully signs in with email/password,
// Google, Apple, Microsoft, Yahoo, anonymous, or an email link,
// Firebase replays that session on every subsequent launch. Enabling
// biometric simply layers a "you must prove this is you" prompt
// between the Firebase-cached session and the HomeScreen.
//
// This means:
//   * Biometric is ALWAYS connected to whichever Firebase account the
//     user last signed in with — no separate enrolment, no password
//     re-entry. The same Face ID that unlocks the user's iPhone is
//     enough to unlock LoadOut against their existing account.
//   * Biometric never reads, stores, or transmits any account
//     credential. The unlock decision is purely "is the OS happy
//     this is the device's primary user?"; on success we flip a
//     single in-memory bit and let the rest of the app proceed.
//   * Disabling biometric is non-destructive: the user still has
//     their Firebase session, they just stop seeing the unlock prompt.
//
// Public API:
//   * `bool get isAvailable` — true once `_probe()` has confirmed the
//     OS exposes biometric AND the user has at least one biometric
//     enrolled.
//   * `bool get isEnabled` — has the user opted into "use biometric
//     to unlock LoadOut?" Persisted via SharedPreferences.
//   * `bool get isUnlocked` — transient; true once biometric has
//     succeeded this app session, OR true permanently when [isEnabled]
//     is false (no gate to clear).
//   * `Future<void> setEnabled(bool)` — flip the persisted preference.
//     Enabling immediately requires a biometric pass to confirm the
//     user actually has biometric working; we don't trust a "yes"
//     toggle without a follow-up auth.
//   * `Future<bool> authenticate({required String reason})` — one-
//     shot prompt; returns true on success, false on cancellation /
//     failure / timeout. On success, flips [isUnlocked] to true and
//     notifies listeners.
//   * `void lock()` — testing / sign-out hook to re-arm the gate.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// `_AuthGate` in `lib/app.dart` watches the Firebase auth stream and
// chooses between [LoginScreen] and [HomeScreen]. Biometric inserts
// a third state — "user is signed in but the app is locked behind
// biometric" — which the gate renders as a [BiometricLockScreen]
// instead of [HomeScreen] when this service reports `isEnabled &&
// !isUnlocked`.
//
// Splitting biometric into its own service (rather than wiring it
// directly into `_AuthGate`) keeps the gate's logic small and lets
// the Settings → Account screen and any future "lock on background"
// feature share the same source of truth.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * **Availability is a two-condition check.** `local_auth` can
//     report "device supports biometric" while the user has never
//     enrolled a face or fingerprint. Both conditions must be true
//     for the toggle to be functional, so [_probe] reads
//     `isDeviceSupported` AND `getAvailableBiometrics().isNotEmpty`
//     before declaring availability.
//   * **The OS prompt is asynchronous AND user-cancellable.** Every
//     entry point that triggers `authenticate(...)` has to handle a
//     `false` return cleanly — either re-prompt, fall through to
//     sign-out, or leave the lock screen up. We never auto-retry on
//     failure; the user explicitly drives the next step.
//   * **`stickyAuth: true` matters.** Without it, the OS dismisses
//     the prompt the moment the app backgrounds (e.g., if the user
//     pulls down notification center). Sticky-auth keeps the prompt
//     alive across brief OS interruptions, which matches the
//     "unlock once per session" semantics.
//   * **Enable-with-confirm.** Toggling the preference to ON without
//     immediately running an auth would let a user enable a feature
//     they can't actually use (e.g., they tapped Yes on the OS
//     enrolment dialog but didn't finish). [setEnabled] runs an
//     auth as part of the enable path so we know the gate works
//     before we start enforcing it.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/app.dart — provides the singleton; `_AuthGate` reads
//   `isEnabled && !isUnlocked` to decide whether to render the
//   biometric unlock screen.
// - lib/screens/settings/account_settings_screen.dart — exposes
//   the toggle and triggers [setEnabled].
// - lib/screens/auth/biometric_lock_screen.dart — the gate UI;
//   calls [authenticate] and [lock].
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads / writes `SharedPreferences` under
//   `biometric_unlock_enabled`.
// - Triggers the platform biometric dialog on every
//   [authenticate] call (Face ID / Touch ID / fingerprint sheet,
//   on whichever platform).

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kEnabledKey = 'biometric_unlock_enabled';

/// Reactive wrapper around `local_auth`. See file header for the full
/// contract and the relationship between this service, Firebase Auth,
/// and the `_AuthGate` in `lib/app.dart`.
class BiometricService extends ChangeNotifier {
  BiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication() {
    // ignore: discarded_futures
    _hydrate();
  }

  final LocalAuthentication _auth;

  bool _isAvailable = false;
  bool _isEnabled = false;
  bool _isUnlocked = true;
  bool _hydrated = false;

  /// Does the OS support biometric AND has the user enrolled at
  /// least one biometric? Both conditions must be true for the
  /// Settings toggle to be functional. Re-probed on every
  /// [_hydrate] call (typically once per process).
  bool get isAvailable => _isAvailable;

  /// Has the user opted into "use biometric to unlock LoadOut?"
  /// Persisted under [_kEnabledKey]. Defaults to false on fresh
  /// installs (opt-in, never opt-out).
  bool get isEnabled => _isEnabled;

  /// Transient unlock flag. Starts false when [isEnabled] is true
  /// (gate is closed at launch, demands biometric); always true
  /// when [isEnabled] is false (no gate to enforce). Set to true
  /// inside [authenticate] on success, reset to false by [lock].
  bool get isUnlocked => _isUnlocked;

  /// True once [_hydrate] finished its SharedPreferences read AND
  /// `local_auth` probe. UI that depends on [isAvailable] should
  /// gate on this so it doesn't flash a "biometric not supported"
  /// message before the probe completes.
  bool get isHydrated => _hydrated;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_kEnabledKey) ?? false;
    _isAvailable = await _probe();
    // Initial unlocked state mirrors the gate logic: locked iff the
    // user has enabled biometric AND it's actually available right
    // now. If they enabled it on a previous device but uninstalled
    // their Face ID, the gate auto-skips so they're not stranded.
    _isUnlocked = !(_isEnabled && _isAvailable);
    _hydrated = true;
    notifyListeners();
  }

  /// Probe the platform for biometric support. Two conditions, both
  /// required: `isDeviceSupported` (OS has biometric APIs) AND
  /// `getAvailableBiometrics()` returns at least one enrolled
  /// biometric. Soft-fails on any platform-channel exception so an
  /// unexpected failure can't block app launch.
  Future<bool> _probe() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final biometrics = await _auth.getAvailableBiometrics();
      return biometrics.isNotEmpty;
    } catch (e) {
      debugPrint('[biometric] probe failed: $e');
      return false;
    }
  }

  /// Run the platform biometric prompt. Returns true on success,
  /// false on cancel / failure / unavailable. On success, flips
  /// [isUnlocked] to true and notifies listeners.
  Future<bool> authenticate({required String reason}) async {
    if (!_isAvailable) return false;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // Sticky — the prompt survives brief OS interruptions
          // (notification shade, control center). Without sticky,
          // the user'd have to re-trigger the gate after every
          // accidental background.
          stickyAuth: true,
          // We're authenticating against the device's primary user;
          // letting the user fall back to PIN keeps people who've
          // disabled biometric (but kept the device passcode)
          // working. Set false to force biometric only.
          biometricOnly: false,
        ),
      );
      if (ok) {
        _isUnlocked = true;
        notifyListeners();
      }
      return ok;
    } catch (e) {
      debugPrint('[biometric] authenticate failed: $e');
      return false;
    }
  }

  /// Flip the persisted preference. Enabling triggers an immediate
  /// [authenticate] check so we never enable a feature the user
  /// can't actually use — if biometric fails during the confirm
  /// step, the toggle stays off and listeners see [isEnabled] ==
  /// false. Disabling is unconditional (no auth required to turn
  /// the gate off — same posture as iOS Settings → Touch ID).
  Future<bool> setEnabled(bool value) async {
    if (value == _isEnabled) return true;
    if (value) {
      if (!_isAvailable) return false;
      final ok = await authenticate(
        reason: 'Confirm with biometrics to enable unlock',
      );
      if (!ok) return false;
    }
    _isEnabled = value;
    // Enabling biometric while the app is open shouldn't lock the
    // user out mid-session — they just confirmed they're the right
    // person. Disabling clears any prior unlock flag for symmetry
    // (next launch starts unlocked because the gate is off anyway).
    _isUnlocked = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
    return true;
  }

  /// Re-arm the lock gate. Used by sign-out flows so a returning
  /// user has to re-authenticate, and by tests.
  void lock() {
    if (!_isEnabled) return;
    if (!_isUnlocked) return;
    _isUnlocked = false;
    notifyListeners();
  }
}
