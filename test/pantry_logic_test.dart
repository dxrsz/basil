import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/features/pantry/pantry_logic.dart';
import 'package:lamars_groceries/features/tidy/tidy_logic.dart';
import 'package:lamars_groceries/models/models.dart';

final _t0 = DateTime(2026, 10, 1);

Item item(
  String id,
  String name, {
  String? qty,
  bool checked = false,
  List<String> recipeIds = const [],
  int minute = 0,
}) => Item(
  id: id,
  listId: 'L',
  name: name,
  quantity: qty,
  category: 'Other',
  checked: checked,
  checkedBy: null,
  recipeId: recipeIds.isEmpty ? null : recipeIds.first,
  recipeIds: recipeIds,
  createdAt: _t0.add(Duration(minutes: minute)),
);

PantryStaple staple(String name, {bool always = false, int daysAgo = 0, String? key}) => PantryStaple(
  id: name,
  listId: 'L',
  name: name,
  nameKey: key ?? name.toLowerCase(),
  always: always,
  confirmedAt: _t0.subtract(Duration(days: daysAgo)),
);

Recipe meal(List<Ingredient> ingredients) => Recipe(
  id: 'R',
  listId: 'L',
  name: 'Taco bowls',
  imageUrl: null,
  imageStatus: ImageStatus.idle,
  createdAt: _t0,
  ingredients: ingredients,
);

