import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/planner_repository.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import 'meal_idea_card.dart';
import 'planner_models.dart';
import 'planner_screen.dart' show LamarThinking;

/// "What can I make tonight?": tick what you have (recently bought items are
/// offered), and Lamar suggests a few dinners that use it up.
class TonightScreen extends ConsumerStatefulWidget {
  const TonightScreen({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<TonightScreen> createState() => _TonightScreenState();
}

class _TonightScreenState extends ConsumerState<TonightScreen> {
  final _input = TextEditingController();

  /// Things they typed in themselves, in order.
  final _typed = <String>[];
  final _selected = <String>{};
  bool _loading = false;
  MealPlan? _ideas;

  /// Idea index -> saved recipe id.
  final _saved = <int, String>{};
  final _saving = <int>{};

  /// Marks the top of the ideas, to scroll them into view when they arrive.
  final _ideasKey = GlobalKey();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final text = _input.text.trim();
    _input.clear();
    if (text.isEmpty) return;
    setState(() {
      if (!_typed.any((t) => t.toLowerCase() == text.toLowerCase())) _typed.add(text);
      _selected.add(text);
    });
  }

  Future<void> _ask() async {
    if (_input.text.trim().isNotEmpty) _add();
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final ideas = await ref.read(plannerRepositoryProvider).tonight(widget.listId, _selected.toList());
      if (mounted) {
        setState(() {
          _ideas = ideas;
          _saved.clear();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _ideasKey.currentContext;
          if (target != null && target.mounted) {
            Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
          }
        });
      }
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(int index, MealIdea idea) async {
    setState(() => _saving.add(index));
    try {
      final id = await ref.read(plannerRepositoryProvider).keepMeal(widget.listId, idea, detail: 'tonight');
      if (!mounted) return;
      setState(() => _saved[index] = id);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${idea.name} saved to Meals'),
            action: SnackBarAction(label: 'View', onPressed: () => context.push('/lists/${widget.listId}/recipes/$id')),
          ),
        );
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving.remove(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = ref.watch(itemsProvider(widget.listId)).value ?? const <Item>[];
    // Recently bought: whatever's been checked off on this list.
    final bought = <String>[];
    for (final i in items.where((i) => i.checked).toList().reversed) {
      if (!bought.any((b) => b.toLowerCase() == i.name.toLowerCase())) bought.add(i.name);
    }
    final offered = [..._typed, ...bought.where((b) => !_typed.any((t) => t.toLowerCase() == b.toLowerCase()))];

    return Scaffold(
      appBar: AppBar(title: const Text('What can I make tonight?')),
      body: _loading
          ? const LamarThinking(
              lines: [
                'Lamar is peering into your fridge…',
                'Lamar is sniffing the spinach…',
                'Lamar is plotting dinner…',
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              children: [
                Text(
                  'Tick what you\'ve got and Lamar will find a dinner that uses it up.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _input,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'Add something, e.g. half a cabbage',
                    suffixIcon: IconButton(tooltip: 'Add', icon: const Icon(Icons.add), onPressed: _add),
                  ),
                  onSubmitted: (_) => _add(),
                ),
                const SizedBox(height: 12),
                if (offered.isEmpty)
                  Text(
                    'Things you check off the shopping list show up here too.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  )
                else ...[
                  if (bought.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('Recently bought', style: theme.textTheme.labelLarge),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final name in offered)
                        FilterChip(
                          label: Text(name),
                          selected: _selected.contains(name),
                          onSelected: (on) => setState(() => on ? _selected.add(name) : _selected.remove(name)),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _selected.isEmpty ? null : _ask,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(_ideas == null ? 'Ask Lamar' : 'Ask again'),
                ),
                if (_ideas != null) ...[
                  SizedBox(key: _ideasKey, height: 24),
                  if (_ideas!.summary.isNotEmpty) ...[
                    Text(_ideas!.summary, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                  ],
                  for (var i = 0; i < _ideas!.meals.length; i++) ...[
                    MealIdeaCard(
                      idea: _ideas!.meals[i],
                      busy: _saving.contains(i),
                      footer: Align(
                        alignment: Alignment.centerLeft,
                        child: _saved.containsKey(i)
                            ? TextButton.icon(
                                onPressed: () => context.push('/lists/${widget.listId}/recipes/${_saved[i]}'),
                                icon: const Icon(Icons.check_circle, size: 18),
                                label: const Text('Saved to Meals'),
                              )
                            : FilledButton.tonalIcon(
                                onPressed: _saving.contains(i) ? null : () => _save(i, _ideas!.meals[i]),
                                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                                label: const Text('Save as a meal'),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            ),
    );
  }
}
