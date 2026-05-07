// FILE: lib/services/ai_chat_config.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Holds the public configuration constants for the LoadOut "Reloading
// Assistant" — the Pro-gated AI chat feature backed by Anthropic's Messages
// API. There is exactly one type in this file: the `AiChatConfig` class,
// which is just a static-only namespace for compile-time constants. No
// instances of it are ever created; everything is accessed as
// `AiChatConfig.foo`.
//
// What lives here:
//
//   - `anthropicApiKey` — the API key sent in the `x-api-key` HTTP header on
//     every request to Anthropic. Currently hard-coded to the placeholder
//     string `'REPLACE_ME_ANTHROPIC_KEY'`. A real key is dropped in at
//     build/release time.
//   - `apiBaseUrl` — `https://api.anthropic.com/v1/messages`. The single
//     endpoint the Reloading Assistant talks to.
//   - `model` — the Claude model identifier passed in each request body
//     (currently `claude-sonnet-4-7`).
//   - `maxOutputTokens` — caps the size of each reply for cost control. A
//     "token" in this context is a chunk of text (roughly ~4 characters of
//     English) that Anthropic bills per. Lower number = cheaper, shorter
//     responses.
//   - `monthlyQuestionQuota` — the per-Pro-user-per-calendar-month cap (30).
//     Enforced client-side by `AiChatService` against a SharedPreferences
//     counter.
//   - `isPlaceholder` — a getter that returns `true` whenever
//     `anthropicApiKey` still starts with `REPLACE_ME`. The chat UI checks
//     this and shows a "coming soon" state instead of attempting any HTTP
//     calls. Lets us ship the screen and the menu entry independently of
//     when the real key lands.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Centralizing these values keeps the rest of the AI plumbing
// (`ai_chat_service.dart`, `ai_chat_screen.dart`) free of string literals.
// When we eventually migrate from "key embedded in binary" to "thin backend
// proxy that authenticates with a Firebase ID token + RevenueCat
// entitlement check and forwards to Anthropic," the only file the rest of
// the codebase needs to learn about is this one. The request shape, safety
// filter, and quota counter on the client all stay identical — what changes
// is `apiBaseUrl` (now points at our proxy), the auth header (Firebase ID
// token instead of `x-api-key`), and `isPlaceholder` (always `false` once
// the proxy ships).
//
// Pre-launch we accept "key in the binary, behind a Pro entitlement, with a
// tight 30-questions-per-month cap" as a controlled risk: the blast radius
// of a leaked key is bounded by paying users only and the per-user cap
// makes runaway abuse expensive for an attacker.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Not particularly tricky — this is a static config namespace. The only
// non-obvious bit is the `isPlaceholder` indirection: checking the prefix
// `'REPLACE_ME'` rather than checking equality with the full literal lets
// us swap in real keys without forgetting to flip a "ready" flag, and lets
// us experiment with multiple placeholder values during development.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/services/ai_chat_service.dart` — reads every constant: builds the
//   HTTP request, populates the auth header, sets the JSON body's `model`
//   and `max_tokens`, and short-circuits to a "coming soon" error when
//   `isPlaceholder` is true.
// - `lib/screens/ai_chat/ai_chat_screen.dart` — reads `isPlaceholder` to
//   render the beta-mode UI, and `monthlyQuestionQuota` for the AppBar
//   quota pill and the quota-exhausted notice.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure compile-time constants. No I/O, no network, no plugin calls.

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
