import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/planner_repository.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/recipe_image.dart';
import '../import/import_flow.dart';
import '../planner/meal_memory.dart';
import '../planner/planner_models.dart';

class RecipesTab extends ConsumerWidget {
  const RecipesTab({super.key, required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipes = ref.watch(recipesProvider(listId));
    final items = ref.watch(itemsProvider(listId)).value ?? const <Item>[];
    final onList = {
      for (final i in items)
        // recipeIds: a merged item can belong to several meals.
        if (!i.checked) ...i.recipeIds,
    };

    return switch (recipes) {
      AsyncData(:final value) when value.isEmpty => EmptyState(
        emoji: '🥘',
        title: 'No meals yet',
        message:
            'Add a meal like "Taco bowls" with what goes in it. '
            'Lamar will flag anything you forgot and snap a photo of it.',
        action: Column(
          children: [
            FilledButton.icon(
              onPressed: () => context.go('/lists/$listId/recipes/new'),
              icon: const Icon(Icons.add),
              label: const Text('Add a meal'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => context.push('/lists/$listId/plan'),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Plan my week with Lamar'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => importToList(context, ref, listId: listId),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Import from photo or link'),
            ),
          ],
        ),
      ),
      AsyncData(:final value) => CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: MealsTabHeader(listId: listId, recipes: value, onList: onList),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.78,
              ),
              itemCount: value.length,
              itemBuilder: (_, i) =>
                  _RecipeCard(recipe: value[i], onList: onList.contains(value[i].id), listId: listId),
            ),
          ),
        ],
      ),
      AsyncError(:final error) => EmptyState(emoji: '😕', title: 'Couldn\'t load meals', message: friendlyError(error)),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class _RecipeCard extends ConsumerWidget {
  const _RecipeCard({required this.recipe, required this.onList, required this.listId});

  final Recipe recipe;
  final bool onList;
  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final events = ref.watch(mealEventsProvider(listId)).value ?? const <MealEvent>[];
    final rating = latestRating(events, recipe.id, userId: ref.watch(currentUserIdProvider));
    return Card(
      child: InkWell(
        onTap: () => context.go('/lists/$listId/recipes/${recipe.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: 'recipe-image-${recipe.id}',
                    child: RecipeImage(
                      recipe: recipe,
                      compact: true,
                      onRetry: () => ref.read(repositoryProvider).generateImage(recipe.id, force: true),
                    ),
                  ),
                  if (rating != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Tooltip(
                        message: ratingText(rating),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                          ),
                          child: Text(rating > 0 ? '👍' : '👎', style: const TextStyle(fontSize: 14)),
                        ),
                      ),
                    ),
                  if (onList)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'On list',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recipe.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${recipe.ingredients.length} ingredient${recipe.ingredients.length == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
