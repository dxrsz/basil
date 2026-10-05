import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/lamar.dart';
import 'tidy_logic.dart';

/// "Tidy up": Lamar reviews the unchecked items and proposes merges and
/// fixes, which the person accepts or rejects one by one. Nothing changes
/// until they tap Apply. Shows a snackbar with the result.
Future<void> showTidySheet(BuildContext context, String listId) async {
  final messenger = ScaffoldMessenger.of(context);
  final applied = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => TidySheet(listId: listId),
  );
  if (applied != null && applied > 0) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Lamar tidied up $applied thing${applied == 1 ? '' : 's'} 🧹')));
  }
}

class TidySheet extends ConsumerStatefulWidget {
  const TidySheet({super.key, required this.listId, this.askLamar});

  final String listId;

  /// Fetches AI proposals; defaults to the `tidy-list` edge function.
  final Future<List<TidyProposal>> Function()? askLamar;

  @override
  ConsumerState<TidySheet> createState() => _TidySheetState();
}

class _TidySheetState extends ConsumerState<TidySheet> {
  List<TidyProposal>? _proposals;
  final _accepted = <TidyProposal>{};

  /// Why the AI part failed (rate limit, offline…); exact duplicates still show.
  String? _aiError;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<Item> items;
    try {
      items = await readFirst(ref, itemsProvider(widget.listId));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _proposals = const [];
        _aiError = friendlyError(e);
      });
      return;
    }
    final local = exactDuplicateProposals(items);
    var ai = const <TidyProposal>[];
    String? aiError;
    if (items.where((i) => !i.checked).length >= 2) {
      try {
        ai = await (widget.askLamar ?? () => ref.read(repositoryProvider).proposeTidy(widget.listId))();
      } catch (e) {
        aiError = friendlyError(e);
      }
    }
    if (!mounted) return;
    // Re-read: the list may have changed while Lamar was thinking.
    final now = ref.read(itemsProvider(widget.listId)).value ?? items;
    final all = combineProposals(local, ai, now);
    setState(() {
      _proposals = all;
      _accepted.addAll(all);
      _aiError = aiError;
    });
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    try {
      final n = await ref.read(repositoryProvider).applyTidy(widget.listId, _accepted.toList());
      if (mounted) Navigator.pop(context, n);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      showError(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final proposals = _proposals;
    final items = {for (final i in ref.watch(itemsProvider(widget.listId)).value ?? const <Item>[]) i.id: i};

    Widget body;
    if (proposals == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Lamar(width: 96),
            const SizedBox(height: 16),
            Text('Lamar is tidying up…', style: theme.textTheme.titleMedium),
          ],
        ),
      );
    } else if (proposals.isEmpty) {
      body = EmptyState(
        emoji: _aiError == null ? '🧹' : '😿',
        title: _aiError == null ? 'Already tidy!' : 'Lamar couldn\'t tidy up',
        message: _aiError ?? 'Lamar looked everything over. No duplicates, nothing to fix.',
      );
    } else {
      body = ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          if (_aiError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_aiError!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
            ),
          for (final p in proposals)
            _ProposalCard(
              proposal: p,
              items: items,
              accepted: _accepted.contains(p),
              onChanged: (v) => setState(() => v ? _accepted.add(p) : _accepted.remove(p)),
            ),
        ],
      );
    }

    final count = _accepted.length;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text('Tidy up', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
          if (proposals != null && proposals.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Lamar found ${proposals.length} thing${proposals.length == 1 ? '' : 's'} to tidy. '
                'Uncheck anything you\'d rather keep as is.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          Flexible(child: body),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(proposals == null || proposals.isEmpty ? 'Close' : 'Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (proposals != null && proposals.isNotEmpty)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: count == 0 || _applying ? null : _apply,
                        icon: _applying
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_fix_high),
                        label: Text(
                          count == proposals.length && count > 1 ? 'Apply all $count' : 'Apply $count',
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

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({required this.proposal, required this.items, required this.accepted, required this.onChanged});

  final TidyProposal proposal;
  final Map<String, Item> items;
  final bool accepted;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      decoration: TextDecoration.lineThrough,
    );
    String label(String name, String? qty) => qty == null || qty.isEmpty ? name : '$name · $qty';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: accepted ? scheme.secondaryContainer.withValues(alpha: 0.5) : scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onChanged(!accepted),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(value: accepted, onChanged: (v) => onChanged(v ?? false)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final id in proposal.itemIds)
                        if (items[id] != null) Text(label(items[id]!.name, items[id]!.quantity), style: muted),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.subdirectory_arrow_right, size: 18, color: scheme.primary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              label(proposal.name, proposal.quantity),
                              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      if (proposal.reason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            proposal.reason,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
