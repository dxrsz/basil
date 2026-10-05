import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/planner_repository.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/features/list/recipes_tab.dart';
import 'package:lamars_groceries/features/planner/kitchen_profile_screen.dart';
import 'package:lamars_groceries/features/planner/planner_controller.dart';
import 'package:lamars_groceries/features/planner/planner_models.dart';
import 'package:lamars_groceries/features/planner/planner_screen.dart';
import 'package:lamars_groceries/features/planner/tonight_screen.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';

MealIdea idea(String name, {String? day, String? reuse}) => MealIdea(
  name: name,
  pitch: 'A cosy weeknight bowl with a squeeze of lime and plenty of crunch',
  minutes: 25,
  appliance: 'Instant Pot / pressure cooker',
  day: day,
  reuseNote: reuse,
  ingredients: const [
    IdeaIngredient(name: 'Chicken thighs', quantity: '1 lb', perishable: true),
    IdeaIngredient(name: 'Cilantro', quantity: '1/2 bunch', perishable: true),
    IdeaIngredient(name: 'Jasmine rice', quantity: '2 cups'),
    IdeaIngredient(name: 'Lime', quantity: '2'),
  ],
);

/// Stands in for Supabase + OpenAI.
class FakePlanner implements PlannerRepository {
  final log = <String>[];
  var failNext = false;
  var swaps = 0;

  void _maybeFail() {
    if (failNext) {
      failNext = false;
      throw Exception('offline');
    }
  }

  @override
  Future<MealPlan> planWeek(String listId) async {
    log.add('plan');
    return MealPlan(
      summary: 'Lamar reused the cilantro on Thursday so none of it wilts.',
      meals: [
        idea('Chicken taco bowls with extra-long name for wrapping', day: 'Monday'),
        idea('Green curry', day: 'Tuesday'),
        idea('Cilantro lime fish', day: 'Thursday', reuse: 'Uses the rest of Monday\'s cilantro'),
      ],
    );
  }

  @override
  Future<MealPlan> swap(String listId, List<MealIdea> week, int index, {List<String> avoid = const []}) async {
    _maybeFail();
    log.add('swap $index avoid=${avoid.join(',')}');
    return MealPlan(
      summary: '',
      meals: [idea('Swap ${++swaps}', day: week[index].day)],
      // The swap broke the cilantro chain.
      weekNotes: List.filled(week.length, null),
    );
  }

  @override
  Future<MealPlan> nudge(String listId, List<MealIdea> week, int index, String nudge) async {
    _maybeFail();
    log.add('nudge $index $nudge');
    // No day and no week notes: the controller keeps the old night and notes.
    return MealPlan(
      summary: '',
      meals: [idea('${week[index].name}, $nudge', reuse: 'Uses the rest of Monday\'s lime')],
    );
  }

  @override
  Future<({MealPlan plan, NopeLearned? learned})> nope(
    String listId,
    List<MealIdea> week,
    int index,
    NopeReason reason, {
    List<String> avoid = const [],
  }) async {
    _maybeFail();
    log.add('nope $index ${reason.kind}:${reason.value} avoid=${avoid.join(',')}');
    return (
      plan: MealPlan(
        summary: '',
        meals: [idea('Nope ${++swaps}', day: week[index].day)],
      ),
      learned: reason.kind == 'ingredient' ? NopeLearned(kind: 'ingredient', value: reason.value) : null,
    );
  }

  @override
  Future<void> logEvent(String listId, MealEventKind kind, String mealName, {String? recipeId, String? detail}) async {
    log.add('log ${kind.name} $mealName${detail == null ? '' : ' ($detail)'}');
  }

  @override
  Future<String> keepMeal(String listId, MealIdea idea, {String? detail}) async {
    _maybeFail();
    log.add('keep ${idea.name}');
    return 'recipe-${idea.name}';
  }

