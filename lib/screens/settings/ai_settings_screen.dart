// FILE: lib/screens/settings/ai_settings_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// The "Settings → AI" page. The ONLY AI-related setting LoadOut surfaces
// is for **AI Smart Import** — the scoped Pro feature that improves a
// low-confidence parse from the photo-import pipeline. No "AI assistant"
// language, no chat, no "smart features" buzzwords. The framing
// throughout is utility-focused: "this feature reads OCR'd text and
// improves the parse — that's it."
//
// What the screen exposes:
//
//   1. **Master enable toggle**: "Use AI for messy handwriting in
//      Smart Import" — persisted in `SharedPreferences` under
//      `ai_smart_import_enabled` (default off). Pro-gated via the
//      tile's tap handler. Non-Pro users see the standard paywall
//      route via `ensurePro`.
//   2. **Hosted-mode usage badge**: when enabled and Pro, shows
//      "X / 20 used this month" using the most recent
//      `HostedUsageStats` snapshot. If no usage call has been made
//      this session, shows "Up to 20 / month" instead.
//   3. **BYOK section**: a "Use my own Anthropic key" toggle that
//      reveals a password-style text field with a reveal-eye, a
//      "Test Connection" button, and Save / Remove. The key is
//      stored in `flutter_secure_storage`.
//   4. **Privacy reassurance card** at the top: a literal,
//      reloader-skeptic-friendly explanation of what AI Smart Import
//      does and does NOT do.
//
// All copy mirrors CLAUDE.md §13 / §20: AI Smart Import only ever sees
// OCR text the user opted into; LoadOut runs no backend that stores
// reloading data; Anthropic doesn't train on API requests.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// The on-device parser handles the easy cases for free. AI Smart Import
// is an opt-in, Pro-only, narrow boost for messier handwriting. Putting
// the toggle in Settings (rather than as a per-import switch) keeps the
// import flow uncluttered and lets the user make a one-time, informed
// privacy decision instead of a per-photo nag.
//
// Routing this from Settings → AI also gives BYOK users somewhere
// obvious to manage their key. The same screen serves both groups
// because the state model is a single boolean (enabled?) plus an
// optional secure-storage key.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. **Two-state Pro gate.** The master enable toggle gates AT TAP
//    (so we can route to the paywall via `ensurePro`), not on render
//    — rendering the toggle locked would feel inconsistent with the
//    other AI settings users might enable later.
// 2. **Secure-storage IO is async.** Every read/write of the BYOK
//    key has to be awaited; the screen tracks `_byokLoading` /
//    `_busy` so the buttons disable correctly.
// 3. **Test connection is destructive on success path.** If the user
//    typed a valid key, we DON'T want to save it without their
//    consent — so "Test Connection" is read-only against Anthropic
//    and "Save" is a separate button.
// 4. **Usage is best-effort.** `hostedUsage()` returns null when
//    BYOK is in use OR when no hosted call has run this session.
//    The UI handles both as "no number to show" cases.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/settings/settings_screen.dart` will eventually link
//   to this page (the parent settings reorg is Agent C's territory;
//   we expose the route via `AiSettingsScreen()` and let the parent
//   wire its tile).
// - `lib/screens/recipes/photo_import_review_screen.dart` reads the
//   master enable flag so the "Improve with AI" button only renders
//   when the user has explicitly opted in.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Reads/writes `SharedPreferences` (`ai_smart_import_enabled`).
// - Reads/writes `FlutterSecureStorage` (the BYOK key).
// - Optionally hits Anthropic's `/v1/messages` endpoint for the
//   "Test connection" sanity check.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/ai_smart_import_config.dart';
import '../../services/ai_smart_import_service.dart';
import '../../services/beginner_mode_service.dart';
import '../../services/entitlement_notifier.dart';
import '../../widgets/pro_gate.dart';

/// SharedPreferences key for the master "Use AI for Smart Import"
/// toggle. Read by both this screen and the photo-import review
/// surface (so it can hide the "Improve with AI" button when the
/// user has opted out).
const String kAiSmartImportEnabledPrefKey = 'ai_smart_import_enabled';

