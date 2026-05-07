/// Configuration for the LoadOut "Reloading Assistant" AI chat feature.
///
/// **Long-term plan:** the Anthropic API key SHOULD NOT ship in the binary.
/// In a future release this should be replaced with a thin backend proxy
/// (e.g. a Cloud Function or other server-side endpoint that authenticates
/// the user via Firebase Auth, applies the per-user quota server-side, and
/// holds the Anthropic key as a server secret). For the v1 launch we accept
/// the simpler in-binary approach with a tight per-user quota cap (30 q/mo)
/// gated behind the existing Pro entitlement so:
///   - The blast radius of a leaked key is bounded (Pro users only, capped).
///   - The plumbing on the client (request shape, safety filter, quota
///     accounting) doesn't need to change when the proxy lands — just the
///     URL and credential header.
///
/// Until a real key is dropped in, [isPlaceholder] returns true and the
/// chat UI renders a "coming soon" state. This lets us ship the screen
/// and the navigation entry independently of key availability.
class AiChatConfig {
  /// Anthropic API key. Treated as a placeholder until set to a real key.
  /// In production, this should be moved to a backend proxy so the key
  /// never ships with the app — but for v1 launch we accept the simpler
  /// in-binary approach with a tight quota cap.
  static const String anthropicApiKey = 'REPLACE_ME_ANTHROPIC_KEY';

  /// Anthropic API base URL.
  static const String apiBaseUrl = 'https://api.anthropic.com/v1/messages';

  /// The model to use.
  static const String model = 'claude-sonnet-4-7';

  /// Max output tokens per response (cost control).
  static const int maxOutputTokens = 600;

  /// Maximum questions allowed per Pro user per calendar month.
  static const int monthlyQuestionQuota = 30;

  /// Whether the embedded API key is still a placeholder. When true, the
  /// chat UI renders a "coming soon" state instead of attempting calls.
  static bool get isPlaceholder => anthropicApiKey.startsWith('REPLACE_ME');
}
