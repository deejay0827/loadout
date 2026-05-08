// FILE: test/handwriting_aliases_test.dart
//
// Unit tests for `lib/data/handwriting_aliases.dart`. Locks the
// dictionary shape (so accidental key edits don't drop a row) and
// exercises the `expandHandwritingTokens` walker plus the
// `parseHandwrittenCharge` mixed-fraction parser.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/data/handwriting_aliases.dart';

void main() {
  group('handwriting alias dictionaries', () {
    test('powder map covers 50+ entries', () {
      expect(kPowderHandwritingAliases.length, greaterThanOrEqualTo(50));
    });
    test('bullet map covers 50+ entries', () {
      expect(kBulletHandwritingAliases.length, greaterThanOrEqualTo(50));
    });
    test('caliber map covers 50+ entries', () {
      expect(kCaliberHandwritingAliases.length, greaterThanOrEqualTo(50));
    });

    test('canonicalPowderName resolves common shorthand', () {
      expect(canonicalPowderName('H4350'), 'H4350');
      expect(canonicalPowderName('h 4350'), 'H4350');
      expect(canonicalPowderName('Hodgdon 4350'), 'H4350');
      expect(canonicalPowderName('RL16'), 'Reloder 16');
      expect(canonicalPowderName('R-L 16'), 'Reloder 16');
      expect(canonicalPowderName('Reloder 16'), 'Reloder 16');
      expect(canonicalPowderName('N140'), 'N140');
      expect(canonicalPowderName('Vihtavuori N140'), 'N140');
      expect(canonicalPowderName('VV N140'), 'N140');
    });

    test('canonicalBulletLine resolves common shorthand', () {
      expect(canonicalBulletLine('ELDM'), 'ELD-M');
      expect(canonicalBulletLine('ELD-M'), 'ELD-M');
      expect(canonicalBulletLine('eld m'), 'ELD-M');
      expect(canonicalBulletLine('SMK'), 'MatchKing');
      expect(canonicalBulletLine('TMK'), 'Tipped MatchKing');
      expect(canonicalBulletLine('VLD'), 'VLD');
      expect(canonicalBulletLine('Hyb'), 'Hybrid');
      expect(canonicalBulletLine('A-Tip'), 'A-Tip');
    });

    test('canonicalCaliberName resolves common shorthand', () {
      expect(canonicalCaliberName('.308'), '.308 Winchester');
      expect(canonicalCaliberName('308'), '.308 Winchester');
      expect(canonicalCaliberName('308 Win'), '.308 Winchester');
      expect(canonicalCaliberName('7.62 NATO'), '7.62x51mm NATO');
      expect(canonicalCaliberName('6.5 CM'), '6.5 Creedmoor');
      expect(canonicalCaliberName('6.5 Creedmoor'), '6.5 Creedmoor');
      expect(canonicalCaliberName('6mm Creed'), '6mm Creedmoor');
      expect(canonicalCaliberName('5.56'), '5.56x45mm NATO');
      expect(canonicalCaliberName('300 BLK'), '.300 AAC Blackout');
    });

    test('whitespace and case are normalized before lookup', () {
      expect(canonicalPowderName('  h4350  '), 'H4350');
      expect(canonicalPowderName('h  4350'), 'H4350');
      expect(canonicalPowderName('H4350'), 'H4350');
      expect(canonicalPowderName('HODGDON 4350'), 'H4350');
    });
  });

  group('parseHandwrittenCharge', () {
    test('parses plain decimal', () {
      expect(parseHandwrittenCharge('41.5'), 41.5);
      expect(parseHandwrittenCharge('44'), 44);
      expect(parseHandwrittenCharge('150'), 150);
    });

    test('parses comma decimal (European)', () {
      expect(parseHandwrittenCharge('41,5'), 41.5);
    });

    test('parses mixed fraction with whitespace', () {
      expect(parseHandwrittenCharge('41 1/2'), 41.5);
      expect(parseHandwrittenCharge('40 3/4'), 40.75);
    });

    test('parses mixed fraction with hyphen', () {
      expect(parseHandwrittenCharge('41-1/2'), 41.5);
      expect(parseHandwrittenCharge('40-3/4'), 40.75);
    });

    test('parses bare fraction', () {
      expect(parseHandwrittenCharge('1/2'), 0.5);
      expect(parseHandwrittenCharge('3/4'), 0.75);
    });

    test('parses vulgar-fraction glyphs', () {
      expect(parseHandwrittenCharge('41½'), 41.5);
      expect(parseHandwrittenCharge('41¼'), 41.25);
      expect(parseHandwrittenCharge('41¾'), 41.75);
      expect(parseHandwrittenCharge('½'), 0.5);
    });

    test('returns null for garbage', () {
      expect(parseHandwrittenCharge('abc'), null);
      expect(parseHandwrittenCharge(''), null);
      expect(parseHandwrittenCharge('41/0'), null); // div-by-zero
    });
  });

  group('expandHandwritingTokens', () {
    test('finds powder + caliber + bullet on one notebook line', () {
      final r = expandHandwritingTokens('308 Win H4350 41.5 gr SMK');
      expect(r.calibers, contains('.308 Winchester'));
      expect(r.powders, contains('H4350'));
      expect(r.bullets, contains('MatchKing'));
    });

    test('returns canonical names for shorthand', () {
      final r = expandHandwritingTokens('6.5 CM RL16 41.5 ELDM');
      expect(r.calibers, contains('6.5 Creedmoor'));
      expect(r.powders, contains('Reloder 16'));
      expect(r.bullets, contains('ELD-M'));
    });

    test('handles multi-token canonical names', () {
      final r = expandHandwritingTokens('Reloder 16 charges nicely');
      expect(r.powders, contains('Reloder 16'));
    });

    test('empty string returns empty result', () {
      final r = expandHandwritingTokens('');
      expect(r.powders, isEmpty);
      expect(r.bullets, isEmpty);
      expect(r.calibers, isEmpty);
    });
  });
}
