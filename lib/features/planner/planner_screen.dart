import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/planner_repository.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/lamar.dart';
import 'add_to_list.dart';
import 'meal_idea_card.dart';
import 'planner_controller.dart';
import 'planner_models.dart';

/// "Plan my week with Lamar": a card per dinner to keep, swap or nudge.
class PlannerScreen extends ConsumerStatefulWidget {
  const PlannerScreen({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends ConsumerState<PlannerScreen> {
  bool _skippedProfile = false;
  bool _adding = false;

  PlannerController get _planner => ref.read(plannerProvider(widget.listId).notifier);

  Future<void> _try(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    }
  }

  Future<void> _editProfile() async {
    await context.push('/lists/${widget.listId}/plan/profile');
  }

  Future<void> _plan() async {
    final kept = ref.read(plannerProvider(widget.listId)).kept.length;
    final cards = ref.read(plannerProvider(widget.listId)).cards.length;
    if (cards > kept && kept > 0) {
      // Kept meals are already saved; only the undecided ones are replaced.
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start a fresh plan?'),
          content: const Text('Meals you kept stay in Meals. Lamar will come up with all-new ideas for the rest.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replan')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _try(_planner.planWeek);
  }

  Future<void> _nudge(int index) async {
    final settings = ref.read(kitchenSettingsProvider(widget.listId)).value;
    final nudge = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => NudgeSheet(appliances: settings?.appliances ?? const {}),
    );
    if (nudge == null || nudge.trim().isEmpty) return;
    await _try(() => _planner.nudge(index, nudge.trim()));
  }

  /// One "Got this already?" review per meal; cancelling one stops there.
  Future<void> _addKeptToList(List<PlanCard> kept) async {
    setState(() => _adding = true);
    var added = 0;
    try {
      for (final c in kept) {
        if (!mounted) return;
        final n = await putMealOnList(context, ref, keptRecipe(widget.listId, c.recipeId!, c.idea));
        if (n == null) break;
        added += n;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(added == 0 ? 'Everything\'s already on the list' : 'Added $added items to the list'),
            action: SnackBarAction(label: 'View list', onPressed: () => context.go('/lists/${widget.listId}')),
          ),
        );
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final taste = ref.watch(tasteProfileProvider);
    final kitchen = ref.watch(kitchenSettingsProvider(widget.listId));
    final plan = ref.watch(plannerProvider(widget.listId));
    final items = ref.watch(itemsProvider(widget.listId)).value ?? const <Item>[];
    final onList = {
      for (final i in items)
        if (!i.checked && i.recipeId != null) i.recipeId!,
    };

    final needsProfile = taste.hasValue && kitchen.hasValue && (taste.value == null || kitchen.value == null);
    final Widget body;
    if (!plan.hasPlan && (taste.isLoading || kitchen.isLoading)) {
      body = const Center(child: CircularProgressIndicator());
    } else if (plan.loading) {
      body = const LamarThinking();
    } else if (!plan.hasPlan && needsProfile && !_skippedProfile) {
      body = _ProfileIntro(onStart: _editProfile, onSkip: () => setState(() => _skippedProfile = true));
    } else if (!plan.hasPlan) {
      body = _ReadyToPlan(
        listId: widget.listId,
        dinners: kitchen.value?.dinnersPerWeek ?? 5,
        onPlan: _plan,
        onList: onList,
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        itemCount: plan.cards.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) => i == 0
            ? _LamarSays(text: plan.summary ?? 'Here\'s your week!')
            : _PlanCardView(
                listId: widget.listId,
                card: plan.cards[i - 1],
                onList: onList.contains(plan.cards[i - 1].recipeId),
                onKeep: () => _try(() => _planner.keep(i - 1)),
                onAddToList: _adding ? null : () => _addKeptToList([plan.cards[i - 1]]),
                onSwap: () => _try(() => _planner.swap(i - 1)),
                onNudge: () => _nudge(i - 1),
              ),
      );
    }

    final notOnList = plan.kept.where((c) => !onList.contains(c.recipeId)).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan my week'),
        actions: [
          if (plan.hasPlan && !plan.loading)
            IconButton(tooltip: 'Replan', icon: const Icon(Icons.refresh), onPressed: _plan),
          IconButton(tooltip: 'Kitchen profile', icon: const Icon(Icons.tune), onPressed: _editProfile),
        ],
      ),
      body: body,
      bottomNavigationBar: plan.hasPlan && !plan.loading && notOnList.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _adding ? null : () => _addKeptToList(notOnList),
                  icon: const Icon(Icons.add_shopping_cart),
                  label: Text(
                    'Put ${notOnList.length} kept meal${notOnList.length == 1 ? '' : 's'} on the list',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

class _PlanCardView extends StatelessWidget {
  const _PlanCardView({
    required this.listId,
    required this.card,
    required this.onList,
    required this.onKeep,
    required this.onSwap,
    required this.onNudge,
    required this.onAddToList,
  });

  final String listId;
  final PlanCard card;
  final bool onList;
  final VoidCallback onKeep;
  final VoidCallback onSwap;
  final VoidCallback onNudge;
  final VoidCallback? onAddToList;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kept = card.status == CardStatus.kept;
    final working = card.status == CardStatus.working;
    return MealIdeaCard(
      idea: card.idea,
      busy: working,
      badge: kept
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(10)),
              child: Text(
                onList ? 'On list' : 'Kept',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimary),
              ),
            )
          : null,
      footer: kept
          ? Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => context.push('/lists/$listId/recipes/${card.recipeId}'),
                  icon: const Icon(Icons.restaurant_menu, size: 18),
                  label: const Text('Saved to Meals'),
                ),
                if (!onList)
                  FilledButton.tonalIcon(
                    onPressed: onAddToList,
                    icon: const Icon(Icons.add_shopping_cart, size: 18),
                    label: const Text('Add to list'),
                  ),
              ],
            )
          : Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: working ? null : onSwap,
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: const Text('Swap'),
                ),
                TextButton.icon(
                  onPressed: working ? null : onNudge,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Nudge'),
                ),
                FilledButton.tonalIcon(
                  onPressed: working ? null : onKeep,
                  icon: const Icon(Icons.favorite_border, size: 18),
                  label: const Text('Keep'),
                ),
              ],
            ),
    );
  }
}

