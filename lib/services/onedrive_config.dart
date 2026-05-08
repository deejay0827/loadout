// FILE: lib/services/onedrive_config.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Holds the public Microsoft Identity Platform configuration for the
// OneDrive Cloud Sync provider. Mirrors the pattern in
// `revenue_cat_config.dart`: PUBLIC client identifier shipped in source
// (anyone can read an iOS / Android binary, so there's no secret here)
// plus an `isPlaceholder` getter the rest of the app can use to show a
// "OneDrive not yet available" state during development.
//
// MICROSOFT OAUTH SETUP (operator step):
//   1. Go to portal.azure.com → App registrations → New registration.
//   2. Name: "LoadOut OneDrive Sync".
//   3. Supported account types: "Accounts in any organizational directory
//      and personal Microsoft accounts (e.g., Skype, Xbox)" — this is
//      what enables consumer OneDrive accounts.
//   4. Redirect URI:
//        Public client / native (mobile & desktop): set TWO entries
//          - `msauth.com.johnsondigital.loadout://auth`     (Android scheme,
//            we follow Microsoft's convention `msauth.<package>://auth`).
//          - `loadout://onedrive-callback`                   (iOS / macOS,
//            registered in Info.plist's CFBundleURLTypes).
//   5. After registration, copy the **Application (client) ID** below
//      to [clientId]. Keep [tenantId] as `consumers` for the personal
//      OneDrive flow — Microsoft's `/consumers/oauth2/...` endpoint is
//      what the OneDrive consumer storage scope (`Files.ReadWrite.AppFolder`)
//      authorizes against. (For an MSAL-flavored common multi-tenant flow
//      use `common`, but consumer OneDrive storage requires `consumers`.)
//   6. Under "API permissions" add `Microsoft Graph → Delegated →
//      Files.ReadWrite.AppFolder` and grant admin consent if the tenant
//      requires it (consumer accounts don't, but the org-tenant fallback
//      does).
//   7. **Public clients do not get a secret.** Mobile-style OAuth flows
//      use PKCE (Proof Key for Code Exchange) instead. There is no
//      client_secret in this file because there isn't one to ship.
//   8. Document next rotation: PKCE-only public client registrations have
//      no expiry. The redirect URIs themselves should be reviewed annually
//      to make sure they still match the iOS / Android URL scheme
//      registrations.
//
// PRIVACY POSTURE: this file contains no secrets and no PII. The
// `clientId` is a public Azure-issued GUID; the redirect schemes are
// public iOS / Android conventions. The actual OAuth flow runs entirely
// on-device — Microsoft sees the user's Microsoft account email (their
// OneDrive identity) but LoadOut never receives the access or refresh
// token outside the local secure-storage layer.

/// Placeholder constant used to detect "not yet configured" mode. When
/// [clientId] starts with this prefix, the OneDrive provider returns
/// false from `isAvailable()` and the sync screen surfaces a "Not yet
/// configured" message instead of trying to authenticate.
const String _kOneDrivePlaceholderPrefix = 'REPLACE_ME';

/// Public OAuth configuration for the LoadOut OneDrive Cloud Sync
/// provider. The values here ship inside the iOS / Android binary —
/// they're public by definition, like the bundle identifier itself.
/// There is no client_secret because the OneDrive provider uses PKCE
/// (a public-client OAuth flow that doesn't need one).
class OneDriveConfig {
  OneDriveConfig._();

  /// Azure AD Application (client) ID. Replace `REPLACE_ME_*` with the
  /// real GUID from portal.azure.com → App registrations → LoadOut
  /// OneDrive Sync → Overview.
  static const String clientId = 'REPLACE_ME_AZURE_CLIENT_ID';

  /// Tenant slug for the OAuth endpoint. Use `consumers` for the
  /// consumer OneDrive `Files.ReadWrite.AppFolder` scope.
  static const String tenantId = 'consumers';

  /// OAuth scopes requested. `offline_access` is required to receive a
  /// refresh token so the provider can re-mint access tokens silently.
  static const List<String> scopes = <String>[
    'Files.ReadWrite.AppFolder',
    'offline_access',
  ];

  /// Redirect URI used by the OAuth flow on iOS / macOS. Must match a
  /// CFBundleURLSchemes entry in `ios/Runner/Info.plist` so the system
  /// hands the auth code back to the app.
  static const String iosRedirectUri = 'loadout://onedrive-callback';

  /// Redirect URI used by the OAuth flow on Android. Must match an
  /// `<intent-filter>` in `android/app/src/main/AndroidManifest.xml`.
  /// We follow Microsoft's documented convention of
  /// `msauth.<package>://auth` so any future MSAL upgrade keeps working.
  static const String androidRedirectUri =
      'msauth.com.johnsondigital.loadout://auth';

  /// Microsoft Graph base URL.
  static const String graphBase = 'https://graph.microsoft.com/v1.0';

  /// True when [clientId] is still a placeholder. The Cloud Sync UI
  /// surfaces a "Not yet configured" state in this case so dev and CI
  /// builds don't break.
  static bool get isPlaceholder => clientId.startsWith(_kOneDrivePlaceholderPrefix);
}
