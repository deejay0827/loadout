import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  // ───────── Email / password ─────────

  Future<UserCredential> signIn(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<UserCredential> signUp(String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    // Best-effort verification email; don't fail signup if it doesn't send.
    try {
      await cred.user?.sendEmailVerification();
    } catch (_) {
      // User can request a new verification email later.
    }
    return cred;
  }

  Future<void> sendEmailVerification() =>
      _auth.currentUser!.sendEmailVerification();

  Future<void> sendPasswordResetEmail(String email) =>
      _auth.sendPasswordResetEmail(email: email);

  // ───────── Email link (passwordless) ─────────

  static const _pendingEmailKey = 'auth.pendingEmailLinkEmail';

  static final ActionCodeSettings _emailLinkSettings = ActionCodeSettings(
    url: 'https://loadout-precision-reloading.web.app/auth/link',
    handleCodeInApp: true,
    iOSBundleId: 'com.johnsondigital.loadout',
    androidPackageName: 'com.johnsondigital.loadout',
    androidInstallApp: true,
    androidMinimumVersion: '1',
  );

  /// Send a sign-in link to [email]. The address is stashed locally so the
  /// app can complete sign-in automatically when the link is tapped on
  /// this device.
  Future<void> sendEmailLink(String email) async {
    await _auth.sendSignInLinkToEmail(
      email: email,
      actionCodeSettings: _emailLinkSettings,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingEmailKey, email);
  }

  /// If [link] is a Firebase email-link sign-in URL and we have a pending
  /// email saved locally, finish sign-in. Returns null otherwise.
  Future<UserCredential?> tryCompleteEmailLink(String link) async {
    if (!_auth.isSignInWithEmailLink(link)) return null;
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_pendingEmailKey);
    if (email == null) return null;
    try {
      final cred = await _auth.signInWithEmailLink(
        email: email,
        emailLink: link,
      );
      await prefs.remove(_pendingEmailKey);
      return cred;
    } catch (_) {
      return null;
    }
  }

  bool isSignInWithEmailLink(String link) =>
      _auth.isSignInWithEmailLink(link);

  // ───────── Anonymous ─────────

  Future<UserCredential> signInAnonymously() => _auth.signInAnonymously();

  // ───────── Google ─────────

  Future<UserCredential> signInWithGoogle() async {
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize();
      _googleInitialized = true;
    }
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: const ['email', 'profile'],
    );
    final auth = account.authentication;
    final credential = GoogleAuthProvider.credential(idToken: auth.idToken);
    return _auth.signInWithCredential(credential);
  }

  // ───────── Apple ─────────
  // iOS uses the native Sign in with Apple sheet (required for App Store
  // approval when other social logins are present). Android falls back to
  // Firebase's web OAuth flow.

  Future<UserCredential> signInWithApple() async {
    if (Platform.isIOS) {
      final apple = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final credential = OAuthProvider('apple.com').credential(
        idToken: apple.identityToken,
        accessToken: apple.authorizationCode,
      );
      return _auth.signInWithCredential(credential);
    }
    return _auth.signInWithProvider(AppleAuthProvider());
  }

  // ───────── Microsoft / Yahoo ─────────
  // Both go through Firebase's hosted OAuth flow.

  Future<UserCredential> signInWithMicrosoft() =>
      _auth.signInWithProvider(MicrosoftAuthProvider());

  Future<UserCredential> signInWithYahoo() =>
      _auth.signInWithProvider(YahooAuthProvider());

  // ───────── Sign out ─────────

  Future<void> signOut() async {
    await _auth.signOut();
    if (_googleInitialized) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // Already signed out / not initialized properly — ignore.
      }
    }
  }
}