/// Quick ways to rework a meal, plus free text.
class NudgeSheet extends StatefulWidget {
  const NudgeSheet({super.key, required this.appliances});

  final Set<String> appliances;

  @override
  State<NudgeSheet> createState() => _NudgeSheetState();
}

class _NudgeSheetState extends State<NudgeSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quick = [
      'Lighter',
      'Faster',
      'Cheaper',
      'Kid-friendly',
      'More veggies',
      for (final a in widget.appliances.where((a) => a != 'oven' && a != 'stand_mixer' && a != 'blender'))
        'Use the ${applianceLabel(a).toLowerCase()}',
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nudge it how?', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in quick)
                  ActionChip(label: Text(q), onPressed: () => Navigator.pop(context, q.toLowerCase())),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: 'Or tell Lamar, e.g. "no oven tonight"',
                suffixIcon: IconButton(
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  onPressed: () => Navigator.pop(context, _text.text),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileIntro extends StatelessWidget {
  const _ProfileIntro({required this.onStart, required this.onSkip});

  final VoidCallback onStart;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Lamar(width: 110),
            const SizedBox(height: 16),
            Text(
              'Lamar has a few questions first',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Who\'s eating, what you can\'t have, and which gadgets you own. About a minute, and you only do it once.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onStart, child: const Text('Let\'s go')),
            const SizedBox(height: 8),
            TextButton(onPressed: onSkip, child: const Text('Skip for now')),
          ],
        ),
      ),
    );
  }
}

class _ReadyToPlan extends ConsumerWidget {
  const _ReadyToPlan({required this.listId, required this.dinners, required this.onPlan, required this.onList});

  final String listId;
  final int dinners;
  final VoidCallback onPlan;
  final Set<String> onList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final recipes = ref.watch(recipesProvider(listId)).value ?? const <Recipe>[];
    final events = ref.watch(mealEventsProvider(listId)).value ?? const <MealEvent>[];
    final again = makeAgainSuggestions(recipes: recipes, events: events, onList: onList, now: DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
      children: [
        const Center(child: Lamar(width: 110)),
        const SizedBox(height: 16),
        Text(
          'Ready when you are',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Lamar will pitch $dinners dinner${dinners == 1 ? '' : 's'} that share fresh ingredients, so '
          'that half bunch of cilantro doesn\'t go to waste. Keep the ones you like.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(onPressed: onPlan, icon: const Icon(Icons.auto_awesome), label: const Text('Plan my week')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => context.push('/lists/$listId/tonight'),
          icon: const Icon(Icons.kitchen_outlined),
          label: const Text('What can I make tonight?'),
        ),
        if (again.isNotEmpty) ...[
          const SizedBox(height: 32),
          Text('Make again?', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final a in again.take(3)) MakeAgainTile(listId: listId, suggestion: a),
        ],
      ],
    );
  }
}

/// "You haven't made Taco bowls in 3 weeks. Make again?" with a one-tap add.
class MakeAgainTile extends ConsumerStatefulWidget {
  const MakeAgainTile({super.key, required this.listId, required this.suggestion});

  final String listId;
  final MakeAgain suggestion;

  @override
  ConsumerState<MakeAgainTile> createState() => _MakeAgainTileState();
}

class _MakeAgainTileState extends ConsumerState<MakeAgainTile> {
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
    final s = widget.suggestion;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Text(s.liked ? '👍' : '🍽️', style: const TextStyle(fontSize: 24)),
      title: Text(s.recipe.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(lastMadeText(s.since)),
      onTap: () => context.push('/lists/${widget.listId}/recipes/${s.recipe.id}'),
      trailing: IconButton.filledTonal(
        tooltip: 'Put on the list',
        onPressed: _busy ? null : _add,
        icon: const Icon(Icons.add_shopping_cart),
      ),
    );
  }
}

class _LamarSays extends StatelessWidget {
  const _LamarSays({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Lamar(width: 48),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
              ),
            ),
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dancing Lamar with rotating status lines while the model thinks.
class LamarThinking extends StatefulWidget {
  const LamarThinking({super.key, this.lines = _defaultLines});

  final List<String> lines;

  static const _defaultLines = [
    'Lamar is sniffing around the fridge…',
    'Lamar is matching up the cilantro…',
    'Lamar is checking who\'s allergic to what…',
    'Lamar is weighing tacos against curry…',
    'Lamar is nearly there…',
  ];

  @override
  State<LamarThinking> createState() => _LamarThinkingState();
}

class _LamarThinkingState extends State<LamarThinking> {
  late final Timer _timer;
  int _line = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
      if (_line < widget.lines.length - 1) setState(() => _line++);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Lamar(width: 140),
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                widget.lines[_line],
                key: ValueKey(_line),
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