/// Settings page for the AI Smart Import feature. The only AI-related
/// surface in Settings — does NOT cover any future AI features.
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  /// Master "AI Smart Import enabled" state.
  bool _enabled = false;

  /// True until the initial pref + secure-storage reads land.
  bool _loading = true;

  /// Mirrors `getByokKey()`. Null when the user hasn't set one.
  String? _byokKey;

  /// "Use my own Anthropic key" toggle — drives the input row's
  /// visibility. Defaults to true if a key is already cached so
  /// the user lands on the existing-key state.
  bool _byokToggle = false;

  /// The text field's controller; pre-filled with the cached key
  /// (if any) so the user can edit / verify. The reveal-eye flips
  /// `_byokObscure`.
  final _byokController = TextEditingController();
  bool _byokObscure = true;

  /// Cached hosted-mode usage snapshot. May be null if BYOK is in
  /// use OR if no hosted call has fired this session.
  HostedUsageStats? _usage;

  /// Disable the screen during long-running ops (test, save).
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  @override
  void dispose() {
    _byokController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Capture context-dependent reads before any await so we don't
    // hit the use_build_context_synchronously lint.
    final svc = context.read<AiSmartImportService>();
    final prefs = await SharedPreferences.getInstance();
    final byok = await svc.getByokKey();
    final usage = await svc.hostedUsage();
    if (!mounted) return;
    setState(() {
      _enabled = prefs.getBool(kAiSmartImportEnabledPrefKey) ?? false;
      _byokKey = byok;
      _byokToggle = byok != null;
      _byokController.text = byok ?? '';
      _usage = usage;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    if (value && !context.read<EntitlementNotifier>().isPro) {
      // BYOK is an exception — a non-Pro user with their own key
      // can still use the feature. Honor that here so the toggle
      // doesn't false-paywall a BYOK user.
      if (_byokKey == null) {
        final upgraded = await ensurePro(context);
        if (!mounted) return;
        if (!upgraded) return;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAiSmartImportEnabledPrefKey, value);
    if (!mounted) return;
    setState(() => _enabled = value);
  }

  Future<void> _setByokToggle(bool value) async {
    setState(() => _byokToggle = value);
    if (!value && _byokKey != null) {
      // User flipped the toggle off; remove the key so we go back
      // to hosted mode (or no-mode for free users).
      await _removeByok();
    }
  }

  Future<void> _saveByok() async {
    final svc = context.read<AiSmartImportService>();
    final messenger = ScaffoldMessenger.of(context);
    final value = _byokController.text.trim();
    if (value.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Enter a key first.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await svc.setByokKey(value);
      if (!mounted) return;
      setState(() {
        _byokKey = value;
        _byokToggle = true;
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved. AI Smart Import will use your key.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeByok() async {
    final svc = context.read<AiSmartImportService>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await svc.setByokKey(null);
      if (!mounted) return;
      setState(() {
        _byokKey = null;
        _byokController.clear();
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Removed.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testByok() async {
    final svc = context.read<AiSmartImportService>();
    final messenger = ScaffoldMessenger.of(context);
    final value = _byokController.text.trim();
    if (value.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Enter a key first.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await svc.testByokKey(value);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Connection OK.')),
      );
    } on SmartImportException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Test failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ─────────────── build ───────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPro = context.watch<EntitlementNotifier>().isPro;
    // Beginner Mode hides the BYOK ("Bring your own Anthropic key")
    // section entirely. The hosted-proxy toggle is enough surface for
    // a beginner; "use your own API key" is a power-user concept that
    // most reloaders don't need and that, if surfaced too early,
    // suggests "you have to set this up to use AI" — which is wrong.
    // Power users turn Beginner Mode off in App Preferences and the
    // BYOK card reappears.
    final beginnerOn = context.watch<BeginnerModeService>().isEnabled;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('AI')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            const SizedBox(height: 8),
            _PrivacyReassuranceCard(theme: theme),
            const _SectionHeader('AI Smart Import'),
            SwitchListTile(
              secondary: const Icon(Icons.auto_fix_high_outlined),
              title: const Text(
                'Use AI for messy handwriting in Smart Import',
              ),
              subtitle: const Text(
                'Pro feature. When the on-device parser is uncertain, send '
                'the OCR\'d text to AI to improve the parse. Only the '
                'OCR\'d text from photos you import is sent. Off by default.',
              ),
              value: _enabled,
              onChanged: (v) {
                // ignore: discarded_futures
                _setEnabled(v);
              },
            ),
            if (_enabled && (_byokKey != null || isPro))
              _UsageTile(usage: _usage, byokActive: _byokKey != null),
            if (!beginnerOn) ...[
              const _SectionHeader('Bring your own key'),
              SwitchListTile(
                secondary: const Icon(Icons.vpn_key_outlined),
                title: const Text('Use my own Anthropic key'),
                subtitle: const Text(
                  'Skip LoadOut\'s hosted proxy and use your own Anthropic '
                  'API key. The key is stored only on this device, in the '
                  'iOS Keychain or Android Keystore. No monthly cap from us; '
                  'you pay Anthropic directly.',
                ),
                value: _byokToggle,
                onChanged: (v) {
                  // ignore: discarded_futures
                  _setByokToggle(v);
                },
              ),
              if (_byokToggle) _ByokInputCard(
                controller: _byokController,
                obscure: _byokObscure,
                onToggleObscure: () =>
                    setState(() => _byokObscure = !_byokObscure),
                onTest: _testByok,
                onSave: _saveByok,
                onRemove: _byokKey == null ? null : _removeByok,
                busy: _busy,
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// One-paragraph privacy reassurance shown at the top of the AI page.
/// Skeptic-friendly framing: utility, not buzz.
class _PrivacyReassuranceCard extends StatelessWidget {
  const _PrivacyReassuranceCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What AI Smart Import does (and does not do)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'AI Smart Import only reads OCR\'d text from photos '
                    'you import. We never see your saved recipes, '
                    'firearms, or anything else from this app. The '
                    'request body is not logged by our proxy. Anthropic '
                    'does not train on API requests. There is no '
                    'conversational AI here — just a translation tool '
                    'that turns messy handwriting into structured fields.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "X / 20 used this month" tile, or "Up to 20 / month" when no
/// hosted call has run yet this session. Hidden in BYOK mode.
class _UsageTile extends StatelessWidget {
  const _UsageTile({required this.usage, required this.byokActive});

  final HostedUsageStats? usage;
  final bool byokActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (byokActive) {
      return ListTile(
        leading: const Icon(Icons.bolt_outlined),
        title: const Text('Using your own key'),
        subtitle: const Text(
          'BYOK mode is active. No LoadOut quota applies.',
        ),
        dense: true,
      );
    }
    final u = usage;
    final label = u == null
        ? 'Up to ${AiSmartImportConfig.monthlyCap} / month'
        : '${u.usedThisMonth} / ${u.monthlyCap} used this month';
    final exhausted = u != null && u.isExhausted;
    return ListTile(
      leading: Icon(
        Icons.cloud_outlined,
        color: exhausted
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
      ),
      title: const Text('Hosted mode'),
      subtitle: Text(
        u == null
            ? 'Routes through LoadOut\'s proxy. Up to '
                '${AiSmartImportConfig.monthlyCap} requests per month.'
            : 'Routes through LoadOut\'s proxy. $label.',
        style: TextStyle(
          color: exhausted ? theme.colorScheme.error : null,
        ),
      ),
      trailing: Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: exhausted
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      dense: true,
    );
  }
}

/// The reveal-eye TextField + Test / Save / Remove row for the BYOK key.
class _ByokInputCard extends StatelessWidget {
  const _ByokInputCard({
    required this.controller,
    required this.obscure,
    required this.onToggleObscure,
    required this.onTest,
    required this.onSave,
    required this.onRemove,
    required this.busy,
  });

  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final Future<void> Function() onTest;
  final Future<void> Function() onSave;
  final Future<void> Function()? onRemove;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [
              FilteringTextInputFormatter.singleLineFormatter,
            ],
            decoration: InputDecoration(
              labelText: 'Anthropic API key (sk-ant-…)',
              suffixIcon: IconButton(
                icon: Icon(
                  obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                ),
                tooltip: obscure ? 'Show key' : 'Hide key',
                onPressed: onToggleObscure,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // ignore: discarded_futures
                  onPressed: busy ? null : onTest,
                  icon: const Icon(Icons.cable_outlined),
                  label: const Text('Test'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  // ignore: discarded_futures
                  onPressed: busy ? null : onSave,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
          if (onRemove != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              // ignore: discarded_futures
              onPressed: busy ? null : onRemove,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove key'),
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