  @override
  Future<MealPlan> tonight(String listId, List<String> have) async =>
      MealPlan(summary: 'Lamar found two ways to use the spinach.', meals: [idea('Spinach frittata'), idea('Saag')]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PlannerController', () {
    late FakePlanner fake;
    late ProviderContainer c;
    PlannerState state() => c.read(plannerProvider('l'));
    PlannerController planner() => c.read(plannerProvider('l').notifier);

    setUp(() async {
      fake = FakePlanner();
      c = ProviderContainer(overrides: [plannerRepositoryProvider.overrideWithValue(fake)]);
      await planner().planWeek();
    });
    tearDown(() => c.dispose());

    test('plans a week of cards', () {
      expect(state().cards.map((c) => c.idea.day), ['Monday', 'Tuesday', 'Thursday']);
      expect(state().summary, contains('cilantro'));
      expect(state().loading, isFalse);
    });

    test('swap replaces one night, remembers what was passed on, and logs it', () async {
      await planner().swap(1);
      await planner().swap(1);
      final card = state().cards[1];
      expect(card.idea.name, 'Swap 2');
      expect(card.idea.day, 'Tuesday');
      expect(card.passed, ['Green curry', 'Swap 1']);
      expect(state().cards[2].idea.reuseNote, isNull, reason: 'other nights get the recomputed notes');
      expect(state().cards[2].idea.day, 'Thursday');
      expect(fake.log, containsAllInOrder(['swap 1 avoid=', 'log swapped Green curry', 'swap 1 avoid=Green curry']));
    });

    test('nudge keeps the night and logs the request', () async {
      await planner().nudge(2, 'faster');
      expect(state().cards[2].idea.name, 'Cilantro lime fish, faster');
      expect(state().cards[2].idea.day, 'Thursday');
      expect(state().cards[2].idea.reuseNote, 'Uses the rest of Monday\'s lime');
      expect(fake.log.last, 'log nudged Cilantro lime fish (faster)');
    });

    test('keep saves the meal once; kept cards can no longer be swapped', () async {
      final id = await planner().keep(0);
      expect(state().cards[0].status, CardStatus.kept);
      expect(state().cards[0].recipeId, id);
      expect(await planner().keep(0), id);
      expect(fake.log.where((l) => l.startsWith('keep')), hasLength(1));
      await planner().swap(0);
      expect(state().cards[0].status, CardStatus.kept);
      expect(state().kept, hasLength(1));
    });

    test('a failed swap restores the card and rethrows', () async {
      fake.failNext = true;
      await expectLater(planner().swap(1), throwsException);
      expect(state().cards[1].idea.name, 'Green curry');
      expect(state().cards[1].status, CardStatus.proposed);
    });
  });

  // No overflow at a small phone with large text.
  group('layout at 360×640, text ×1.3', () {
    Future<void> pump(WidgetTester tester, Widget child, {required ProviderContainer container}) async {
      tester.view.physicalSize = const Size(360, 640) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final app = MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: child,
      );
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: app));
      await tester.pump();
    }

    ProviderContainer container(FakePlanner fake, {List<Item> items = const []}) => ProviderContainer(
      overrides: [
        plannerRepositoryProvider.overrideWithValue(fake),
        currentUserIdProvider.overrideWithValue('me'),
        tasteProfileProvider.overrideWith((ref) async => const TasteProfile()),
        kitchenSettingsProvider.overrideWith(
          (ref, _) async => const KitchenSettings(appliances: {'oven', 'slow_cooker'}),
        ),
        itemsProvider.overrideWith((ref, _) => Stream.value(items)),
        recipesProvider.overrideWith((ref, _) => const AsyncData(<Recipe>[])),
        mealEventsProvider.overrideWith((ref, _) => Stream.value(const <MealEvent>[])),
      ],
    );

    testWidgets('kitchen profile, every question', (tester) async {
      final c = container(FakePlanner());
      addTearDown(c.dispose);
      await pump(
        tester,
        const KitchenProfileForm(listId: 'l', initialTaste: TasteProfile(), initialKitchen: KitchenSettings()),
        container: c,
      );
      expect(find.text('Who\'s eating?'), findsOneWidget);
      for (final title in [
        'Any diets or allergies?',
        'How much time on a weeknight?',
        'What\'s in your kitchen?',
        'Any you\'d like to use more?',
        'What do you love to eat?',
      ]) {
        await tester.tap(find.text('Next'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(find.text('All done'), findsOneWidget);
    });

    testWidgets('a planned week', (tester) async {
      final fake = FakePlanner();
      final c = container(fake);
      addTearDown(c.dispose);
      await c.read(plannerProvider('l').notifier).planWeek();
      await c.read(plannerProvider('l').notifier).keep(0);
      await pump(tester, const PlannerScreen(listId: 'l'), container: c);
      expect(tester.takeException(), isNull);
      expect(find.text('Put 1 kept meal on the list'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('♻️  Uses the rest of Monday\'s cilantro'), 200);
      expect(tester.takeException(), isNull);
      expect(find.text('Keep'), findsWidgets);

      // Nudge sheet offers their appliances.
      await tester.ensureVisible(find.text('Nudge').last);
      await tester.pump();
      await tester.tap(find.text('Nudge').last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Use the slow cooker'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('first visit offers the kitchen profile', (tester) async {
      final c = ProviderContainer(
        overrides: [
          plannerRepositoryProvider.overrideWithValue(FakePlanner()),
          tasteProfileProvider.overrideWith((ref) async => null),
          kitchenSettingsProvider.overrideWith((ref, _) async => null),
          itemsProvider.overrideWith((ref, _) => Stream.value(const <Item>[])),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, const PlannerScreen(listId: 'l'), container: c);
      await tester.pump();
      expect(find.text('Lamar has a few questions first'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Meals tab with "How was it?" and "make again"', (tester) async {
      final now = DateTime.now();
      Recipe r(String id, String name) =>
          Recipe(id: id, listId: 'l', name: name, imageUrl: null, imageStatus: ImageStatus.idle, createdAt: now);
      MealEvent e(String id, Duration ago) => MealEvent(
        id: '$id-${ago.inDays}',
        listId: 'l',
        recipeId: id,
        mealName: id,
        kind: MealEventKind.added,
        createdAt: now.subtract(ago),
      );
      final c = ProviderContainer(
        overrides: [
          plannerRepositoryProvider.overrideWithValue(FakePlanner()),
          itemsProvider.overrideWith((ref, _) => Stream.value(const <Item>[])),
          recipesProvider.overrideWith(
            (ref, _) => AsyncData([r('a', 'Sheet-pan chicken with lemony potatoes'), r('b', 'Taco bowls')]),
          ),
          mealEventsProvider.overrideWith(
            (ref, _) => Stream.value([e('a', const Duration(days: 3)), e('b', const Duration(days: 30))]),
          ),
        ],
      );
      addTearDown(c.dispose);
      await pump(
        tester,
        const Scaffold(body: RecipesTab(listId: 'l')),
        container: c,
      );
      await tester.pump();
      expect(find.text('How was Sheet-pan chicken with lemony potatoes?'), findsOneWidget);
      expect(find.textContaining('You haven\'t made Taco bowls in 4 weeks'), findsOneWidget);
      expect(find.text('Plan my week'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty Meals tab under the list app bar', (tester) async {
      final c = ProviderContainer(
        overrides: [
          itemsProvider.overrideWith((ref, _) => Stream.value(const <Item>[])),
          recipesProvider.overrideWith((ref, _) => const AsyncData(<Recipe>[])),
        ],
      );
      addTearDown(c.dispose);
      await pump(
        tester,
        DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Groceries'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Shopping'),
                  Tab(text: 'Meals'),
                ],
              ),
            ),
            body: const RecipesTab(listId: 'l'),
          ),
        ),
        container: c,
      );
      expect(find.text('Plan my week with Lamar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('what can I make tonight', (tester) async {
      final c = container(
        FakePlanner(),
        items: [
          for (final n in ['Spinach', 'Feta', 'Eggs', 'Tortillas', 'Greek yogurt'])
            Item(
              id: n,
              listId: 'l',
              name: n,
              quantity: null,
              category: 'Produce',
              checked: true,
              checkedBy: null,
              recipeId: null,
              createdAt: DateTime(2026),
            ),
        ],
      );
      addTearDown(c.dispose);
      await pump(tester, const TonightScreen(listId: 'l'), container: c);
      expect(find.text('Recently bought'), findsOneWidget);
      await tester.tap(find.text('Spinach'));
      await tester.pump();
      await tester.ensureVisible(find.text('Ask Lamar'));
      await tester.pump();
      await tester.tap(find.text('Ask Lamar'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // scrolls the ideas into view
      expect(find.text('Spinach frittata'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
