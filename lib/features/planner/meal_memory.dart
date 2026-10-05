import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/planner_repository.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import 'add_to_list.dart';
import 'planner_models.dart';

/// "How was it?" prompts waved away this session ("Not yet").
final _dismissedRatingsProvider = NotifierProvider<_Dismissed, Set<String>>(_Dismissed.new);

class _Dismissed extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(String recipeId) => state = {...state, recipeId};
}

/// Meals rated from the Meals tab this session, newest last: their "How was
/// it?" card stays (showing the vote) until dismissed, instead of vanishing
/// the moment you tap, which looked like the vote hadn't stuck.
final _justRatedProvider = NotifierProvider<_JustRated, List<String>>(_JustRated.new);

class _JustRated extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void add(String recipeId) => state = [...state.where((id) => id != recipeId), recipeId];
  void remove(String recipeId) => state = [...state.where((id) => id != recipeId)];
}

/// 👍 / 👎 with an unmistakable selected state: the chosen one is filled and
/// outlined, the other fades. Tapping the other one changes the vote.
class RatingThumbs extends StatelessWidget {
  const RatingThumbs({super.key, required this.selected, required this.onRate, this.size = 22});

  /// 1, -1, or null if not rated yet.
  final int? selected;
  final ValueChanged<int> onRate;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget thumb(int value, String emoji, String tooltip) {
      final isSelected = selected == value;
      final faded = selected != null && !isSelected;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: isSelected ? 'Your vote' : tooltip,
          child: Material(
            shape: CircleBorder(side: BorderSide(color: isSelected ? scheme.secondary : Colors.transparent, width: 2)),
            color: isSelected ? scheme.secondaryContainer : Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: isSelected ? null : () => onRate(value),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Opacity(
                  opacity: faded ? 0.35 : 1,
                  child: Text(emoji, style: TextStyle(fontSize: size)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [thumb(1, '👍', 'Loved it'), thumb(-1, '👎', 'Not for us')]);
  }
}

/// "You loved it" / "Not for you", for a rating.
String ratingText(int rating) => rating > 0 ? 'You loved it' : 'Not one for you';

Future<void> _rate(BuildContext context, WidgetRef ref, Recipe recipe, int rating) async {
  try {
    await ref.read(plannerRepositoryProvider).rate(recipe.listId, recipe.id, recipe.name, rating);
    ref.read(_justRatedProvider.notifier).add(recipe.id);
    if (context.mounted) {
      showError(context, rating > 0 ? 'Lamar will suggest more like this' : 'Noted. Lamar will steer clear of it.');
    }
  } catch (e) {
    if (context.mounted) showError(context, friendlyError(e));
  }
}

/// Top of the Meals tab: the planner's front doors, a "How was it?" for a
/// recent meal, and a "make again?" nudge for a forgotten favourite.
class MealsTabHeader extends ConsumerWidget {
  const MealsTabHeader({super.key, required this.listId, required this.recipes, required this.onList});

  final String listId;
  final List<Recipe> recipes;
  final Set<String> onList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(mealEventsProvider(listId)).value ?? const <MealEvent>[];
    final now = DateTime.now();
    final toRate = pendingRatings(
      recipes: recipes,
      events: events,
      onList: onList,
      now: now,
      dismissed: ref.watch(_dismissedRatingsProvider),
    );
    final again = makeAgainSuggestions(recipes: recipes, events: events, onList: onList, now: now);
    final me = ref.watch(currentUserIdProvider);
    // Just rated here: keep showing that card (with the vote) until dismissed.
    final byId = {for (final r in recipes) r.id: r};
    final justRated = [
      for (final id in ref.watch(_justRatedProvider).reversed)
        if (byId[id] != null && latestRating(events, id, userId: me) != null) byId[id]!,
    ];
    final rateCard = justRated.isNotEmpty
        ? _HowWasIt(
            recipe: justRated.first,
            voted: latestRating(events, justRated.first.id, userId: me),
          )
        : toRate.isNotEmpty
        ? _HowWasIt(recipe: toRate.first)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => context.push('/lists/$listId/plan'),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Plan my week', overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/lists/$listId/tonight'),
                icon: const Icon(Icons.kitchen_outlined, size: 18),
                label: const Text('From my fridge', overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
        if (rateCard != null) ...[const SizedBox(height: 12), rateCard],
        if (again.isNotEmpty) ...[const SizedBox(height: 12), _MakeAgainCard(suggestion: again.first)],
      ],
    );
  }
}

class _HowWasIt extends ConsumerWidget {
  const _HowWasIt({required this.recipe, this.voted});

  final Recipe recipe;

  /// Their vote, once they've voted (the card then confirms it).
  final int? voted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final on = theme.colorScheme.onSurface;
    return Card(
      color: voted == null ? theme.colorScheme.secondaryContainer : theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    voted == null ? 'How was ${recipe.name}?' : recipe.name,
                    style: theme.textTheme.titleSmall?.copyWith(color: on),
                  ),
                  if (voted != null)
                    Text(
                      '${ratingText(voted!)}. Lamar will remember.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            RatingThumbs(selected: voted, onRate: (v) => _rate(context, ref, recipe, v), size: 20),
            IconButton(
              tooltip: voted == null ? 'Not yet' : 'Done',
              onPressed: () => voted == null
                  ? ref.read(_dismissedRatingsProvider.notifier).add(recipe.id)
                  : ref.read(_justRatedProvider.notifier).remove(recipe.id),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _MakeAgainCard extends ConsumerStatefulWidget {
  const _MakeAgainCard({required this.suggestion});

  final MakeAgain suggestion;

  @override
  ConsumerState<_MakeAgainCard> createState() => _MakeAgainCardState();
}

class _MakeAgainCardState extends ConsumerState<_MakeAgainCard> {
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      final n = await putMealOnList(context, ref, widget.suggestion.recipe);
      if (mounted && n != null) {
        showError(context, n == 0 ? 'Everything\'s already on the list' : 'Added $n to the list');
      }
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Lamar noticed: ${widget.suggestion.message}',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add_shopping_cart, size: 18),
                label: const Text('Put it on the list'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// On a meal's detail screen: when it was last made, and 👍 / 👎.
class MealMemoryRow extends ConsumerWidget {
  const MealMemoryRow({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final events = ref.watch(mealEventsProvider(recipe.listId)).value ?? const <MealEvent>[];
    final me = ref.watch(currentUserIdProvider);
    final last = lastMadeByRecipe(events)[recipe.id];
    final mine = latestRating(events, recipe.id, userId: me);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mine == null ? 'How was it?' : ratingText(mine),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  [
                    if (last != null) lastMadeText(DateTime.now().difference(last)),
                    if (mine != null) 'Tap the other thumb to change your vote',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          RatingThumbs(selected: mine, onRate: (v) => _rate(context, ref, recipe, v)),
        ],
      ),
    );
  }
}
