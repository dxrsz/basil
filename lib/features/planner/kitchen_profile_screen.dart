import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/planner_repository.dart';
import '../../data/repository.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/lamar.dart';
import 'planner_models.dart';

/// Lamar's one-minute kitchen interview: one question per screen, mostly
/// taps. Personal answers (diet, dislikes, tastes) are saved to the user;
/// household answers (who's eating, effort, appliances) to the list.
class KitchenProfileScreen extends ConsumerWidget {
  const KitchenProfileScreen({super.key, required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taste = ref.watch(tasteProfileProvider);
    final kitchen = ref.watch(kitchenSettingsProvider(listId));
    if (taste.hasError || kitchen.hasError) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          emoji: '😕',
          title: 'Lamar lost his notes',
          message: friendlyError(taste.error ?? kitchen.error!),
        ),
      );
    }
    if (!taste.hasValue || !kitchen.hasValue) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return KitchenProfileForm(
      listId: listId,
      initialTaste: taste.value ?? const TasteProfile(),
      initialKitchen: kitchen.value ?? const KitchenSettings(),
    );
  }
}

class KitchenProfileForm extends ConsumerStatefulWidget {
  const KitchenProfileForm({super.key, required this.listId, required this.initialTaste, required this.initialKitchen});

  final String listId;
  final TasteProfile initialTaste;
  final KitchenSettings initialKitchen;

  @override
  ConsumerState<KitchenProfileForm> createState() => _KitchenProfileFormState();
}

class _KitchenProfileFormState extends ConsumerState<KitchenProfileForm> {
  static const _pageCount = 6;

  final _pages = PageController();
  final _dislikeInput = TextEditingController();
  late TasteProfile _taste = widget.initialTaste;
  late KitchenSettings _kitchen = widget.initialKitchen;
  int _page = 0;
  bool _saving = false;

  @override
  void dispose() {
    _pages.dispose();
    _dislikeInput.dispose();
    super.dispose();
  }

  void _go(int page) {
    FocusScope.of(context).unfocus();
    setState(() => _page = page);
    _pages.animateToPage(page, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  Future<void> _finish() async {
    if (_dislikeInput.text.trim().isNotEmpty) _addDislike();
    setState(() => _saving = true);
    final repo = ref.read(plannerRepositoryProvider);
    try {
      await Future.wait([repo.saveTasteProfile(_taste), repo.saveKitchenSettings(widget.listId, _kitchen)]);
      ref.invalidate(tasteProfileProvider);
      ref.invalidate(kitchenSettingsProvider(widget.listId));
      if (!mounted) return;
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go('/lists/${widget.listId}/plan');
      }
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addDislike() {
    var text = _dislikeInput.text.trim();
    text = text.replaceFirst(RegExp(r'^no\s+', caseSensitive: false), '').trim();
    _dislikeInput.clear();
    if (text.isEmpty || _taste.dislikes.any((d) => d.toLowerCase() == text.toLowerCase())) return;
    setState(() => _taste = _taste.copyWith(dislikes: [..._taste.dislikes, text]));
  }

  Set<String> _toggle(Set<String> set, String key, bool on) => on ? {...set, key} : ({...set}..remove(key));

  @override
  Widget build(BuildContext context) {
    final last = _page == _pageCount - 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kitchen profile'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_page + 1) / _pageCount),
        ),
      ),
      body: PageView(
        controller: _pages,
        physics: const NeverScrollableScrollPhysics(),
        children: [_who(), _diet(), _effort(), _appliances(), _wantMore(), _tastes()],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              if (_page > 0) TextButton(onPressed: _saving ? null : () => _go(_page - 1), child: const Text('Back')),
              const Spacer(),
              FilledButton(
                onPressed: _saving ? null : (last ? _finish : () => _go(_page + 1)),
                child: _saving
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(last ? 'All done' : 'Next'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- questions

  Widget _who() => _Question(
    lamar: true,
    title: 'Who\'s eating?',
    subtitle: 'Lamar plans portions for everyone at the table (cats not included, sadly).',
    children: [
      const _Label('People at dinner'),
      Row(
        children: [
          IconButton.filledTonal(
            tooltip: 'Fewer',
            onPressed: _kitchen.householdSize > 1
                ? () => setState(() => _kitchen = _kitchen.copyWith(householdSize: _kitchen.householdSize - 1))
                : null,
            icon: const Icon(Icons.remove),
          ),
          Expanded(
            child: Text(
              '${_kitchen.householdSize}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'More',
            onPressed: _kitchen.householdSize < 12
                ? () => setState(() => _kitchen = _kitchen.copyWith(householdSize: _kitchen.householdSize + 1))
                : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const _Label('Dinners to plan each week'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var n = 1; n <= 7; n++)
            ChoiceChip(
              label: Text('$n'),
              selected: _kitchen.dinnersPerWeek == n,
              onSelected: (_) => setState(() => _kitchen = _kitchen.copyWith(dinnersPerWeek: n)),
            ),
        ],
      ),
    ],
  );

  Widget _diet() => _Question(
    title: 'Any diets or allergies?',
    subtitle: 'Just yours. Lamar combines everyone\'s on a shared list, so nobody gets something they can\'t eat.',
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in dietChoices)
            FilterChip(
              label: Text('${c.emoji} ${c.label}'),
              selected: _taste.diets.contains(c.key),
              onSelected: (on) => setState(() => _taste = _taste.copyWith(diets: _toggle(_taste.diets, c.key, on))),
            ),
        ],
      ),
      const SizedBox(height: 24),
      const _Label('Anything you won\'t eat?'),
      TextField(
        controller: _dislikeInput,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          hintText: 'e.g. no mushrooms',
          suffixIcon: IconButton(tooltip: 'Add', icon: const Icon(Icons.add), onPressed: _addDislike),
        ),
        onSubmitted: (_) => _addDislike(),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final d in _taste.dislikes)
            InputChip(
              label: Text('No $d'),
              onDeleted: () => setState(() => _taste = _taste.copyWith(dislikes: [..._taste.dislikes]..remove(d))),
            ),
        ],
      ),
    ],
  );

