import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/avatars.dart';
import '../join/join_link.dart';
import '../notifications/push.dart';

void showShareSheet(BuildContext context, ShoppingList list) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ShareSheet(list: list),
  );
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.list});

  final ShoppingList list;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  late final Future<String> _code = ref.read(repositoryProvider).createInvite(widget.list.id);

  String _message(String code) =>
      'Join my "${widget.list.name}" list on Lamar\'s Groceries 🐈‍⬛\n${inviteLink(code)}\n\n'
      'Or open the app, tap "Join a list" and enter: $code';

  Future<void> _send(String code) async {
    await SharePlus.instance.share(ShareParams(text: _message(code)));
    // Sharing a list is when notifications start to matter; ask (once).
    await ref.read(pushServiceProvider).requestPermissionIfNeeded();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final members = ref.watch(membersProvider(widget.list.id)).value ?? const <Member>[];
    final me = ref.watch(currentUserIdProvider);
    final iAmOwner = widget.list.ownerId == me;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share "${widget.list.name}"', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Anyone with the link or code can view and edit the list. Invites expire after 7 days.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FutureBuilder<String>(
              future: _code,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text(friendlyError(snap.error!), style: TextStyle(color: scheme.error));
                }
                final code = snap.data;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: code == null
                          ? const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2))
                          : SelectableText(
                              code,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                letterSpacing: 8,
                                fontWeight: FontWeight.w800,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                    ),
                    if (code != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        inviteLink(code).replaceFirst('https://', ''),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: code == null
                                ? null
                                : () {
                                    Clipboard.setData(ClipboardData(text: inviteLink(code)));
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(const SnackBar(content: Text('Invite link copied')));
                                  },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy link'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: code == null ? null : () => _send(code),
                            icon: const Icon(Icons.ios_share),
                            label: const Text('Send invite'),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            Text('People (${members.length})', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final m in members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: MemberAvatar(member: m, radius: 18),
                title: Text(m.userId == me ? '${m.displayName} (you)' : m.displayName),
                subtitle: Text(m.isOwner ? 'Owner' : 'Can edit'),
                trailing: iAmOwner && m.userId != me
                    ? IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () => ref.read(repositoryProvider).removeMember(widget.list.id, m.userId),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
