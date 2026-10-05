import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/import_repository.dart';
import '../../data/offline/offline_providers.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../util/categories.dart';
import '../../widgets/avatars.dart';
import '../../widgets/connectivity_banner.dart';
import '../../widgets/empty_state.dart';
import '../import/import_flow.dart';

class ShoppingTab extends ConsumerStatefulWidget {
  const ShoppingTab({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<ShoppingTab> createState() => _ShoppingTabState();
}

class _ShoppingTabState extends ConsumerState<ShoppingTab> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// Optimistic check state, shown until the realtime stream catches up.
  final _pending = <String, bool>{};

  /// Items deleted locally but not yet confirmed gone by the stream. Hidden
  /// at once so the list (and Dismissible, which requires it) updates instantly.
  final _hidden = <String>{};
  bool _showChecked = true;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Repository get _repo => ref.read(repositoryProvider);

  Future<void> _add() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // A pasted recipe link: let Lamar read it instead of adding the URL as an item.
    if (linkIn(text) != null) {
      _input.clear();
      return importToList(context, ref, listId: widget.listId, initialText: text);
    }
    _input.clear();
    _focus.requestFocus();
    try {
      final added = await _repo.addItem(widget.listId, text);
      if (mounted && added.merged) {
        final now = added.quantity == null ? '' : ', so Lamar made it ${added.quantity}';
        showError(context, '${added.name} was already on the list$now');
      }
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    }
  }

  Future<void> _toggle(Item item, bool checked) async {
    HapticFeedback.selectionClick();
    setState(() => _pending[item.id] = checked);
    try {
      await _repo.setChecked(item.id, checked, listId: item.listId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pending.remove(item.id));
      showError(context, friendlyError(e));
    }
  }