  Widget _effort() => _Question(
    title: 'How much time on a weeknight?',
    subtitle: 'Lamar keeps the bigger cooking projects for the weekend.',
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (minutes, label) in const [(15, '⚡ 15 min'), (30, '⏲️ 30 min'), (45, '🧑‍🍳 45+ min')])
            ChoiceChip(
              label: Text(label),
              selected: _kitchen.timeBudget == minutes,
              onSelected: (_) => setState(() => _kitchen = _kitchen.copyWith(timeBudget: minutes)),
            ),
        ],
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Leftovers welcome'),
        subtitle: const Text('Cook once, eat twice'),
        value: _kitchen.leftovers,
        onChanged: (v) => setState(() => _kitchen = _kitchen.copyWith(leftovers: v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Batch-cook on Sundays'),
        subtitle: const Text('Prep ahead for busy nights'),
        value: _kitchen.batchCook,
        onChanged: (v) => setState(() => _kitchen = _kitchen.copyWith(batchCook: v)),
      ),
    ],
  );

  Widget _appliances() => _Question(
    title: 'What\'s in your kitchen?',
    subtitle: 'Tap everything you have. Lamar assumes a stovetop.',
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in applianceChoices)
            FilterChip(
              label: Text('${c.emoji} ${c.label}'),
              selected: _kitchen.appliances.contains(c.key),
              onSelected: (on) =>
                  setState(() => _kitchen = _kitchen.copyWith(appliances: _toggle(_kitchen.appliances, c.key, on))),
            ),
        ],
      ),
    ],
  );

  Widget _wantMore() {
    final have = applianceChoices.where((c) => _kitchen.appliances.contains(c.key)).toList();
    return _Question(
      title: 'Any you\'d like to use more?',
      subtitle: 'That air fryer gathering dust? Lamar will work it into the week.',
      children: [
        if (have.isEmpty)
          Text(
            'Pick some appliances on the last screen first, or skip this one.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in have)
              FilterChip(
                label: Text('${c.emoji} ${c.label}'),
                selected: _kitchen.wantMore.contains(c.key),
                onSelected: (on) =>
                    setState(() => _kitchen = _kitchen.copyWith(wantMore: _toggle(_kitchen.wantMore, c.key, on))),
              ),
          ],
        ),
      ],
    );
  }

  Widget _tastes() {
    final theme = Theme.of(context);
    return _Question(
      title: 'What do you love to eat?',
      subtitle: 'Pick a few favourites. Lamar will mix things up from there.',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in cuisineChoices)
              FilterChip(
                label: Text('${c.emoji} ${c.label}'),
                selected: _taste.cuisines.contains(c.key),
                onSelected: (on) =>
                    setState(() => _taste = _taste.copyWith(cuisines: _toggle(_taste.cuisines, c.key, on))),
              ),
          ],
        ),
        const SizedBox(height: 24),
        const _Label('Spice'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < spiceLabels.length; i++)
              ChoiceChip(
                label: Text('${'🌶️' * i}${i == 0 ? '🧊' : ''} ${spiceLabels[i]}'),
                selected: _taste.spice == i,
                onSelected: (_) => setState(() => _taste = _taste.copyWith(spice: i)),
              ),
          ],
        ),
        const SizedBox(height: 24),
        const _Label('Comfort food or something new?'),
        Slider(
          value: _taste.adventurous.toDouble(),
          max: 100,
          divisions: 4,
          label: switch (_taste.adventurous) {
            < 25 => 'Classics, please',
            < 50 => 'Mostly familiar',
            < 75 => 'A bit of both',
            < 100 => 'Mostly new',
            _ => 'Surprise me',
          },
          onChanged: (v) => setState(() => _taste = _taste.copyWith(adventurous: v.round())),
        ),
        Row(
          children: [
            Expanded(child: Text('🛋️ Comfort', style: theme.textTheme.labelMedium)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Adventurous 🧭', style: theme.textTheme.labelMedium, textAlign: TextAlign.end),
            ),
          ],
        ),
      ],
    );
  }
}

class _Question extends StatelessWidget {
  const _Question({required this.title, required this.subtitle, required this.children, this.lamar = false});

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool lamar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lamar) ...[const Center(child: Lamar(width: 72)), const SizedBox(height: 12)],
          Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
  );
}
