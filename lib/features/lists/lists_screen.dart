import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/avatars.dart';
import '../../widgets/empty_state.dart';
import '../join/join_link.dart';
import '../notifications/push.dart';
import 'list_form_sheet.dart';

class ListsScreen extends ConsumerWidget {
  const ListsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final result = await showListFormSheet(context);
    if (result == null || !context.mounted) return;
    try {
      final id = await ref.read(repositoryProvider).createList(result.name, result.emoji);
      if (context.mounted) context.go('/lists/$id');
    } catch (e) {
      if (context.mounted) showError(context, friendlyError(e));
    }
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final code = await showDialog<String>(context: context, builder: (_) => const _JoinDialog());
    if (code == null || code.isEmpty || !context.mounted) return;
    try {
      // Accept a pasted invite link as well as a bare code.
      final id = await ref.read(repositoryProvider).joinList(joinCodeFromUri(Uri.tryParse(code) ?? Uri()) ?? code);
      if (context.mounted) context.go('/lists/$id');
      await ref.read(pushServiceProvider).requestPermissionIfNeeded();
    } catch (e) {
      if (context.mounted) showError(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(listsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your lists'),
        actions: [
          IconButton(
            tooltip: 'Join a list',
            icon: const Icon(Icons.group_add_outlined),
            onPressed: () => _join(context, ref),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) {
              if (v == 'account') context.go('/account');
              if (v == 'notifications') context.go('/settings/notifications');
              if (v == 'signout') signOutAndUnregister(ref);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'account', child: Text('Account')),
              PopupMenuItem(value: 'notifications', child: Text('Notifications')),
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New list'),
      ),
      body: switch (lists) {
        AsyncValue(:final value?) when value.isEmpty => EmptyState(
          emoji: '🧺',
          title: 'No lists yet',
          message: 'Make a list for your household, or join one someone shared with you.',
          action: OutlinedButton.icon(
            onPressed: () => _join(context, ref),
            icon: const Icon(Icons.group_add_outlined),
            label: const Text('Join with a code'),
          ),
        ),
        AsyncValue(:final value?) => ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          itemCount: value.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => _ListCard(list: value[i]),
        ),
        AsyncValue(:final error?) => EmptyState(
          emoji: '😕',
          title: 'Couldn\'t load your lists',
          message: friendlyError(error),
          action: FilledButton(onPressed: () => ref.invalidate(listsProvider), child: const Text('Try again')),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _ListCard extends ConsumerWidget {
  const _ListCard({required this.list});

  final ShoppingList list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final items = ref.watch(itemsProvider(list.id)).value ?? const <Item>[];
    final members = ref.watch(membersProvider(list.id)).value ?? const <Member>[];
    final remaining = items.where((i) => !i.checked).length;
    final total = items.length;

    return Card(
      child: InkWell(
        onTap: () => context.go('/lists/${list.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(list.emoji, style: const TextStyle(fontSize: 28)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(list.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      total == 0
                          ? 'Empty'
                          : remaining == 0
                          ? 'All done ✓'
                          : '$remaining to get',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (total > 0) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (total - remaining) / total,
                          minHeight: 4,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (members.length > 1) AvatarStack(members: members, radius: 12, max: 3),
            ],
          ),
        ),
      ),
    );
  }
}

class _JoinDialog extends StatefulWidget {
  const _JoinDialog();

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a list'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, letterSpacing: 6, fontWeight: FontWeight.w700),
        decoration: const InputDecoration(hintText: 'ABC123'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text.trim()), child: const Text('Join')),
      ],
    );
  }
}
