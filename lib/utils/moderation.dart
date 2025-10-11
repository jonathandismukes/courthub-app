class ModerationResult {
  final String cleanedText;
  final bool containsProfanity;
  final bool looksLikeSpam;
  final List<String> flaggedKeywords;

  const ModerationResult({
    required this.cleanedText,
    this.containsProfanity = false,
    this.looksLikeSpam = false,
    this.flaggedKeywords = const [],
  });
}

/// Lightweight client-side moderation helpers for profanity censoring and basic spam/keyword checks.
class Moderation {
  // Keep short and neutral. Server-side rules should ultimately enforce policy.
  static final Set<String> _banned = {
    // Keep minimal sample list; extend server-side if needed
    'damn', 'hell', 'shit', 'fuck', 'bitch', 'asshole', 'bastard'
  };

  static final Set<String> _flagKeywords = {
    'hate', 'kill', 'suicide', 'bomb', 'terror', 'harass', 'bully'
  };

  /// Replace profanity with **** preserving word boundaries.
  static String censorProfanity(String input) {
    if (input.isEmpty) return input;
    final words = input.split(RegExp(r'(\s+)'));
    return words.map((token) {
      final lower = token.toLowerCase();
      final stripped = lower.replaceAll(RegExp(r'[^a-z]'), '');
      if (_banned.contains(stripped)) {
        return token.replaceAll(RegExp(r'\S'), '*');
      }
      return token;
    }).join('');
  }

  /// Very basic spam heuristics: long repeated characters, many URLs, or excessive emojis.
  static bool isSpam(String input) {
    if (input.length > 500) return true;
    if (RegExp(r'(http[s]?:\/\/)', caseSensitive: false).allMatches(input).length > 2) return true;
    if (RegExp(r'(.)\1{6,}') .hasMatch(input)) return true; // char repeated 7+ times
    if (RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true).allMatches(input).length > 30) return true;
    return false;
  }

  static List<String> findFlaggedKeywords(String input) {
    final lower = input.toLowerCase();
    return _flagKeywords.where((k) => lower.contains(k)).toList();
  }

  static ModerationResult process(String input) {
    final cleaned = censorProfanity(input);
    return ModerationResult(
      cleanedText: cleaned,
      containsProfanity: cleaned != input,
      looksLikeSpam: isSpam(input),
      flaggedKeywords: findFlaggedKeywords(input),
    );
  }
}