  Future<void> _delete(Item item) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _hidden.add(item.id));
    try {
      await _repo.deleteItem(item.id, listId: item.listId);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Removed ${item.name}'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                if (mounted) setState(() => _hidden.remove(item.id));
                _repo.restoreItem(item);
              },
            ),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      setState(() => _hidden.remove(item.id));
      showError(context, friendlyError(e));
    }
  }

  Future<void> _edit(Item item) async {
    final result = await showDialog<({String name, String quantity})>(
      context: context,
      builder: (_) => _EditItemDialog(item: item),
    );
    if (result == null || result.name.isEmpty) return;
    try {
      await _repo.updateItem(item.id, name: result.name, quantity: result.quantity, listId: item.listId);
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    }
  }

  Future<void> _clearChecked(List<Item> done) async {
    final ids = done.map((i) => i.id).toSet();
    setState(() => _hidden.addAll(ids));
    try {
      final n = await _repo.clearChecked(widget.listId, ids: ids);
      if (mounted && n > 0) showError(context, 'Cleared $n item${n == 1 ? '' : 's'}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _hidden.removeAll(ids));
      showError(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(itemsProvider(widget.listId));
    final recipes = ref.watch(recipesProvider(widget.listId)).value ?? const <Recipe>[];
    final members = ref.watch(membersProvider(widget.listId)).value ?? const <Member>[];
    final recipeNames = {for (final r in recipes) r.id: r.name};
    // Merged items can come from several meals; tag them with all of them.
    String? mealTag(Item i) {
      final names = [for (final id in i.recipeIds) ?recipeNames[id]];
      return names.isEmpty ? recipeNames[i.recipeId] : names.join(' + ');
    }

    final membersById = {for (final m in members) m.userId: m};
    final shared = members.length > 1;
    final unsynced = ref.watch(pendingItemIdsProvider(widget.listId)).value ?? const <String>{};

    final raw = itemsAsync.value;
    Widget body;
    if (raw == null) {
      body = itemsAsync.hasError
          ? EmptyState(emoji: '😕', title: 'Couldn\'t load items', message: friendlyError(itemsAsync.error!))
          : const Center(child: CircularProgressIndicator());
    } else {
      // Drop optimistic overrides the server has confirmed.
      final byId = {for (final i in raw) i.id: i};
      _pending.removeWhere((id, v) => byId[id] == null || byId[id]!.checked == v);
      _hidden.removeWhere((id) => !byId.containsKey(id)); // the server confirmed the delete
      final items = [
        for (final i in raw)
          if (!_hidden.contains(i.id)) _pending.containsKey(i.id) ? i.copyWith(checked: _pending[i.id]) : i,
      ];

      final todo = items.where((i) => !i.checked).toList();
      final done = items.where((i) => i.checked).toList();
      final groups = <String, List<Item>>{};
      for (final i in todo) {
        (groups[i.category] ??= []).add(i);
      }
      final orderedCategories = [
        ...categoryOrder.where(groups.containsKey),
        ...groups.keys.where((c) => !categoryOrder.contains(c)),
      ];

      body = items.isEmpty
          ? const EmptyState(
              emoji: '📝',
              title: 'Nothing on the list',
              message: 'Add items below, snap a photo of a list, or add a meal from the Meals tab to pull in its ingredients.',
            )
          : CustomScrollView(
              slivers: [
                if (todo.isNotEmpty) SliverToBoxAdapter(child: _StoreModeButton(listId: widget.listId)),
                if (todo.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 32, 16, 16),
                      child: Center(child: Text('🎉  Everything\'s in the cart', style: TextStyle(fontSize: 16))),
                    ),
                  ),
                if (todo.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Text(
                        'Tap to check off · swipe to remove · press and hold to edit',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                for (final category in orderedCategories) ...[
                  SliverToBoxAdapter(child: _SectionHeader('${categoryEmoji[category] ?? '🛍️'}  $category')),
                  SliverList.list(
                    children: [
                      for (final item in groups[category]!)
                        _ItemTile(
                          key: ValueKey(item.id),
                          item: item,
                          recipeName: mealTag(item),
                          pending: unsynced.contains(item.id),
                          onToggle: (v) => _toggle(item, v),
                          onDelete: () => _delete(item),
                          onEdit: () => _edit(item),
                        ),
                    ],
                  ),
                ],
                if (done.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
                      child: Row(
                        children: [
                          InkWell(
                            onTap: () => setState(() => _showChecked = !_showChecked),
                            child: Row(
                              children: [
                                Text(
                                  'In the cart (${done.length})',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                ),
                                Icon(_showChecked ? Icons.expand_less : Icons.expand_more, size: 20),
                              ],
                            ),
                          ),
                          const Spacer(),
                          TextButton(onPressed: () => _clearChecked(done), child: const Text('Clear')),
                        ],
                      ),
                    ),
                  ),
                  if (_showChecked)
                    SliverList.list(
                      children: [
                        for (final item in done)
                          _ItemTile(
                            key: ValueKey(item.id),
                            item: item,
                            recipeName: mealTag(item),
                            checkedBy: shared ? membersById[item.checkedBy] : null,
                            pending: unsynced.contains(item.id),
                            onToggle: (v) => _toggle(item, v),
                            onDelete: () => _delete(item),
                            onEdit: () => _edit(item),
                          ),
                      ],
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            );
    }

    return Column(
      children: [
        Expanded(child: body),
        _AddBar(
          controller: _input,
          focusNode: _focus,
          onSubmit: _add,
          onImport: () => importToList(context, ref, listId: widget.listId),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    super.key,
    required this.item,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
    this.recipeName,
    this.checkedBy,
    this.pending = false,
  });

  final Item item;
  final String? recipeName;
  final Member? checkedBy;

  /// Has changes that haven't reached the server yet (offline).
  final bool pending;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  /// Long-press: tapping the row checks it off.
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;

    Widget deleteBackground(Alignment side) => Container(
      alignment: side,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      color: scheme.errorContainer,
      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
    );
    // Swipe either way to delete (with Undo); tap to check off; long-press to edit.
    return Dismissible(
      key: ValueKey('dismiss-${item.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDelete(),
      background: deleteBackground(Alignment.centerLeft),
      secondaryBackground: deleteBackground(Alignment.centerRight),
      child: InkWell(
        onTap: () => onToggle(!item.checked),
        onLongPress: onEdit,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Checkbox(value: item.checked, shape: const CircleBorder(), onChanged: (v) => onToggle(v ?? false)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: theme.textTheme.bodyLarge!.copyWith(
                          color: item.checked ? muted : scheme.onSurface,
                          decoration: item.checked ? TextDecoration.lineThrough : null,
                        ),
                        child: Text(item.name),
                      ),
                      if (item.quantity != null || recipeName != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (item.quantity != null)
                                Text(item.quantity!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                              if (recipeName != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: scheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    recipeName!,
                                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (pending) const Padding(padding: EdgeInsets.only(right: 12), child: PendingSyncIcon()),
              if (checkedBy != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Tooltip(
                    message: 'Got by ${checkedBy!.displayName}',
                    child: MemberAvatar(member: checkedBy!, radius: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "I'm at the store": opens store mode for this list.
class _StoreModeButton extends StatelessWidget {
  const _StoreModeButton({required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: () => context.go('/lists/$listId/store'),
        icon: const Icon(Icons.shopping_cart_outlined),
        label: const Text('Switch to shopping view'),
      ),
    );
  }
}

class _AddBar extends StatelessWidget {
  const _AddBar({required this.controller, required this.focusNode, required this.onSubmit, required this.onImport});

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Add an item, e.g. "2 lb chicken"',
                    prefixIcon: Icon(Icons.add),
                  ),
                  onSubmitted: (_) => onSubmit(),
                ),
              ),
              IconButton(
                tooltip: 'Snap or paste a list',
                onPressed: onImport,
                icon: const Icon(Icons.add_a_photo_outlined),
              ),
              IconButton.filled(onPressed: onSubmit, icon: const Icon(Icons.arrow_upward)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditItemDialog extends StatefulWidget {
  const _EditItemDialog({required this.item});

  final Item item;

  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _qty = TextEditingController(text: widget.item.quantity);

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, (name: _name.text.trim(), quantity: _qty.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Item'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _qty,
            decoration: const InputDecoration(labelText: 'Quantity (optional)'),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
