// FILE: lib/utils/natural_sort.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Provides `naturalCompare(a, b)` — a `Comparator<String>` that orders
// strings the way humans expect when those strings contain embedded
// numbers. Plain `String.compareTo` is **lexicographic** (character by
// character), which puts `"10mm"` BEFORE `"2mm"` because the character
// `'1'` sorts before `'2'`. Reloaders read those caliber sequences as
// numbers (`2 < 10`), so we need a comparator that does too.
//
// The algorithm:
//
//   1. Strip a leading `'.'` from each string. Cartridge names like
//      `".22 LR"` and `".308 Win"` should sort by their numeric value
//      (`22` and `308`) rather than have the dot pull them ahead of every
//      letter. After stripping, ".22 LR" sorts as if "22 LR".
//
//   2. Tokenize the rest of each string into ordered chunks. A chunk is
//      either a numeric run (digits, optionally with a single decimal
//      point — so "6.5" parses as one chunk of value 6.5) or a non-numeric
//      run.
//
//   3. Walk the two chunk lists in lock-step. Compare each pair:
//        - number vs number   → numeric `compareTo`
//        - number vs text     → number wins (numbers come before text)
//        - text vs number     → number wins
//        - text vs text       → case-insensitive lexicographic
//      First non-zero result decides.
//
//   4. If one list ran out before the other, the shorter list is "less".
//      So `"6mm"` < `"6mm Match"`.
//
// Examples (sort ascending):
//   .22 LR
//   5.56 NATO
//   6mm Creedmoor
//   6.5 Creedmoor
//   8mm Mauser
//   9mm Luger
//   10mm Auto
//   .30-06 Springfield
//   .30-30 Winchester
//   .308 Winchester
//   .357 Magnum
//   GM205M
//   GM215M
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Every list of catalog entries the user sees in a dropdown — cartridges,
// powders, bullets, primers, brass, firearms — should sort in caliber-
// number order, not in ASCII order. Without this comparator we'd need
// either (a) custom sort keys baked into every JSON entry, or (b) a
// dozen one-off sorts in each repository / screen, both of which drift
// from each other. This one shared helper means every dropdown sorts the
// same way for free.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// 1. LEADING-DOT CARTRIDGES. SAAMI imperial nomenclature prefixes the
//    bore diameter with a dot (".22 LR", ".308 Win"). Without the dot
//    strip these would sort to the very top of any list because `'.'` is
//    ASCII 0x2E, before every letter. Stripping the leading dot makes
//    them interleave naturally with metric calibers ("6mm", "8mm",
//    "9mm").
// 2. DECIMAL NUMBERS. "6mm Creedmoor" vs "6.5 Creedmoor" — the chunker
//    has to recognize "6.5" as a single number, not "6", ".", "5". The
//    regex `(\d+(?:\.\d+)?)` greedily captures one decimal segment.
// 3. NUMBER vs TEXT MIXED CHUNKS. "9mm Luger" starts with a number, but
//    "Federal #205M" starts with text. Plain `String.compareTo` would
//    interleave them in a way that depends on ASCII codes; the rule
//    "numbers come before text at the same chunk position" matches what
//    users expect from caliber lists.
// 4. CASE-INSENSITIVITY. Brand names like `"federal"` vs `"Federal"`
//    would otherwise sort apart because `'F' < 'f'` in ASCII. We
//    `toLowerCase()` text chunks before comparison so case doesn't
//    matter for ordering, but we don't rewrite the original strings —
//    callers still see the original case.
// 5. EMPTY STRINGS / NULL-SAFETY. Both inputs are required `String`s.
//    Pass empty strings if your data may be null and you want them to
//    sort to the top.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - lib/repositories/component_repository.dart — every list method that
//   feeds a dropdown post-sorts with `naturalCompare`.
// - lib/screens/saami/saami_screen.dart — cartridge picker list.
// - lib/screens/ballistics/ballistics_screen.dart — bullet + rifle picker
//   autocompletes.
// - lib/screens/firearms/firearms_list_screen.dart — user firearm list.
// - lib/repositories/firearm_repository.dart — firearm list query.
// - Anywhere else a list of catalog labels gets shown in alphabetical
//   order to the user.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None. Pure functions. Stateless.

/// Regex that matches one chunk: either a (possibly decimal) number or a
/// run of non-digit characters. Anchored as a *non-capturing* group inside
/// an alternation so each match returns exactly one chunk.
final RegExp _chunkPattern = RegExp(r'\d+(?:\.\d+)?|[^\d]+');

/// A parsed chunk of a string — either a numeric value or a text run.
class _Chunk {
  const _Chunk.number(this.numericValue)
      : isNumber = true,
        textValue = '';
  const _Chunk.text(this.textValue)
      : isNumber = false,
        numericValue = 0;

  final bool isNumber;
  final double numericValue;
  final String textValue;
}

List<_Chunk> _tokenize(String input) {
  // Strip exactly one leading dot — common SAAMI nomenclature for imperial
  // bore-diameter names (".22 LR", ".308 Win", ".357 Magnum"). Without
  // this strip, those names would sort to the very top of the list.
  final stripped = input.startsWith('.') ? input.substring(1) : input;
  final out = <_Chunk>[];
  for (final match in _chunkPattern.allMatches(stripped)) {
    final piece = match.group(0)!;
    final numeric = double.tryParse(piece);
    if (numeric != null) {
      out.add(_Chunk.number(numeric));
    } else {
      out.add(_Chunk.text(piece));
    }
  }
  return out;
}

/// Compares two strings using natural ordering — embedded numeric runs
/// are compared numerically, text runs case-insensitively, leading dots
/// in cartridge names are ignored for ordering.
///
/// Returns negative if `a` sorts before `b`, positive if after, zero if
/// equal. Suitable as a `Comparator<String>` for `List.sort` /
/// `Iterable.toList()..sort(naturalCompare)`.
int naturalCompare(String a, String b) {
  if (identical(a, b)) return 0;
  final aChunks = _tokenize(a);
  final bChunks = _tokenize(b);
  final shorter = aChunks.length < bChunks.length ? aChunks.length : bChunks.length;
  for (var i = 0; i < shorter; i++) {
    final ac = aChunks[i];
    final bc = bChunks[i];
    if (ac.isNumber && bc.isNumber) {
      final cmp = ac.numericValue.compareTo(bc.numericValue);
      if (cmp != 0) return cmp;
    } else if (ac.isNumber) {
      // Numbers sort before text at the same chunk position.
      return -1;
    } else if (bc.isNumber) {
      return 1;
    } else {
      final cmp = ac.textValue.toLowerCase().compareTo(bc.textValue.toLowerCase());
      if (cmp != 0) return cmp;
    }
  }
  // All shared chunks were equal — the shorter run sorts first.
  return aChunks.length.compareTo(bChunks.length);
}
