import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/planner_repository.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/data/repository.dart';
import 'package:lamars_groceries/features/planner/planner_models.dart';
import 'package:lamars_groceries/features/recipe/recipe_editor_screen.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';

class _FakePlanner implements PlannerRepository {
  var calls = 0;

  @override
  Future<MealIdea> idea(String listId, {List<String> avoid = const []}) async {
    calls++;
    return MealIdea(
      name: 'Harissa chickpeas $calls',
      pitch: 'Smoky, cosy, one pan',
      ingredients: const [
        IdeaIngredient(name: 'Chickpeas', quantity: '2 cans'),
        IdeaIngredient(name: 'Harissa', quantity: '2 tbsp'),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRepo implements Repository {
  @override
  Future<List<Suggestion>> suggestIngredients({
    required String meal,
    required List<String> ingredients,
    required List<String> dismissed,
    bool autofill = false,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakePlanner planner;

  Future<void> pumpEditor(WidgetTester tester) async {
    planner = _FakePlanner();
    tester.view.physicalSize = const Size(412, 915) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          plannerRepositoryProvider.overrideWithValue(planner),
          repositoryProvider.overrideWithValue(_FakeRepo()),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const RecipeEditorScreen(listId: 'l'),
        ),
      ),
    );
    await tester.pump();
  }

  TextEditingController nameField(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!;

  // Regression: clearing the name back to empty didn't rebuild the screen
  // (the listener skipped setState when the name matched the last reviewed
  // one, which starts as ''), so Surprise me never came back.
  testWidgets('clearing a typed name brings Surprise me back', (tester) async {
    await pumpEditor(tester);
    expect(find.text('Surprise me'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'T');
    await tester.pump();
    expect(find.text('Surprise me'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(nameField(tester).text, '');
    expect(find.text('Surprise me'), findsOneWidget);
  });

  testWidgets('clearing the name of an untouched Surprise pick starts over', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('Surprise me'));
    await tester.pumpAndSettle();
    expect(nameField(tester).text, 'Harissa chickpeas 1');
    expect(find.text('Chickpeas · 2 cans'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(find.text('Surprise me'), findsOneWidget);
    expect(find.text('Chickpeas · 2 cans'), findsNothing);
  });

  testWidgets('clearing the name keeps ingredients the user added themselves', (tester) async {
    await pumpEditor(tester);
    await tester.enterText(find.byType(TextField).first, 'Toast');
    await tester.enterText(find.widgetWithText(TextField, 'Add an ingredient'), 'Bread');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(find.text('Bread'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2)); // let the review debounce settle
  });
}
