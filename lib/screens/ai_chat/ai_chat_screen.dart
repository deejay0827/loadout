// FILE: lib/screens/ai_chat/ai_chat_screen.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Renders the Pro-gated "Reloading Assistant" chat screen — a
// conversational front-end onto Anthropic's Messages API, with strict
// safety rails so the model never slips into prescriptive load data.
//
// `AiChatScreen` itself is a thin wrapper that wraps the body in a
// `ProGate(feature: 'AI Reloading Assistant', child: _AiChatScaffold())`.
// Non-Pro users see the gated-feature UI from `lib/widgets/pro_gate.dart`
// and never reach the network code.
//
// `_AiChatScaffold` is the real screen, with state for:
//
//   - `_history`        — the in-memory list of `ChatMessage`s for this
//     session. NEVER persisted. When the screen pops, the conversation
//     is gone.
//   - `_used`           — the running questions-this-month count, fetched
//     once at `initState` from `AiChatService.getQuestionsUsedThisMonth`
//     and updated after every successful send.
//   - `_quotaLoaded`    — false until the initial quota read returns,
//     so the AppBar pill renders "… / 30" instead of a misleading
//     "0 / 30".
//   - `_sending`        — disables the input bar and shows a typing
//     bubble while a request is in flight.
//
// The visible structure of the screen, top to bottom:
//
//   1. AppBar with a brass `_QuotaPill` ("12 / 30 this month"). When
//      `_used >= quota`, the pill flips to error-coloured.
//   2. A pinned brass-italic `_DisclaimerBanner` reminding the user
//      "AI is reference only. Always verify against current published
//      manuals before producing live ammunition." This is the THIRD
//      and most visible of the three liability rails (the system
//      prompt and the regex output filter live in `ai_chat_service.dart`).
//   3. If `AiChatConfig.isPlaceholder`, a `_ComingSoonNotice` card.
//   4. The message list. Empty state shows `_EmptyState` ("Ask me
//      anything"). Otherwise a `ListView.builder` of `_MessageBubble`s
//      — user bubbles right-aligned with brass tint, assistant bubbles
//      left-aligned. When `message.isError` is true (a refusal from
//      the safety filter, or a network error), the bubble uses the
//      theme's error red. While `_sending`, a `_TypingBubble` is
//      appended after the last message.
//   5. EITHER the `_ChatInputBar` (multiline `TextField` + circular
//      send button) OR, when the quota is exhausted, a "You've used
//      your 30 questions this month. Resets on the 1st." panel
//      replacing the input bar entirely.
//
// The `TextField` in `_ChatInputBar` deliberately turns off
// `autocorrect` and `enableSuggestions` — same UX choice as the SAAMI
// search field, so the OS doesn't rewrite niche reloading jargon while
// the user types.
//
// `_send()` is the call-site for the service. It snapshots the prior
// `_history`, optimistically appends the new user turn, calls
// `_service.sendMessage(userText, history)`, and on completion either
// appends the assistant reply, updates the count, shows a snackbar
// for `quotaExceeded`, or appends an error bubble. The new text is
// cleared from the input on send. After every state transition,
// `_scrollToBottomSoon()` posts a frame callback to animate the list
// to the bottom.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// All of the network plumbing, quota tracking, and safety filtering
// lives in `lib/services/ai_chat_service.dart`. This file is purely the
// rendering and orchestration shell — it has no business decisions in
// it beyond "send this when the user taps Send" and "clear the input
// after a successful enqueue."
//
// History is kept in memory only, by design. CLAUDE.md §13 commits to
// "your reloading data stays on this device" and "we don't operate a
// backend that stores reloading data." Persisting chat transcripts —
// which routinely include question fragments like "what's a good powder
// for..." — would weaken that commitment, and the value of restoring
// a chat across launches is small enough that we just throw it away.
//
// The placeholder-mode UI exists so that we can ship the screen and
// the navigation entry independently of when the real Anthropic key
// is dropped in. Until `AiChatConfig.isPlaceholder` flips to false,
// the input bar is disabled and a "coming soon" notice replaces the
// hopeful empty state.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Three rough edges:
//
//   1. The quota pill must visibly distinguish "still loading the
//      initial count" from "you've sent zero messages this month."
//      The `_quotaLoaded` flag drives a "… / 30" placeholder until
//      the SharedPreferences read returns, otherwise users would briefly
//      see "0 / 30" and assume the counter had reset.
//   2. The post-send scroll must use `addPostFrameCallback` rather than
//      a synchronous `animateTo`. The new message hasn't been laid
//      out yet at the time `setState` returns; `maxScrollExtent` would
//      still report the pre-message value, and the list would scroll
//      one bubble short of the bottom.
//   3. Refusal bubbles (returned by the regex output filter when the
//      model leaks a recipe) come back wrapped in a `ChatMessage` with
//      `isError: true`. The bubble styling switches on that, NOT on
//      the role — the role is still `assistant`. Distinguishing those
//      two assistant codepaths visually is what tells the user "this
//      is the safety filter speaking, not Claude."
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/screens/home/home_screen.dart` — the bottom-nav "Assistant"
//   tab (or its drawer-opened variant) hosts this screen.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// - Indirectly: HTTPS POST to api.anthropic.com via the
//   `AiChatService` it constructs.
// - Indirectly: SharedPreferences reads/writes for quota tracking via
//   the same service.
// - The screen itself does no I/O, no DB writes, no clipboard, no
//   plugins. Persistent state lives entirely behind the service.

import 'package:flutter/material.dart';

import '../../services/ai_chat_config.dart';
import '../../services/ai_chat_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pro_gate.dart';

/// Pro-gated chat-style assistant for reloading concepts.
///
/// Liability rails are stacked:
///   1. The system prompt (`kReloadingAssistantSystemPrompt`) tells the
///      model in absolute terms not to produce specific load data.
///   2. [AiChatService.looksLikeLoadData] is a regex-based output filter
///      that catches charge-weight + powder + cartridge combos that
///      slip through and replaces them with a stock refusal.
///   3. The visible disclaimer banner (top of screen, brass italic) keeps
///      the user reminded that this is reference only.
///
/// Quota: 30 questions per Pro user per calendar month, tracked in
/// SharedPreferences and reset on the 1st via period-tag comparison
/// inside [AiChatService].
///
/// History is in-memory only — when this screen is dismissed, the
/// conversation goes with it. Privacy posture (see CLAUDE.md §13)
/// keeps us well clear of persisting prompt content.
class AiChatScreen extends StatelessWidget {
  const AiChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ProGate(
      feature: 'AI Reloading Assistant',
      child: _AiChatScaffold(),
    );
  }
}

class _AiChatScaffold extends StatefulWidget {
  const _AiChatScaffold();

  @override
  State<_AiChatScaffold> createState() => _AiChatScaffoldState();
}

class _AiChatScaffoldState extends State<_AiChatScaffold> {
  late final AiChatService _service;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  final List<ChatMessage> _history = [];
  bool _sending = false;
  int _used = 0;
  bool _quotaLoaded = false;

  @override
  void initState() {
    super.initState();
    _service = AiChatService();
    _loadQuota();
  }

  @override
  void dispose() {
    _service.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _loadQuota() async {
    final used = await _service.getQuestionsUsedThisMonth();
    if (!mounted) return;
    setState(() {
      _used = used;
      _quotaLoaded = true;
    });
  }

  bool get _quotaExhausted =>
      _used >= AiChatConfig.monthlyQuestionQuota;

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    if (_quotaExhausted) return;
    if (AiChatConfig.isPlaceholder) {
      _showSnack('AI Chat is in beta — coming soon.');
      return;
    }

    final userMsg = ChatMessage(role: 'user', content: text);
    final priorHistory = List<ChatMessage>.from(_history);
    setState(() {
      _history.add(userMsg);
      _sending = true;
      _inputController.clear();
    });
    _scrollToBottomSoon();

    final result = await _service.sendMessage(
      userText: text,
      history: priorHistory,
    );
    if (!mounted) return;

    setState(() {
      _sending = false;
      if (result.isSuccess) {
        _history.add(result.message!);
        _used = result.questionsUsedThisMonth;
      } else if (result.quotaExceeded) {
        _used = AiChatConfig.monthlyQuestionQuota;
        _showSnack(result.error!);
      } else {
        _history.add(
          ChatMessage(
            role: 'assistant',
            content: result.error ?? 'Something went wrong.',
            isError: true,
          ),
        );
      }
    });
    _scrollToBottomSoon();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reloading Assistant'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: _QuotaPill(
                used: _used,
                quota: AiChatConfig.monthlyQuestionQuota,
                loaded: _quotaLoaded,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _DisclaimerBanner(),
            if (AiChatConfig.isPlaceholder) const _ComingSoonNotice(),
            Expanded(
              child: _history.isEmpty
                  ? _EmptyState(
                      placeholder: AiChatConfig.isPlaceholder,
                      quotaExhausted: _quotaExhausted,
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: _history.length + (_sending ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (_sending && index == _history.length) {
                          return const _TypingBubble();
                        }
                        return _MessageBubble(message: _history[index]);
                      },
                    ),
            ),
            if (_quotaExhausted)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: theme.colorScheme.surfaceContainerHigh,
                child: Text(
                  'You\'ve used your '
                  '${AiChatConfig.monthlyQuestionQuota} questions this month. '
                  'Resets on the 1st.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              )
            else
              _ChatInputBar(
                controller: _inputController,
                focusNode: _inputFocus,
                enabled: !_sending && !AiChatConfig.isPlaceholder,
                onSend: _send,
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── Subwidgets ───────────────────────────

class _DisclaimerBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 18,
            color: AppTheme.brass,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI is reference only. Always verify against current published '
              'manuals before producing live ammunition.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.brass,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComingSoonNotice extends StatelessWidget {
  const _ComingSoonNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.surfaceContainer,
      child: Row(
        children: [
          Icon(
            Icons.science_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI Chat is in beta — coming soon. The screen is ready; the '
              'assistant will be enabled in a future update.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuotaPill extends StatelessWidget {
  const _QuotaPill({
    required this.used,
    required this.quota,
    required this.loaded,
  });

  final int used;
  final int quota;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exhausted = used >= quota;
    final color = exhausted
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final text = loaded ? '$used / $quota this month' : '… / $quota';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.placeholder,
    required this.quotaExhausted,
  });

  final bool placeholder;
  final bool quotaExhausted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 56,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              placeholder
                  ? 'Coming soon'
                  : (quotaExhausted ? 'Out of questions' : 'Ask me anything'),
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              placeholder
                  ? 'The Reloading Assistant will be enabled in a future '
                      'update. The UI is ready for it.'
                  : 'Concepts, terminology, and process — at a high level. '
                      'I won\'t share specific load data; use a published '
                      'manual for that.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    final bg = isUser
        ? theme.colorScheme.primary.withValues(alpha: 0.18)
        : (message.isError
            ? theme.colorScheme.error.withValues(alpha: 0.12)
            : theme.colorScheme.surfaceContainerHigh);
    final border = isUser
        ? theme.colorScheme.primary.withValues(alpha: 0.4)
        : (message.isError
            ? theme.colorScheme.error.withValues(alpha: 0.5)
            : theme.colorScheme.outline.withValues(alpha: 0.3));
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Text(
          message.content,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(14),
          ),
        ),
        child: SizedBox(
          width: 36,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '...',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatInputBar extends StatelessWidget {
  const _ChatInputBar({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: enabled,
                maxLines: 4,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                // Same UX choice as the SAAMI search field — disable
                // OS-level autocorrect / suggestion overlays so reloading
                // jargon doesn't get rewritten.
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: enabled
                      ? 'Ask about concepts, terminology, workflow…'
                      : 'Disabled',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: enabled ? onSend : null,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
              ),
              child: const Icon(Icons.send_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}
