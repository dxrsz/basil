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

Future<void> _rate(BuildContext context, WidgetRef ref, Recipe recipe, int rating) async {
  try {
    await ref.read(plannerRepositoryProvider).rate(recipe.listId, recipe.id, recipe.name, rating);
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
                label: const Text('Tonight?', overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
        if (toRate.isNotEmpty) ...[const SizedBox(height: 12), _HowWasIt(recipe: toRate.first)],
        if (again.isNotEmpty) ...[const SizedBox(height: 12), _MakeAgainCard(suggestion: again.first)],
      ],
    );
  }
}

class _HowWasIt extends ConsumerWidget {
  const _HowWasIt({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'How was ${recipe.name}?',
                style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
            IconButton(tooltip: 'Loved it', onPressed: () => _rate(context, ref, recipe, 1), icon: const Text('👍')),
            IconButton(tooltip: 'Not for us', onPressed: () => _rate(context, ref, recipe, -1), icon: const Text('👎')),
            IconButton(
              tooltip: 'Not yet',
              onPressed: () => ref.read(_dismissedRatingsProvider.notifier).add(recipe.id),
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

    Widget thumb(int value, String emoji, String tooltip) {
      final selected = mine == value;
      return IconButton(
        tooltip: tooltip,
        isSelected: selected,
        style: IconButton.styleFrom(backgroundColor: selected ? theme.colorScheme.secondaryContainer : null),
        onPressed: selected ? null : () => _rate(context, ref, recipe, value),
        icon: Text(emoji, style: const TextStyle(fontSize: 20)),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How was it?', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                if (last != null)
                  Text(
                    lastMadeText(DateTime.now().difference(last)),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          thumb(1, '👍', 'Loved it'),
          thumb(-1, '👎', 'Not for us'),
        ],
      ),
    );
  }
}
