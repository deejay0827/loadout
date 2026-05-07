import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_chat_config.dart';

/// System prompt for the LoadOut Reloading Assistant.
///
/// This prompt is the FIRST line of defense for the liability rails — the
/// model is told in absolute terms not to produce specific load data. The
/// SECOND line of defense is the regex-based output filter in
/// [AiChatService.looksLikeLoadData] which catches anything that slips
/// through.
const String kReloadingAssistantSystemPrompt = '''
You are LoadOut's reloading assistant. You help users understand reloading concepts, terminology, and process — at a high level only.

ABSOLUTE RULES:
1. NEVER give specific load data. No charge weights, no COAL targets, no pressure values, no primer recommendations for specific cartridges. If a user asks for a load, redirect them to current published manuals from Hodgdon, Sierra, Hornady, Lyman, etc.
2. NEVER recommend exceeding any published maximum.
3. NEVER suggest substituting components without consulting a manual.
4. ALWAYS reinforce: cross-check with current published reloading manuals before producing live ammunition.
5. If the user is new to reloading, encourage them to take a class or work with someone experienced.

You CAN help with:
- Explaining concepts (CBTO vs COAL, shoulder bump, headspace, BCs G1 vs G7, neck tension)
- Comparing approaches at a conceptual level (full-length vs neck sizing — the tradeoffs)
- Cartridge metadata that's already in the SAAMI database (case length, max pressure)
- Workflow questions (when to anneal, why people sort brass)
- Equipment questions in general terms (what a comparator does)

Keep responses concise. Use plain English. Reference published sources where appropriate.
''';

/// Stock refusal text used when the safety filter trips. Same wording used
/// for the model's own refusals where possible so the user sees a
/// consistent message regardless of which layer caught the request.
const String kSafetyRefusal =
    'For your safety I can\'t share specific load data — charge weights, '
    'COAL/CBTO targets, primer picks, or pressure numbers. Please pull '
    'current data from a published manual (Hodgdon, Sierra, Hornady, '
    'Lyman, Vihtavuori, etc.) and cross-check at least two sources. '
    'I\'m happy to talk through concepts, terminology, or workflow at a '
    'high level instead.';

/// One chat message in the conversation history. Roles match the Anthropic
/// Messages API: `user` and `assistant`.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.isError = false,
  });

  final String role;
  final String content;

  /// Marks an assistant turn that represents a local error / refusal
  /// rather than a real model response. Used by the UI to style error
  /// bubbles differently.
  final bool isError;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  Map<String, dynamic> toApiJson() => {
        'role': role,
        'content': content,
      };
}

/// Result returned by [AiChatService.sendMessage]. Either a successful
/// assistant turn (with the new message + remaining quota) or an error
/// case the UI should show to the user.
class AiChatResult {
  const AiChatResult.success({
    required this.message,
    required this.questionsUsedThisMonth,
  })  : error = null,
        quotaExceeded = false;

  const AiChatResult.error(this.error)
      : message = null,
        questionsUsedThisMonth = 0,
        quotaExceeded = false;

  const AiChatResult.quotaExceeded({
    required this.questionsUsedThisMonth,
  })  : message = null,
        error = 'You\'ve used your '
            '${AiChatConfig.monthlyQuestionQuota} questions this month. '
            'Resets on the 1st.',
        quotaExceeded = true;

  final ChatMessage? message;
  final int questionsUsedThisMonth;
  final String? error;
  final bool quotaExceeded;

  bool get isSuccess => message != null;
}

/// Handles HTTP, quota tracking, and the output safety filter for the
/// Reloading Assistant chat. Stateless across instances apart from the
/// SharedPreferences-backed quota counter.
class AiChatService {
  AiChatService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // ─────────────────────────── Quota ───────────────────────────

