import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import 'pantry_data.dart';
import 'pantry_logic.dart';

/// See and edit what this list's household said it already has.
Future<void> showPantrySheet(BuildContext context, String listId) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => PantrySheet(listId: listId),
);

class PantrySheet extends ConsumerStatefulWidget {
  const PantrySheet({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<PantrySheet> createState() => _PantrySheetState();
}

class _PantrySheetState extends ConsumerState<PantrySheet> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Repository get _repo => ref.read(repositoryProvider);

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    }
  }

  void _add() {
    final name = _input.text.trim();
    if (name.isEmpty) return;
    _input.clear();
    _run(() => _repo.addPantryStaple(widget.listId, name));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pantry = ref.watch(pantryProvider(widget.listId));
    final now = DateTime.now();
    final staples = [...?pantry.value]
      ..sort((a, b) => a.always == b.always ? a.nameKey.compareTo(b.nameKey) : (a.always ? -1 : 1));

    Widget list;
    if (pantry.value == null) {
      list = pantry.hasError
          ? EmptyState(emoji: '😕', title: 'Couldn\'t load the pantry', message: friendlyError(pantry.error!))
          : const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
    } else if (staples.isEmpty) {
      list = const EmptyState(
        emoji: '🥫',
        title: 'Nothing noted yet',
        message: 'Say "Got it" when adding a meal, or add things you always keep around.',
      );
    } else {
      list = ListView(
        shrinkWrap: true,
        children: [for (final s in staples) _StapleTile(staple: s, now: now, run: _run)],
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text('Pantry', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'When you add a meal, Lamar leaves these off the list. He already assumes basics like oil, '
                'salt and spices, and asks again about anything not confirmed in ${pantryMemory.inDays} days '
                'unless it\'s pinned.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Flexible(child: list),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          hintText: 'We always have…',
                          prefixIcon: Icon(Icons.push_pin_outlined),
                        ),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filled(tooltip: 'Add', onPressed: _add, icon: const Icon(Icons.add)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StapleTile extends ConsumerWidget {
  const _StapleTile({required this.staple, required this.now, required this.run});

  final PantryStaple staple;
  final DateTime now;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final age = now.difference(staple.confirmedAt);
    final days = age.inDays;
    final subtitle = staple.always
        ? 'Always have'
        : age >= pantryMemory
        ? 'Last confirmed $days days ago · Lamar will ask again'
        : 'Got it ${days == 0
              ? 'today'
              : days == 1
              ? 'yesterday'
              : '$days days ago'}';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 24, right: 8),
      title: Text(staple.name),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: staple.always ? 'Unpin' : 'Always have',
            isSelected: staple.always,
            color: staple.always ? scheme.primary : null,
            icon: const Icon(Icons.push_pin_outlined),
            selectedIcon: const Icon(Icons.push_pin),
            onPressed: () => run(() => ref.read(repositoryProvider).setPantryAlways(staple.id, !staple.always)),
          ),
          IconButton(
            tooltip: 'Forget',
            icon: const Icon(Icons.close),
            onPressed: () => run(() => ref.read(repositoryProvider).deletePantryStaple(staple.id)),
          ),
        ],
      ),
    );
  }
}
