import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/import_repository.dart';
import 'package:lamars_groceries/features/import/import_review_sheet.dart';
import 'package:lamars_groceries/theme.dart';

const _listResult = ImportResult(
  kind: ImportKind.list,
  items: [
    ImportedItem(name: 'Chicken thighs', quantity: '2 lb'),
    ImportedItem(name: 'Milk'),
    ImportedItem(name: 'Eggs', quantity: '1 dozen'),
    ImportedItem(name: 'Bananas'),
    ImportedItem(name: 'Shredded extra-sharp white cheddar cheese', quantity: '2 bags'),
    ImportedItem(name: 'Black beans', quantity: '3 cans'),
    ImportedItem(name: 'Tortillas'),
    ImportedItem(name: 'Coffee'),
    ImportedItem(name: 'Apples', quantity: '6'),
    ImportedItem(name: 'Oat milk', quantity: '2 cartons'),
    ImportedItem(name: 'Sourdough bread'),
    ImportedItem(name: 'Paper towels'),
  ],
);

const _recipeResult = ImportResult(
  kind: ImportKind.recipe,
  mealName: 'Grandma\'s Banana Bread',
  url: 'https://www.example.com/banana-bread',
  items: [
    ImportedItem(name: 'Bananas', quantity: '3'),
    ImportedItem(name: 'Butter', quantity: '1/3 cup'),
    ImportedItem(name: 'Flour', quantity: '1 1/2 cups'),
  ],
);

const _pantryResult = ImportResult(
  kind: ImportKind.pantry,
  items: [
    ImportedItem(name: 'Milk', low: true),
    ImportedItem(name: 'Eggs'),
    ImportedItem(name: 'Cheddar'),
    ImportedItem(name: 'Orange juice', low: true),
  ],
);