  /// Current YYYY-MM tag. Used as the key suffix and the period marker.
  String _currentPeriod() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    return '${now.year}-$mm';
  }

  String _countKeyForPeriod(String period) =>
      'ai_chat_count_${period.replaceAll('-', '_')}';

  static const String _periodPrefKey = 'ai_chat_count_period';

  /// Returns the count of questions used in the current calendar month,
  /// resetting the counter if the calendar month rolled over since the
  /// last increment.
  Future<int> getQuestionsUsedThisMonth() async {
    final prefs = await SharedPreferences.getInstance();
    final period = _currentPeriod();
    final storedPeriod = prefs.getString(_periodPrefKey);
    if (storedPeriod != period) {
      // New month — reset the counter for the new period. We deliberately
      // don't delete the previous month's key; it's harmless and lets us
      // do month-over-month diagnostics if we ever want them.
      await prefs.setString(_periodPrefKey, period);
      await prefs.setInt(_countKeyForPeriod(period), 0);
      return 0;
    }
    return prefs.getInt(_countKeyForPeriod(period)) ?? 0;
  }

  /// Number of questions remaining in the current month.
  Future<int> getQuestionsRemainingThisMonth() async {
    final used = await getQuestionsUsedThisMonth();
    final remaining = AiChatConfig.monthlyQuestionQuota - used;
    return remaining < 0 ? 0 : remaining;
  }

  /// Increment the month's counter by one. Called only after a successful
  /// (non-error) API response so failed calls don't burn quota.
  Future<int> _incrementCount() async {
    final prefs = await SharedPreferences.getInstance();
    final period = _currentPeriod();
    final key = _countKeyForPeriod(period);
    final next = (prefs.getInt(key) ?? 0) + 1;
    await prefs.setString(_periodPrefKey, period);
    await prefs.setInt(key, next);
    return next;
  }

  // ─────────────────────────── Send ───────────────────────────

  /// Send [userText] as a new user turn given the prior [history], hit the
  /// Anthropic API, run the response through the safety filter, and return
  /// the result.
  ///
  /// [history] should NOT include the new user turn — this method appends
  /// it internally before calling the API.
  Future<AiChatResult> sendMessage({
    required String userText,
    required List<ChatMessage> history,
  }) async {
    if (AiChatConfig.isPlaceholder) {
      return const AiChatResult.error(
        'AI Chat is in beta — coming soon.',
      );
    }

    // Quota check BEFORE the network call.
    final used = await getQuestionsUsedThisMonth();
    if (used >= AiChatConfig.monthlyQuestionQuota) {
      return AiChatResult.quotaExceeded(questionsUsedThisMonth: used);
    }

    final messages = [
      for (final m in history) m.toApiJson(),
      {'role': 'user', 'content': userText},
    ];

    final body = jsonEncode({
      'model': AiChatConfig.model,
      'max_tokens': AiChatConfig.maxOutputTokens,
      'system': kReloadingAssistantSystemPrompt,
      'messages': messages,
    });

    http.Response resp;
    try {
      resp = await _client.post(
        Uri.parse(AiChatConfig.apiBaseUrl),
        headers: {
          'content-type': 'application/json',
          'x-api-key': AiChatConfig.anthropicApiKey,
          'anthropic-version': '2023-06-01',
        },
        body: body,
      );
    } catch (e) {
      debugPrint('AiChatService: network error: $e');
      return const AiChatResult.error(
        'Network error. Check your connection and try again.',
      );
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      debugPrint(
        'AiChatService: HTTP ${resp.statusCode}: ${resp.body}',
      );
      return AiChatResult.error(
        'Assistant unavailable (HTTP ${resp.statusCode}). Try again shortly.',
      );
    }

    String text;
    try {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final content = decoded['content'] as List<dynamic>?;
      if (content == null || content.isEmpty) {
        return const AiChatResult.error(
          'Assistant returned an empty response.',
        );
      }
      text = (content.first as Map<String, dynamic>)['text'] as String? ?? '';
      text = text.trim();
      if (text.isEmpty) {
        return const AiChatResult.error(
          'Assistant returned an empty response.',
        );
      }
    } catch (e) {
      debugPrint('AiChatService: parse error: $e');
      return const AiChatResult.error(
        'Couldn\'t read assistant response.',
      );
    }

    // Safety filter: if the model produced something that looks like a
    // load recipe in spite of the system prompt, refuse and replace.
    if (looksLikeLoadData(text)) {
      debugPrint(
        'AiChatService: safety filter tripped on response: $text',
      );
      // Burn the quota anyway — the user already paid the network cost
      // and a determined adversary shouldn't get free retries because
      // the model leaked. But we mark the message as an error so the
      // UI styles it accordingly.
      final usedAfter = await _incrementCount();
      return AiChatResult.success(
        message: const ChatMessage(
          role: 'assistant',
          content: kSafetyRefusal,
          isError: true,
        ),
        questionsUsedThisMonth: usedAfter,
      );
    }

    final usedAfter = await _incrementCount();
    return AiChatResult.success(
      message: ChatMessage(role: 'assistant', content: text),
      questionsUsedThisMonth: usedAfter,
    );
  }

  // ─────────────────────────── Output safety filter ───────────────────────────

  /// Powders frequently called out by reloaders. Lower-cased for matching.
  /// Not exhaustive — picked to cover the most-asked "what's a load of X
  /// for Y" queries. False negatives are acceptable here because the
  /// system prompt is the primary guard; this is just a backstop.
  static const List<String> _powderNames = [
    'h4350', 'h4831', 'h4831sc', 'h4895', 'h1000', 'h335', 'h322', 'h380',
    'h414', 'h450', 'h50bmg', 'h4198', 'h110',
    'varget', 'retumbo', 'benchmark', 'longshot', 'titegroup', 'titewad',
    'lil\'gun', 'lilgun', 'cfe pistol', 'cfe 223', 'cfe223', 'hp-38', 'hp38',
    'hs-6', 'hs6', 'bl-c(2)', 'bl-c', 'blc2', 'hybrid 100v',
    'imr 4064', 'imr4064', 'imr 4350', 'imr4350', 'imr 4895', 'imr4895',
    'imr 4198', 'imr 4451', 'imr4451', 'imr 4166', 'imr4166', 'imr 8208',
    'imr8208', 'imr 7977', 'imr7977', 'imr 4831', 'imr4831',
    'reloder', 'reloader', 'rl-15', 'rl15', 'rl-16', 'rl16', 'rl-17', 'rl17',
    'rl-19', 'rl19', 'rl-22', 'rl22', 'rl-23', 'rl23', 'rl-26', 'rl26',
    'unique', 'red dot', 'green dot', 'blue dot', 'bullseye', '2400',
    'autocomp', 'sport pistol', 'power pistol',
    'n130', 'n133', 'n135', 'n140', 'n150', 'n160', 'n165', 'n170', 'n540',
    'n550', 'n555', 'n560', 'n565', 'n568', 'n570', 'n105', 'n110', 'n320',
    'n330', 'n340', 'n350',
    'staball', 'staball 6.5', 'staball hd', 'staball match',
    'win 231', 'w231', 'w296', 'w748', 'w760', 'wsf', 'wst', 'wlp',
    'accurate 2200', 'accurate 2230', 'accurate 2460', 'accurate 2495',
    'accurate 2520', 'accurate 4064', 'accurate 4350', 'accurate 4831',
    'accurate magpro', 'accurate 1680', 'accurate no. 5', 'accurate no. 7',
    'accurate no. 9',
  ];

  /// Cartridge names commonly asked about. Lower-cased for matching.
  /// Same backstop philosophy as [_powderNames] — system prompt is primary.
  static const List<String> _cartridgeNames = [
    '6.5 creedmoor', '6mm creedmoor', '6.5 prc', '6.5 grendel', '6.5x55',
    '6mm br', '6 br', '6brx', '6 dasher', '6 gt',
    '.223 remington', '.223 rem', '223 remington', '223 rem', '223',
    '5.56 nato', '5.56x45', '5.56',
    '.308 winchester', '.308 win', '308 winchester', '308 win', '308',
    '7.62 nato', '7.62x51',
    '.30-06', '30-06', '30-06 springfield',
    '.270 winchester', '.270 win', '270 winchester', '270 win', '270',
    '.243 winchester', '.243 win', '243 winchester', '243 win', '243',
    '.22-250', '22-250', '.22-250 remington',
    '.220 swift', '220 swift',
    '.300 win mag', '300 win mag', '.300 winchester magnum',
    '.300 wsm', '300 wsm', '.300 prc', '300 prc', '.300 norma', '300 norma',
    '.338 lapua', '338 lapua', '.338 lapua magnum',
    '7mm rem mag', '7mm remington magnum', '7mm prc',
    '.50 bmg', '50 bmg',
    '9mm', '9x19', '9 luger', '.45 acp', '45 acp', '.40 s&w', '40 s&w',
    '.380 acp', '380 acp', '.357 magnum', '357 magnum', '.357 mag', '357 mag',
    '.44 magnum', '44 magnum', '.44 mag', '44 mag', '.38 special', '38 special',
    '.45-70', '45-70', '.45-70 government',
    '.222 remington', '.222 rem', '222 remington', '222 rem',
    '.204 ruger', '204 ruger',
    '.17 hmr', '17 hmr', '.17 hornet', '17 hornet',
    '.218 bee', '218 bee', '.22 hornet', '22 hornet',
    '6.8 spc', '6.8 western', '7-08', '7mm-08',
    '.260 remington', '.260 rem', '260 remington', '260 rem',
    '.350 legend', '350 legend',
    '.450 bushmaster', '450 bushmaster',
    '.25-06', '25-06', '.257 weatherby',
  ];

  /// Returns true if [text] looks like a specific reloading recipe. Used
  /// as the second-layer safety filter on model output.
  ///
  /// Heuristic: the text must contain BOTH a charge-weight pattern (an
  /// integer or decimal grain count) AND a known powder name AND a known
  /// cartridge name. Two of the three is not enough — we want to allow
  /// general talk like "Varget is a popular powder for the .308" without
  /// tripping.
  static bool looksLikeLoadData(String text) {
    final chargePattern = RegExp(
      r'\b\d{1,2}(?:\.\d{1,2})?\s*(?:gr\b|grains?\b)',
      caseSensitive: false,
    );
    if (!chargePattern.hasMatch(text)) return false;

    final lower = text.toLowerCase();
    final hasPowder = _powderNames.any((p) => lower.contains(p));
    if (!hasPowder) return false;

    final hasCartridge = _cartridgeNames.any((c) => lower.contains(c));
    if (!hasCartridge) return false;

    return true;
  }

  void dispose() {
    _client.close();
  }
}
