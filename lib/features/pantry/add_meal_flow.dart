import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/models.dart';
import 'pantry_data.dart';
import 'pantry_logic.dart';

/// Puts a meal's ingredients on its shopping list, asking "Got this already?"
/// first.
///
/// **Use this whenever the UI adds a meal to the list** (meal detail, the
/// meal editor, the meal planner…) rather than calling
/// `Repository.addRecipeToList` directly. It shows a quick review sheet where
/// pantry staples and things the household said it has are pre-marked "Got
/// it" and everything else is pre-selected; one tap confirms. Answers are
/// remembered per list (see `pantry_logic.dart`), and items already on the
/// list merge instead of duplicating.
///
/// [recipe] must carry its ingredients (as from `recipeProvider`, or a
/// `Recipe` built from just-saved editor state).
///
/// Returns how many items were added or merged (0 if there was nothing to
/// add), or null if the person cancelled. Throws on network/server errors;
/// show them with `friendlyError`.
Future<int?> showAddMealToListFlow(BuildContext context, WidgetRef ref, Recipe recipe) async {
  final repo = ref.read(repositoryProvider);
  final listId = recipe.listId;
  // Pantry memory is a nicety: without it, Lamar just falls back to staples.
  final pantryF = ref
      .read(pantryProvider(listId).future)
      .timeout(const Duration(seconds: 8))
      .catchError((Object _) => const <PantryStaple>[]);
  final items = await ref.read(itemsProvider(listId).future).timeout(const Duration(seconds: 8));
  final pantry = await pantryF;

  final rows = buildMealReview(recipe: recipe, items: items, pantry: pantry, now: DateTime.now());
  if (rows.isEmpty) return 0;
  if (!context.mounted) return null;

  final confirmed = await showModalBottomSheet<List<MealReviewRow>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => MealReviewSheet(mealName: recipe.name, rows: rows),
  );
  if (confirmed == null) return null;

  final answers = reviewAnswers(confirmed);
  if (answers.have.isNotEmpty || answers.forget.isNotEmpty) {
    await repo.rememberPantry(listId, have: answers.have, forget: answers.forget);
  }
  if (!confirmed.any((r) => r.add)) return 0;
  return repo.addRecipeToList(recipe.id, skip: answers.skip);
}

/// The "Got this already?" review. Pops with the rows (choices in
/// [MealReviewRow.add]) when confirmed.
class MealReviewSheet extends StatefulWidget {
  const MealReviewSheet({super.key, required this.mealName, required this.rows});

  final String mealName;
  final List<MealReviewRow> rows;

  @override
  State<MealReviewSheet> createState() => _MealReviewSheetState();
}

class _MealReviewSheetState extends State<MealReviewSheet> {
  // Grouped by Lamar's first guess and kept in place while toggling, so rows
  // don't jump around under your thumb.
  late final _toGet = widget.rows.where((r) => r.add).toList();
  late final _gotIt = widget.rows.where((r) => !r.add).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final adding = widget.rows.where((r) => r.add).length;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text('Got this already?', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              _gotIt.isEmpty
                  ? 'Adding ${widget.mealName}. Uncheck anything you already have and Lamar will remember.'
                  : 'Lamar sniffed the pantry and thinks you\'ve got a few of these. Tap to change.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                if (_toGet.isNotEmpty) _Header('To get'),
                for (final r in _toGet) _ReviewTile(row: r, onChanged: (v) => setState(() => r.add = v)),
                if (_gotIt.isNotEmpty) _Header('Lamar thinks you\'ve got'),
                for (final r in _gotIt) _ReviewTile(row: r, onChanged: (v) => setState(() => r.add = v)),
              ],
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, widget.rows),
                      icon: Icon(adding == 0 ? Icons.check : Icons.add_shopping_cart),
                      label: Text(
                        adding == 0 ? 'Got it all' : 'Add $adding to the list',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 2),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.row, required this.onChanged});

  final MealReviewRow row;
  final ValueChanged<bool> onChanged;

  String? _subtitle() {
    final r = row;
    if (!r.add) {
      return switch (r.guess.reason) {
        PantryReason.always => 'Got it · always have',
        PantryReason.remembered => 'Got it · you had it ${_ago(r.guess.confirmedAt!)}',
        PantryReason.staple => 'Got it · pantry staple',
        _ => 'Got it',
      };
    }
    if (r.onList != null) {
      final into = r.combined;
      return into == null || into == r.onList!.quantity ? 'Already on the list' : 'On the list · becomes $into';
    }
    if (r.guess.reason == PantryReason.stale) {
      return [if (r.quantity != null) r.quantity!, 'had it ${_ago(r.guess.confirmedAt!)}, still?'].join(' · ');
    }
    return r.quantity;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitle = _subtitle();
    return CheckboxListTile(
      value: row.add,
      onChanged: (v) => onChanged(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      checkboxShape: const CircleBorder(),
      title: Text(row.name, style: TextStyle(color: row.add ? scheme.onSurface : scheme.onSurfaceVariant)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
    );
  }
}

String _ago(DateTime t) {
  final days = DateTime.now().difference(t).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  return '$days days ago';
}