/// Pumps a button that opens the real review sheet and records what it returns.
Future<List<ImportDecision?>> _open(
  WidgetTester tester,
  ImportResult result, {
  ImportTarget target = ImportTarget.shopping,
  Size size = const Size(360, 640),
  double textScale = 1.3,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final popped = <ImportDecision?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async => popped.add(await showImportReview(context, result, target)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return popped;
}

void main() {
  for (final (size, textScale) in [(const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
    for (final (label, result, target) in [
      ('list', _listResult, ImportTarget.shopping),
      ('recipe', _recipeResult, ImportTarget.shopping),
      ('recipe in editor', _recipeResult, ImportTarget.editor),
      ('pantry', _pantryResult, ImportTarget.shopping),
      ('empty', const ImportResult(kind: ImportKind.list, items: []), ImportTarget.shopping),
    ]) {
      testWidgets('review sheet ($label) fits at $size, text ×$textScale', (tester) async {
        await _open(tester, result, target: target, size: size, textScale: textScale);
        expect(tester.takeException(), isNull); // a RenderFlex overflow surfaces here
      });
    }
  }

  testWidgets('list: edit, untick and remove before adding', (tester) async {
    final popped = await _open(tester, _listResult);
    expect(find.text('Lamar read your list'), findsOneWidget);
    expect(find.text('Add 12 to the list'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Milk'), 'Whole milk');
    await tester.tap(find.byType(Checkbox).at(1)); // untick "Whole milk"
    await tester.pump();
    await tester.tap(find.byTooltip('Remove').first); // drop chicken
    await tester.pump();
    expect(find.text('Add 10 to the list'), findsOneWidget);

    await tester.tap(find.text('Add 10 to the list'));
    await tester.pumpAndSettle();
    final d = popped.single!;
    expect(d.asMeal, isFalse);
    expect(d.items.map((i) => i.name), isNot(contains('Chicken thighs')));
    expect(d.items.map((i) => i.name), isNot(contains('Whole milk')));
    expect(d.items.first.name, 'Eggs');
    expect(d.items.first.quantity, '1 dozen');
  });

  testWidgets('recipe: saves as a meal, can switch to list items', (tester) async {
    final popped = await _open(tester, _recipeResult);
    expect(find.text('Lamar found a recipe'), findsOneWidget);
    expect(find.text('From example.com'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Grandma\'s Banana Bread'), findsOneWidget);

    // A meal needs a name.
    await tester.enterText(find.widgetWithText(TextField, 'Grandma\'s Banana Bread'), '');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save meal')).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Meal name'), 'Banana bread');
    await tester.pump();

    await tester.tap(find.text('Save meal'));
    await tester.pumpAndSettle();
    final d = popped.single!;
    expect(d.asMeal, isTrue);
    expect(d.mealName, 'Banana bread');
    expect(d.addToList, isTrue);
    expect(d.items, hasLength(3));
  });

  testWidgets('recipe: the user can override the kind', (tester) async {
    final popped = await _open(tester, _recipeResult);
    await tester.tap(find.text('List items'));
    await tester.pump();
    expect(find.text('Meal name'), findsNothing);
    await tester.tap(find.text('Add 3 to the list'));
    await tester.pumpAndSettle();
    expect(popped.single!.asMeal, isFalse);
  });

  testWidgets('pantry: starts with only the low items ticked', (tester) async {
    final popped = await _open(tester, _pantryResult);
    expect(find.text('Lamar peeked in the fridge'), findsOneWidget);
    expect(find.text('Add 2 to the list'), findsOneWidget);
    await tester.tap(find.text('Add 2 to the list'));
    await tester.pumpAndSettle();
    expect(popped.single!.items.map((i) => i.name), ['Milk', 'Orange juice']);
  });

  testWidgets('editor: no kind switch, everything becomes ingredients', (tester) async {
    final popped = await _open(tester, _listResult, target: ImportTarget.editor);
    expect(find.text('A meal'), findsNothing);
    expect(find.text('Put ingredients on the shopping list'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Meal name'), 'Tacos');
    await tester.pump();
    await tester.tap(find.text('Use 12 ingredients'));
    await tester.pumpAndSettle();
    expect(popped.single!.mealName, 'Tacos');
  });

  testWidgets('add another item by hand', (tester) async {
    final popped = await _open(tester, _pantryResult);
    await tester.ensureVisible(find.text('Add another'));
    await tester.pump();
    await tester.tap(find.text('Add another'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(8), 'Butter'); // 4 rows × (name, qty) + the new name
    await tester.pump();
    await tester.tap(find.text('Add 3 to the list'));
    await tester.pumpAndSettle();
    expect(popped.single!.items.last.name, 'Butter');
  });

  testWidgets('empty result only offers Close', (tester) async {
    final popped = await _open(tester, const ImportResult(kind: ImportKind.list, items: []));
    expect(find.text('Lamar couldn\'t find anything to add'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(popped.single, isNull);
  });

  group('linkIn', () {
    test('finds links worth fetching', () {
      expect(linkIn('https://example.com/recipe'), 'https://example.com/recipe');
      expect(linkIn('  http://a.co/x?y=1  '), 'http://a.co/x?y=1');
      expect(linkIn('www.example.com/tacos'), 'https://www.example.com/tacos');
      expect(linkIn('Try this! https://example.com/r'), 'https://example.com/r');
    });

    test('leaves plain items and long pastes alone', () {
      expect(linkIn('2 lb chicken'), isNull);
      expect(linkIn('milk\neggs\nbread'), isNull);
      expect(linkIn('Banana bread\n${'3 bananas, 1 cup flour, ' * 10}\nSource: https://example.com/bb'), isNull);
    });
  });

  test('ImportResult.fromJson', () {
    final r = ImportResult.fromJson({
      'kind': 'pantry',
      'meal_name': null,
      'items': [
        {'name': 'Milk', 'quantity': null, 'low': true},
        {'name': 'Eggs', 'quantity': '6', 'low': false},
      ],
      'source': 'photo',
    });
    expect(r.kind, ImportKind.pantry);
    expect(r.items.first.low, isTrue);
    expect(r.items.last.quantity, '6');
    expect(ImportResult.fromJson({'kind': 'weird', 'items': []}).kind, ImportKind.list);
  });
}
