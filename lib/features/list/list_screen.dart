import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../widgets/avatars.dart';
import '../../widgets/empty_state.dart';
import '../lists/list_form_sheet.dart';
import 'recipes_tab.dart';
import 'share_sheet.dart';
import 'shopping_tab.dart';

class ListScreen extends ConsumerStatefulWidget {
  const ListScreen({super.key, required this.listId, this.initialTab = 0});

  final String listId;
  final int initialTab;

  @override
  ConsumerState<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends ConsumerState<ListScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialTab)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _menu(String action) async {
    final repo = ref.read(repositoryProvider);
    final list = ref.read(listProvider(widget.listId));
    if (list == null) return;
    try {
      switch (action) {
        case 'edit':
          final result = await showListFormSheet(context, initialName: list.name, initialEmoji: list.emoji);
          if (result != null) await repo.updateList(list.id, name: result.name, emoji: result.emoji);
        case 'leave':
          if (await _confirm('Leave "${list.name}"?', 'You can rejoin later with an invite code.', 'Leave')) {
            await repo.leaveList(list.id);
            if (mounted) context.go('/');
          }
        case 'delete':
          if (await _confirm(
            'Delete "${list.name}"?',
            'This removes the list, its items and recipes for everyone it\'s shared with.',
            'Delete',
          )) {
            await repo.deleteList(list.id);
            if (mounted) context.go('/');
          }
      }
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    }
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(listProvider(widget.listId));
    final members = ref.watch(membersProvider(widget.listId)).value ?? const [];
    final isOwner = list != null && list.ownerId == ref.watch(currentUserIdProvider);

    if (list == null) {
      final loading = ref.watch(listsProvider).isLoading;
      return Scaffold(
        appBar: AppBar(),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(emoji: '🫥', title: 'List not found', message: 'It may have been deleted, or you left it.'),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${list.emoji}  ${list.name}', overflow: TextOverflow.ellipsis),
        actions: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => showShareSheet(context, list),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: members.length > 1
                  ? AvatarStack(members: members, radius: 12, max: 3)
                  : const Icon(Icons.person_add_alt_1_outlined),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Rename')),
              if (!isOwner) const PopupMenuItem(value: 'leave', child: Text('Leave list')),
              if (isOwner) const PopupMenuItem(value: 'delete', child: Text('Delete list')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.checklist_rounded), text: 'Shopping'),
            Tab(icon: Icon(Icons.restaurant_menu), text: 'Meals'),
          ],
        ),
      ),
      floatingActionButton: _tabs.index == 1
          ? FloatingActionButton.extended(
              onPressed: () => context.go('/lists/${list.id}/recipes/new'),
              icon: const Icon(Icons.add),
              label: const Text('New meal'),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          ShoppingTab(listId: list.id),
          RecipesTab(listId: list.id),
        ],
      ),
    );
  }
}
