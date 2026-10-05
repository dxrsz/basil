import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/features/planner/planner_models.dart';
import 'package:lamars_groceries/models/models.dart';

final now = DateTime(2026, 10, 5, 18);

Recipe recipe(String id, String name) =>
    Recipe(id: id, listId: 'l', name: name, imageUrl: null, imageStatus: ImageStatus.idle, createdAt: DateTime(2026));

var _n = 0;
MealEvent event(String? recipeId, MealEventKind kind, Duration ago, {int? rating, String? user, String name = 'x'}) =>
    MealEvent(
      id: '${_n++}',
      listId: 'l',
      recipeId: recipeId,
      mealName: name,
      kind: kind,
      rating: rating,
      userId: user,
      createdAt: now.subtract(ago),
    );

void main() {
  group('makeAgainSuggestions', () {
    final tacos = recipe('t', 'Taco bowls');
    final curry = recipe('c', 'Green curry');
    final soup = recipe('s', 'Soup');
    final never = recipe('n', 'Never made');

    test('suggests meals not made for a while, liked first then oldest', () {
      final out = makeAgainSuggestions(
        recipes: [tacos, curry, soup, never],
        events: [
          event('t', MealEventKind.added, const Duration(days: 21)),
          event('c', MealEventKind.added, const Duration(days: 40)),
          event('s', MealEventKind.added, const Duration(days: 15)),
          event('s', MealEventKind.rated, const Duration(days: 15), rating: 1),
        ],
        onList: const {},
        now: now,
      );
      expect(out.map((m) => m.recipe.name), ['Soup', 'Green curry', 'Taco bowls']);
      expect(out.last.message, 'You haven\'t made Taco bowls in 3 weeks. Make again?');
    });

    test('skips recent, disliked, never-made and already-on-list meals', () {
      final out = makeAgainSuggestions(
        recipes: [tacos, curry, soup, never],
        events: [
          event('t', MealEventKind.added, const Duration(days: 30)),
          event('t', MealEventKind.cooked, const Duration(days: 3)), // made recently
          event('c', MealEventKind.added, const Duration(days: 30)),
          event('c', MealEventKind.rated, const Duration(days: 29), rating: -1),
          event('s', MealEventKind.added, const Duration(days: 30)),
        ],
        onList: const {'s'},
        now: now,
      );
      expect(out, isEmpty);
    });

    test('the latest rating wins', () {
      final out = makeAgainSuggestions(
        recipes: [curry],
        events: [
          event('c', MealEventKind.rated, const Duration(days: 60), rating: -1),
          event('c', MealEventKind.rated, const Duration(days: 20), rating: 1),
        ],
        onList: const {},
        now: now,
      );
      expect(out.single.liked, isTrue);
    });
  });

  group('pendingRatings', () {
    final tacos = recipe('t', 'Taco bowls');
    final curry = recipe('c', 'Green curry');

    test('asks about meals added 2-10 days ago and not rated since', () {
      final out = pendingRatings(
        recipes: [tacos, curry],
        events: [
          event('t', MealEventKind.added, const Duration(days: 3)),
          event('c', MealEventKind.added, const Duration(days: 4)),
          event('c', MealEventKind.rated, const Duration(days: 1), rating: 1),
        ],
        onList: const {},
        now: now,
      );
      expect(out.map((r) => r.id), ['t']);
    });

    test('waits until it is shopped for, and respects "not yet"', () {
      final events = [event('t', MealEventKind.added, const Duration(days: 3))];
      expect(pendingRatings(recipes: [tacos], events: events, onList: const {'t'}, now: now), isEmpty);
      expect(
        pendingRatings(recipes: [tacos], events: events, onList: const {}, now: now, dismissed: const {'t'}),
        isEmpty,
      );
    });

    test('too fresh or too old is not asked about', () {
      for (final days in [1, 12]) {
        final events = [event('t', MealEventKind.added, Duration(days: days))];
        expect(pendingRatings(recipes: [tacos], events: events, onList: const {}, now: now), isEmpty);
      }
    });

    test('an old rating does not cover a new cook', () {
      final out = pendingRatings(
        recipes: [tacos],
        events: [
          event('t', MealEventKind.rated, const Duration(days: 30), rating: 1),
          event('t', MealEventKind.added, const Duration(days: 3)),
        ],
        onList: const {},
        now: now,
      );
      expect(out, hasLength(1));
    });
  });

  test('latestRating can be per user', () {
    final events = [
      event('t', MealEventKind.rated, const Duration(days: 2), rating: 1, user: 'me'),
      event('t', MealEventKind.rated, const Duration(days: 1), rating: -1, user: 'them'),
    ];
    expect(latestRating(events, 't'), -1);
    expect(latestRating(events, 't', userId: 'me'), 1);
    expect(latestRating(events, 'other'), isNull);
  });

  test('humanAgo and lastMadeText', () {
    expect(humanAgo(const Duration(days: 1)), '1 day');
    expect(humanAgo(const Duration(days: 10)), '10 days');
    expect(humanAgo(const Duration(days: 21)), '3 weeks');
    expect(humanAgo(const Duration(days: 75)), '2 months');
    expect(lastMadeText(const Duration(hours: 3)), 'Last made today');
    expect(lastMadeText(const Duration(days: 21)), 'Last made 3 weeks ago');
  });

  test('want-more appliances are limited to ones they have', () {
    const s = KitchenSettings(appliances: {'oven', 'air_fryer'}, wantMore: {'air_fryer', 'grill'});
    expect(s.toJson()['want_more'], ['air_fryer']);
  });

  test('MealIdea round-trips and becomes recipe ingredients', () {
    final idea = MealIdea.fromJson({
      'name': 'Chicken tacos',
      'pitch': 'Crunchy and quick',
      'minutes': 25,
      'effort': 'easy',
      'appliance': 'air fryer',
      'ingredients': [
        {'name': 'Cilantro', 'quantity': '1/2 bunch', 'perishable': true},
        {'name': 'Tortillas', 'quantity': null, 'perishable': false},
      ],
      'reuse_note': null,
      'day': 'Monday',
    });
    expect(MealIdea.fromJson(idea.toJson()).toJson(), idea.toJson());
    final ings = idea.toRecipeIngredients();
    expect(ings.map((i) => (i.name, i.quantity, i.position)), [('Cilantro', '1/2 bunch', 0), ('Tortillas', null, 1)]);
  });
}
