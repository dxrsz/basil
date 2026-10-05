import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/planner_repository.dart';
import 'package:lamars_groceries/features/planner/nope_sheet.dart';
import 'package:lamars_groceries/features/planner/planner_controller.dart';
import 'package:lamars_groceries/features/planner/planner_models.dart';
import 'package:lamars_groceries/theme.dart';

import 'planner_test.dart' show FakePlanner, idea;

MealIdea tofuBowl() => MealIdea.fromJson({
  ...idea('Crispy tofu rice bowls', day: 'Monday').toJson(),
  'nope_guesses': [
    {'kind': 'ingredient', 'label': 'Not into tofu', 'value': 'tofu'},
    {'kind': 'spice', 'label': 'Too spicy', 'value': ''},
  ],
});

void main() {
  group('NopeReason / MealIdea', () {
    test('guesses survive the JSON round trip (and withNote)', () {
      final m = tofuBowl().withNote('Uses the rest of Monday\'s lime');
      expect(m.nopeGuesses.map((g) => g.label), ['Not into tofu', 'Too spicy']);
      expect(m.nopeGuesses.first.value, 'tofu');
    });

    test('acknowledgements say what Lamar learned', () {
      const tofu = NopeReason(kind: 'ingredient', label: 'Not into tofu', value: 'tofu');
      expect(nopeAck(tofu, const NopeLearned(kind: 'ingredient', value: 'tofu')), contains('tofu again'));
      expect(nopeAck(generalNopeReasons.first, null), contains('easier'));
      expect(nopeAck(const NopeReason(kind: 'mood', label: 'Just not feeling it'), null), isNull);
    });
  });

  group('PlannerController.nope', () {
    late FakePlanner fake;
    late ProviderContainer c;
    PlannerController planner() => c.read(plannerProvider('l').notifier);
    PlannerState state() => c.read(plannerProvider('l'));

    setUp(() async {
      fake = FakePlanner();
      c = ProviderContainer(overrides: [plannerRepositoryProvider.overrideWithValue(fake)]);
      await planner().planWeek();
    });
    tearDown(() => c.dispose());

    test('replaces the night, keeps the day, and remembers what was passed on', () async {
      final before = state().cards[1].idea.name;
      final learned = await planner().nope(
        1,
        const NopeReason(kind: 'ingredient', label: 'Not into tofu', value: 'tofu'),
      );
      expect(learned?.value, 'tofu');
      expect(state().cards[1].idea.name, 'Nope 1');
      expect(state().cards[1].idea.day, 'Tuesday');
      expect(state().cards[1].passed, [before]);
      expect(fake.log.last, 'nope 1 ingredient:tofu avoid=');
    });

    test('a failure restores the card', () async {
      final before = state().cards[0].idea.name;
      fake.failNext = true;
      await expectLater(planner().nope(0, generalNopeReasons.first), throwsException);
      expect(state().cards[0].idea.name, before);
      expect(state().cards[0].status, CardStatus.proposed);
    });
  });

  group('NopeSheet', () {
    // What the sheet popped with, once it closes.
    late List<NopeReason?> results;

    Future<void> open(WidgetTester tester, {Size size = const Size(412, 915), double text = 1}) async {
      results = [];
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => results.add(
                    await showModalBottomSheet<NopeReason>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => NopeSheet(idea: tofuBowl()),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers Lamar\'s guesses first, then general reasons', (tester) async {
      await open(tester);
      expect(find.text('Nope to Crispy tofu rice bowls?'), findsOneWidget);
      final labels = tester.widgetList<ActionChip>(find.byType(ActionChip)).map((c) => (c.label as Text).data).toList();
      expect(labels.take(2), ['Not into tofu', 'Too spicy']);
      expect(labels, containsAll(['Too much work', 'Too heavy', 'Too light', 'Had it recently']));
    });

    testWidgets('tapping a guess returns it', (tester) async {
      await open(tester);
      await tester.tap(find.text('Not into tofu'));
      await tester.pumpAndSettle();
      expect(find.byType(NopeSheet), findsNothing);
      expect(results.single?.kind, 'ingredient');
      expect(results.single?.value, 'tofu');
    });

    testWidgets('typed reasons are sent as "other" with the text as the label', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'We had fish yesterday');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(results.single?.kind, 'other');
      expect(results.single?.label, 'We had fish yesterday');
    });

    testWidgets('an empty typed reason does nothing', (tester) async {
      await open(tester);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.byType(NopeSheet), findsOneWidget);
      expect(results, isEmpty);
    });

    testWidgets('fits at 360x640 with text x1.3', (tester) async {
      await open(tester, size: const Size(360, 640), text: 1.3);
      expect(tester.takeException(), isNull);
    });
  });
}
