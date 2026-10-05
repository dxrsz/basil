import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/util/item_merge.dart';

void main() {
  // The same vectors are run against the SQL mirror by tool/pantry_tidy_check.dart.
  final cases = jsonDecode(File('test/fixtures/item_merge_cases.json').readAsStringSync()) as Map<String, dynamic>;

  group('normalizeItemName', () {
    for (final c in (cases['names'] as List).cast<List>()) {
      test('"${c[0]}" → "${c[1]}"', () => expect(normalizeItemName(c[0] as String), c[1]));
    }

    test('singular and plural match', () {
      expect(normalizeItemName('Avocado'), normalizeItemName('avocados'));
      expect(normalizeItemName('Tomato'), normalizeItemName('TOMATOES'));
      expect(normalizeItemName('lime'), isNot(normalizeItemName('lemon')));
    });
  });

  group('combineQuantities', () {
    for (final c in (cases['combine'] as List).cast<List>()) {
      test('${jsonEncode(c[0])} + ${jsonEncode(c[1])} → ${jsonEncode(c[2])}', () {
        expect(combineQuantities(c[0] as String?, c[1] as String?), c[2]);
      });
    }

    test('chains', () {
      var q = combineQuantities('1 cup', '1 cup');
      q = combineQuantities(q, '1 bunch');
      q = combineQuantities(q, '½ cup');
      expect(q, '2½ cups + 1 bunch');
    });
  });

  group('formatAmount', () {
    test('whole, glyphs, decimals', () {
      expect(formatAmount(3), '3');
      expect(formatAmount(2.999), '3');
      expect(formatAmount(0.5), '½');
      expect(formatAmount(1.25), '1¼');
      expect(formatAmount(1 / 3), '⅓');
      expect(formatAmount(1.2), '1.2');
      expect(formatAmount(0.125), '0.13');
    });
  });
}
