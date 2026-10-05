import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../util/item_merge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/recipe_image.dart';
import '../pantry/add_meal_flow.dart';
import '../pantry/pantry_data.dart';
import '../pantry/pantry_logic.dart';
import '../planner/meal_memory.dart';
import 'meal_videos.dart';

class RecipeDetailScreen extends ConsumerStatefulWidget {
  const RecipeDetailScreen({super.key, required this.listId, required this.recipeId});

  final String listId;
  final String recipeId;

  @override
  ConsumerState<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen> {
  bool _busy = false;

  Repository get _repo => ref.read(repositoryProvider);

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final message = await action();
      if (mounted && message != null) showError(context, message);
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Recipe recipe) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${recipe.name}?'),
        content: const Text('Items already on the shopping list stay there.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _repo.deleteRecipe(recipe.id);
      if (mounted) context.go('/lists/${widget.listId}?tab=recipes');
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final recipe = ref.watch(recipeProvider((listId: widget.listId, recipeId: widget.recipeId)));
    final items = ref.watch(itemsProvider(widget.listId)).value ?? const <Item>[];
    final pantry = ref.watch(pantryProvider(widget.listId)).value ?? const <PantryStaple>[];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (recipe == null) {
      final loading = ref.watch(recipesProvider(widget.listId)).isLoading;
      return Scaffold(
        appBar: AppBar(),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(emoji: '🫥', title: 'Meal not found', message: 'Someone may have deleted it.'),
      );
    }

    // Where each ingredient stands on the shopping list.
    final mine = items.where((i) => i.recipeIds.contains(recipe.id)).toList();
    final onListCount = mine.where((i) => !i.checked).length;
    final memory = {for (final p in pantry) p.nameKey: p};
    final now = DateTime.now();
    _IngredientState stateOf(Ingredient ing) {
      final n = normalizeItemName(ing.name);
      final matches = items.where((i) => normalizeItemName(i.name) == n);
      if (matches.any((i) => !i.checked)) return _IngredientState.onList;
      if (matches.any((i) => i.checked)) return _IngredientState.inCart;
      if (guessPantry(ing.name, memory, now).have) return _IngredientState.pantry;
      return _IngredientState.none;
    }

    final missingFromList = recipe.ingredients.where((i) => stateOf(i) == _IngredientState.none).length;
    final inPantry = recipe.ingredients.where((i) => stateOf(i) == _IngredientState.pantry).length;
    void addToList() => _run(() async {
      final n = await showAddMealToListFlow(context, ref, recipe);
      if (n == null) return null;
      return n == 0 ? 'Nothing to add. Lamar\'s got you covered' : 'Added $n to the list';
    });

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 340,
            pinned: true,
            stretch: true,
            actions: [
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => context.go('/lists/${widget.listId}/recipes/${recipe.id}/edit'),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'photo':
                      _run(() async {
                        await _repo.generateImage(recipe.id, force: true);
                        return 'Making a new photo…';
                      });
                    case 'delete':
                      _delete(recipe);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'photo', child: Text('New photo')),
                  PopupMenuItem(value: 'delete', child: Text('Delete meal')),
                ],
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground],
              background: Hero(
                tag: 'recipe-image-${recipe.id}',
                child: RecipeImage(recipe: recipe, onRetry: () => _repo.generateImage(recipe.id, force: true)),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            sliver: SliverList.list(
              children: [
                Text(recipe.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                if (recipe.ingredients.isNotEmpty)
                  if (missingFromList > 0)
                    FilledButton.icon(
                      onPressed: _busy ? null : addToList,
                      icon: const Icon(Icons.add_shopping_cart),
                      label: Text('Add $missingFromList ingredient${missingFromList == 1 ? '' : 's'} to the list'),
                    )
                  else if (onListCount > 0)
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              final n = await _repo.removeRecipeFromList(recipe.id);
                              return 'Removed $n from the list';
                            }),
                      icon: const Icon(Icons.remove_shopping_cart_outlined),
                      label: const Text('Take off the list'),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle, color: scheme.primary),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('You\'ve got everything for this one')),
                          if (inPantry > 0)
                            TextButton(onPressed: _busy ? null : addToList, child: const Text('Out of something?')),
                        ],
                      ),
                    ),
                MealMemoryRow(recipe: recipe),
                const SizedBox(height: 24),
                Text('Ingredients', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                if (recipe.ingredients.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No ingredients yet. Tap edit to add some.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                for (final ing in recipe.ingredients) _IngredientRow(ingredient: ing, state: stateOf(ing)),
                MealVideos(recipe: recipe),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _IngredientState { none, onList, inCart, pantry }

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.ingredient, required this.state});

  final Ingredient ingredient;
  final _IngredientState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color, label) = switch (state) {
      _IngredientState.onList => (Icons.shopping_cart_outlined, scheme.primary, 'On list'),
      _IngredientState.inCart => (Icons.check_circle, scheme.primary, 'Got it'),
      _IngredientState.pantry => (Icons.kitchen_outlined, scheme.onSurfaceVariant, 'In pantry'),
      _IngredientState.none => (Icons.circle_outlined, scheme.outline, null),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 14),
          Expanded(child: Text(ingredient.name, style: theme.textTheme.bodyLarge)),
          if (ingredient.quantity != null)
            Text(ingredient.quantity!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          if (label != null) ...[
            const SizedBox(width: 10),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
          ],
        ],
      ),
    );
  }
}
