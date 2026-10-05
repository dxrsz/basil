import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/features/pantry/add_meal_flow.dart';
import 'package:lamars_groceries/features/pantry/pantry_data.dart';
import 'package:lamars_groceries/features/pantry/pantry_logic.dart';
import 'package:lamars_groceries/features/pantry/pantry_sheet.dart';
import 'package:lamars_groceries/features/tidy/tidy_sheet.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';

final _now = DateTime.now();

Item _item(String id, String name, String? qty) => Item(
  id: id,
  listId: 'L',
  name: name,
  quantity: qty,
  category: 'Other',
  checked: false,
  checkedBy: null,
  recipeId: null,
  createdAt: _now,
);

/// Opens [sheet] as a modal bottom sheet, like the app does.
Future<void> _pumpSheet(
  WidgetTester tester,
  Size size,
  double textScale,
  Widget sheet, {
  List overrides = const [],
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...overrides],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => sheet,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

List<MealReviewRow> _rows() => buildMealReview(
  recipe: Recipe(
    id: 'R',
    listId: 'L',
    name: 'Extremely long-named weeknight chicken taco rice bowls with all the fixings',
    imageUrl: null,
    imageStatus: ImageStatus.idle,
    createdAt: _now,
    ingredients: [
      for (final (i, (n, q)) in [
        ('Extra virgin olive oil', '2 tbsp'),
        ('Boneless skinless chicken thighs', '2 lb'),
        ('Avocados', '2'),
        ('Jasmine rice', '2 cups'),
        ('Cilantro', '1 bunch'),
        ('Limes', '3'),
        ('Ground cumin', '1 tsp'),
        ('Smoked paprika', '1 tsp'),
        ('Kosher salt', null),
        ('Black beans', '2 cans'),
        ('Tortilla chips', '1 bag'),
        ('Sour cream', '1 tub'),
        ('Pickled red onion', '1 jar'),
        ('Cotija cheese', '4 oz'),
      ].indexed)
        Ingredient(name: n, quantity: q, position: i),
    ],
  ),
  items: [_item('1', 'Avocado', '1 large')],
  pantry: [
    PantryStaple(
      id: 'p',
      listId: 'L',
      name: 'Tortilla chips',
      nameKey: 'tortilla chip',
      always: false,
      confirmedAt: _now.subtract(const Duration(days: 3)),
    ),
  ],
  now: _now,
);

void main() {
  for (final (size, textScale) in [(const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
    testWidgets('"Got this already?" fits at $size, text ×$textScale, and flips items', (tester) async {
      final rows = _rows();
      await _pumpSheet(tester, size, textScale, MealReviewSheet(mealName: 'Taco bowls', rows: rows));
      expect(tester.takeException(), isNull);
      expect(find.text('Got this already?'), findsOneWidget);

      final adding = rows.where((r) => r.add).length;
      expect(find.text('Add $adding to the list'), findsOneWidget);
      // Olive oil is pre-marked "Got it"; flip it.
      expect(rows.firstWhere((r) => r.name == 'Extra virgin olive oil').add, isFalse);
      await tester.scrollUntilVisible(
        find.text('Extra virgin olive oil'),
        100,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extra virgin olive oil'));
      await tester.pump();
      expect(rows.firstWhere((r) => r.name == 'Extra virgin olive oil').add, isTrue);
      expect(find.text('Add ${adding + 1} to the list'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tidy up fits at $size, text ×$textScale', (tester) async {
      final items = [
        _item('a', 'Avocado', '1'),
        _item('b', 'avocados', '2'),
        _item('c', 'Chicken', '2 lb'),
        _item('d', 'Boneless skinless chicken thighs from the good butcher', '1 lb'),
        _item('e', 'Tomatos', null),
      ];
      await _pumpSheet(
        tester,
        size,
        textScale,
        TidySheet(
          listId: 'L',
          askLamar: () async => const [
            TidyProposal(
              kind: 'merge',
              itemIds: ['c', 'd'],
              name: 'Boneless skinless chicken thighs from the good butcher',
              quantity: '3 lb',
              reason: 'Same chicken, listed twice',
            ),
            TidyProposal(kind: 'fix', itemIds: ['e'], name: 'Tomatoes', quantity: null, reason: 'Spelling'),
          ],
        ),
        overrides: [itemsProvider('L').overrideWith((ref) => Stream.value(items))],
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('Apply all 3'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Tomatoes'),
        100,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomatoes'));
      await tester.pump();
      expect(find.text('Apply 2'), findsOneWidget);
    });

    testWidgets('Pantry sheet fits at $size, text ×$textScale', (tester) async {
      await _pumpSheet(
        tester,
        size,
        textScale,
        const PantrySheet(listId: 'L'),
        overrides: [
          pantryProvider('L').overrideWith(
            (ref) => Stream.value([
              PantryStaple(
                id: '1',
                listId: 'L',
                name: 'Ghee',
                nameKey: 'ghee',
                always: true,
                confirmedAt: _now.subtract(const Duration(days: 100)),
              ),
              PantryStaple(
                id: '2',
                listId: 'L',
                name: 'A really quite long pantry item name for testing',
                nameKey: 'a really quite long pantry item name for testing',
                always: false,
                confirmedAt: _now.subtract(const Duration(days: 45)),
              ),
            ]),
          ),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Always have'), findsOneWidget);
      expect(find.textContaining('Lamar will ask again'), findsOneWidget);
    });
  }
}
