// FILE: test/recipe_parser_test.dart
//
// Unit tests for `lib/services/recipe_parser.dart`. The parser is the
// only photo-import stage that's reasonable to test without a device —
// the OCR stage's output is non-deterministic in handwriting. The
// tests exercise the parser with synthetic strings that look like what
// ML Kit returns for a notebook page, with the device's reference
// catalog injected as the parser's constructor inputs.
//
// These tests deliberately don't open the database — `RecipeParser` is
// pure and should stay that way.

import 'package:flutter_test/flutter_test.dart';
import 'package:loadout/services/recipe_parser.dart';

void main() {
  group('RecipeParser', () {
    final parser = RecipeParser(
      cartridgeAliases: {
        '6.5 Creedmoor': const ['6.5 CM', '6.5 Creed', '6.5CM'],
        '.308 Winchester': const ['308 Win', '7.62x51mm NATO'],
        '6mm Creedmoor': const ['6CM', '6 Creed'],
      },
      powderNames: const [
        'H4350',
        'H4831SC',
        'IMR4350',
        'IMR4451',
        'Varget',
        'RL16',
        'N140',
        'CFE223',
      ],
      bulletLines: const [
        BulletCatalogEntry(
          manufacturer: 'Hornady',
          line: 'ELD Match',
          weightGr: 140,
        ),
        BulletCatalogEntry(
          manufacturer: 'Hornady',
          line: 'ELD-X',
          weightGr: 143,
        ),
        BulletCatalogEntry(
          manufacturer: 'Berger',
          line: 'Hybrid',
          weightGr: 105,
        ),
        BulletCatalogEntry(
          manufacturer: 'Sierra',
          line: 'MatchKing',
          weightGr: 175,
        ),
      ],
      primerNames: const [
        'Federal #210M',
        'Federal #205M',
        'CCI #BR2',
        'CCI #450',
      ],
      brassNames: const ['Lapua', 'Hornady', 'Lake City', 'Starline'],
    );

    test('extracts caliber, powder, charge, bullet, weight, COAL', () {
      // Mirrors the example in the task spec.
      final raw = '6.5 CM Match\nH4350 41.5 gr\n140 ELDM\nCOAL 2.825';
      final draft = parser.parse(raw);

      expect(draft.caliber?.value, '6.5 Creedmoor');
      expect(draft.caliber!.confidence, greaterThanOrEqualTo(0.75));

      expect(draft.powder?.value, contains('H4350'));
      expect(draft.powder!.confidence, greaterThanOrEqualTo(0.75));

      expect(draft.powderChargeGr?.value, 41.5);
      expect(draft.powderChargeGr!.confidence, greaterThanOrEqualTo(0.5));

      expect(draft.bulletWeightGr?.value, 140);

      expect(draft.coalIn?.value, 2.825);
      expect(draft.coalIn!.confidence, greaterThanOrEqualTo(0.5));
    });

    test('matches an alias even when the canonical name is missing', () {
      final raw = '308 Win\nVarget 44.0 gr\n175 SMK\nCOAL 2.800';
      final draft = parser.parse(raw);
      expect(draft.caliber?.value, '.308 Winchester');
      expect(draft.powder?.value, 'Varget');
      expect(draft.powderChargeGr?.value, 44.0);
      expect(draft.bulletWeightGr?.value, 175);
      expect(draft.coalIn?.value, 2.800);
    });

    test('disambiguates bullet weight from powder charge by range', () {
      // "140" right next to ELDM is the bullet weight; "41.5" with "gr"
      // is the powder charge.
      final raw = 'H4350 41.5gr\n140gr ELDM';
      final draft = parser.parse(raw);
      expect(draft.powderChargeGr?.value, 41.5);
      expect(draft.bulletWeightGr?.value, 140);
    });

    test('finds CBTO when keyword is present', () {
      final raw = '6.5 Creedmoor\nH4350 41.7 gr\n140 ELDM\nCBTO 2.250';
      final draft = parser.parse(raw);
      expect(draft.cbtoIn?.value, 2.250);
    });

    test('finds primer from catalog hit', () {
      final raw = '6.5 Creedmoor H4350 41.5 gr\nFederal #210M primer\nLapua brass';
      final draft = parser.parse(raw);
      expect(draft.primer?.value, 'Federal #210M');
      expect(draft.brass?.value, 'Lapua');
    });

    test('returns null fields when nothing matches', () {
      final draft = parser.parse('asdf qwer\nrandom garbage');
      expect(draft.caliber, isNull);
      expect(draft.powder, isNull);
      expect(draft.powderChargeGr, isNull);
      expect(draft.bulletWeightGr, isNull);
      expect(draft.coalIn, isNull);
    });

    test('produces a fallback recipe name when none is found', () {
      final raw = 'H4350 41.5 gr\n140 gr\nCOAL 2.825\n6.5 Creedmoor';
      final draft = parser.parse(raw);
      expect(draft.recipeName, isNotNull);
      expect(draft.recipeName, isNotEmpty);
    });

    test('preserves OCR text in notes', () {
      final raw = '6.5 Creedmoor\nH4350 41.5 gr\n140 ELDM';
      final draft = parser.parse(raw);
      expect(draft.notes, contains('6.5 Creedmoor'));
      expect(draft.notes, contains('H4350'));
    });

    test('confidence is high for exact catalog hits', () {
      final raw = 'Cartridge: 6.5 Creedmoor\nPowder: H4350\nCharge: 41.5 gr';
      final draft = parser.parse(raw);
      // Both caliber and powder are direct catalog matches.
      expect(draft.caliber!.confidence, 0.95);
      expect(draft.powder!.confidence, 0.95);
    });

    test('handles "grain" spelled out next to the charge', () {
      final raw = '6.5 Creedmoor\nH4350 41.5 grain\n140 ELDM';
      final draft = parser.parse(raw);
      expect(draft.powderChargeGr?.value, 41.5);
    });

    test('rejects out-of-range powder charges', () {
      // 200 gr is outside the 5-80 powder-charge range — should be
      // ignored as a powder charge but still detected as a bullet
      // weight (200 is in the 30-250 bullet range).
      final raw = '200 gr\n6.5 Creedmoor\nH4350';
      final draft = parser.parse(raw);
      expect(draft.powderChargeGr, isNull);
      expect(draft.bulletWeightGr?.value, 200);
    });
  });
}