void main() {
  group('isPantryStaple', () {
    for (final name in [
      'Olive oil',
      'extra virgin olive oil',
      'Salt',
      'Kosher salt',
      'Soy sauce',
      'All-purpose flour',
      'Brown sugar',
      'Jasmine rice',
      'Ground cumin',
      'Smoked paprika',
      'Garlic powder',
      'Red pepper flakes',
      'Black pepper',
      'Pepper',
      'Dijon mustard',
      'Honey',
      'Bay leaves',
      'Taco seasoning',
    ]) {
      test('$name is a staple', () => expect(isPantryStaple(name), isTrue));
    }
    for (final name in [
      'Bell pepper',
      'Red bell peppers',
      'Jalapeño pepper',
      'Flour tortillas',
      'Rice noodles',
      'Chicken thighs',
      'Avocado',
      'Sparkling water',
      'Sugar snap peas',
      'Oil-packed tuna',
      '',
    ]) {
      test('$name is not a staple', () => expect(isPantryStaple(name), isFalse));
    }
  });

  group('guessPantry', () {
    test('pinned staples are always had', () {
      final g = guessPantry('Ghee', {'ghee': staple('Ghee', always: true, daysAgo: 400)}, _t0);
      expect((g.have, g.reason), (true, PantryReason.always));
    });
    test('recent answers are trusted', () {
      final g = guessPantry('Tortilla chips', {'tortilla chip': staple('Tortilla chips', daysAgo: 3)}, _t0);
      expect((g.have, g.reason), (true, PantryReason.remembered));
    });
    test('answers older than 30 days are asked again', () {
      final g = guessPantry('Tortilla chips', {'tortilla chip': staple('Tortilla chips', daysAgo: 31)}, _t0);
      expect((g.have, g.reason), (false, PantryReason.stale));
    });
    test('stale memory of a curated staple falls back to the staple', () {
      final g = guessPantry('Olive oil', {'olive oil': staple('Olive oil', daysAgo: 90)}, _t0);
      expect((g.have, g.reason), (true, PantryReason.staple));
    });
    test('unknown things are added', () {
      final g = guessPantry('Cilantro', const {}, _t0);
      expect((g.have, g.reason), (false, PantryReason.none));
    });
  });

  group('buildMealReview', () {
    final ingredients = [
      const Ingredient(name: 'Olive oil', quantity: '2 tbsp'),
      const Ingredient(name: 'Avocados', quantity: '2'),
      const Ingredient(name: 'Rice', quantity: '1 cup'),
      const Ingredient(name: 'rice', quantity: '1 cup'),
      const Ingredient(name: 'Cilantro', quantity: '1 bunch'),
      const Ingredient(name: 'Limes'),
      const Ingredient(name: 'Corn'),
      const Ingredient(name: 'Tortilla chips'),
    ];

    test('pre-marks staples and remembered items, merges with the list, asks about cart items', () {
      final rows = buildMealReview(
        recipe: meal(ingredients),
        items: [
          item('1', 'Avocado', qty: '1'), // on the list → merges
          item('2', 'Lime', checked: true), // only in the cart → asked about (gets a fresh item)
          item('3', 'Corn', recipeIds: ['R']), // already from this meal → skipped
        ],
        pantry: [staple('Tortilla chips', key: 'tortilla chip', daysAgo: 2)],
        now: _t0,
      );
      expect([for (final r in rows) r.name], ['Olive oil', 'Avocados', 'Rice', 'Cilantro', 'Limes', 'Tortilla chips']);
      final by = {for (final r in rows) r.name: r};
      expect(by['Olive oil']!.add, isFalse);
      expect(by['Rice']!.add, isFalse); // a staple
      expect(by['Rice']!.quantity, '2 cups'); // duplicate lines combined
      expect(by['Tortilla chips']!.add, isFalse);
      expect(by['Cilantro']!.add, isTrue);
      expect(by['Avocados']!.add, isTrue);
      expect(by['Avocados']!.onList?.id, '1');
      expect(by['Avocados']!.combined, '3');
      // Already in the cart: the meal needs its own, so it defaults to add (as a new item).
      expect(by['Limes']!.add, isTrue);
      expect(by['Limes']!.onList, isNull);
    });

    test('items on the list default to add even when they look like staples', () {
      final rows = buildMealReview(
        recipe: meal([const Ingredient(name: 'Olive oil', quantity: '1 bottle')]),
        items: [item('1', 'olive oil')],
        pantry: const [],
        now: _t0,
      );
      expect(rows.single.add, isTrue);
    });

    test('empty when everything is handled', () {
      expect(
        buildMealReview(
          recipe: meal([const Ingredient(name: 'Corn')]),
          items: [
            item('1', 'Corn', recipeIds: ['R']),
          ],
          pantry: const [],
          now: _t0,
        ),
        isEmpty,
      );
    });
  });

  group('reviewAnswers', () {
    test('skips and remembers got-its, forgets flipped memories', () {
      final rows = buildMealReview(
        recipe: meal(const [
          Ingredient(name: 'Olive oil'),
          Ingredient(name: 'Cilantro'),
          Ingredient(name: 'Tortilla chips'),
          Ingredient(name: 'Salsa'),
        ]),
        items: const [],
        pantry: [staple('Tortilla chips', key: 'tortilla chip', daysAgo: 2)],
        now: _t0,
      );
      final by = {for (final r in rows) r.name: r};
      by['Cilantro']!.add = false; // "we have cilantro"
      by['Tortilla chips']!.add = true; // "we're out"
      final a = reviewAnswers(rows);
      expect(a.skip, ['Olive oil', 'Cilantro']);
      expect(a.have, ['Cilantro']); // olive oil is a curated staple; no need to remember it
      expect(a.forget, ['Tortilla chips']);
    });
  });

  group('tidy', () {
    test('exact duplicates merge into the oldest, combining quantities', () {
      final proposals = exactDuplicateProposals([
        item('b', 'avocados', qty: '2', minute: 2),
        item('a', 'Avocado', qty: '1', minute: 1),
        item('c', 'Rice', qty: '1 cup'),
        item('d', 'rice', qty: '2 cups', checked: true),
        item('e', 'AVOCADO', minute: 3),
      ]);
      expect(proposals, hasLength(1));
      expect(proposals.single.itemIds, ['a', 'b', 'e']);
      expect(proposals.single.name, 'Avocado');
      expect(proposals.single.quantity, '3');
      expect(proposals.single.reason, 'On the list 3 times');
    });

    test('AI proposals overlapping local ones or stale items are dropped', () {
      final items = [item('a', 'Avocado'), item('b', 'avocados'), item('c', 'Chicken'), item('d', 'Chicken thighs')];
      final local = exactDuplicateProposals(items);
      TidyProposal ai(List<String> ids) =>
          TidyProposal(kind: 'merge', itemIds: ids, name: 'x', quantity: null, reason: '');
      final all = combineProposals(local, [
        ai(['a', 'c']),
        ai(['c', 'd']),
        ai(['d', 'zzz']),
      ], items);
      expect(
        [for (final p in all) p.itemIds],
        [
          ['a', 'b'],
          ['c', 'd'],
        ],
      );
    });

    test('toChange keeps the first item', () {
      const p = TidyProposal(kind: 'merge', itemIds: ['k', 'r1', 'r2'], name: 'N', quantity: null, reason: '');
      expect(p.toChange(), {
        'keep_id': 'k',
        'remove_ids': ['r1', 'r2'],
        'name': 'N',
        'quantity': null,
      });
    });
  });
}
