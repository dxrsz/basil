import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/recipe_image.dart';

class RecipesTab extends ConsumerWidget {
  const RecipesTab({super.key, required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipes = ref.watch(recipesProvider(listId));
    final items = ref.watch(itemsProvider(listId)).value ?? const <Item>[];
    final onList = {for (final i in items) if (!i.checked && i.recipeId != null) i.recipeId!};

    return switch (recipes) {
      AsyncData(:final value) when value.isEmpty => EmptyState(
          emoji: '🥘',
          title: 'No meals yet',
          message: 'Add a meal like "Taco bowls" with what goes in it. '
              'Basil will flag anything you forgot and make a photo of it.',
          action: FilledButton.icon(
            onPressed: () => context.go('/lists/$listId/recipes/new'),
            icon: const Icon(Icons.add),
            label: const Text('Add a meal'),
          ),
        ),
      AsyncData(:final value) => GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.78,
          ),
          itemCount: value.length,
          itemBuilder: (_, i) => _RecipeCard(
            recipe: value[i],
            onList: onList.contains(value[i].id),
            listId: listId,
          ),
        ),
      AsyncError(:final error) =>
        EmptyState(emoji: '😕', title: 'Couldn\'t load meals', message: friendlyError(error)),
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
