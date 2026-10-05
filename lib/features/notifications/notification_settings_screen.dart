import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../data/sharing_repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import 'push.dart';

final notificationSettingsProvider = FutureProvider.autoDispose<NotificationSettings>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(sharingRepositoryProvider).fetchSettings();
});

final mutedListIdsProvider = FutureProvider.autoDispose<Set<String>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(sharingRepositoryProvider).fetchMutedListIds();
});

/// `/settings/notifications`: what Lamar pings you about, and which lists to
/// keep quiet.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen> {
  // Optimistic local copies so switches respond instantly.
  NotificationSettings? _settings;
  Set<String>? _muted;

  Future<void> _save(NotificationSettings next) async {
    final before = _settings;
    setState(() => _settings = next);
    try {
      await ref.read(sharingRepositoryProvider).saveSettings(next);
      if (next.enabled) await ref.read(pushServiceProvider).requestPermissionIfNeeded();
    } catch (e) {
      if (!mounted) return;
      setState(() => _settings = before);
      showError(context, friendlyError(e));
    }
  }

  Future<void> _mute(Set<String> before, String listId, bool muted) async {
    setState(() => _muted = muted ? {...before, listId} : ({...before}..remove(listId)));
    try {
      await ref.read(sharingRepositoryProvider).setListMuted(listId, muted);
    } catch (e) {
      if (!mounted) return;
      setState(() => _muted = before);
      showError(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loaded = ref.watch(notificationSettingsProvider);
    final mutedLoaded = ref.watch(mutedListIdsProvider);
    final lists = ref.watch(listsProvider).value ?? const <ShoppingList>[];
    final pushAvailable = ref.watch(pushServiceProvider).available;

    final error = loaded.error ?? mutedLoaded.error;
    if (error != null && _settings == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: EmptyState(
          emoji: '😿',
          title: 'Couldn\'t load your settings',
          message: friendlyError(error),
          action: FilledButton(
            onPressed: () => ref
              ..invalidate(notificationSettingsProvider)
              ..invalidate(mutedListIdsProvider),
            child: const Text('Try again'),
          ),
        ),
      );
    }
    final settings = _settings ?? loaded.value;
    final muted = _muted ?? mutedLoaded.value;
    if (settings == null || muted == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final on = settings.enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (!pushAvailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Card(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const ListTile(
                  leading: Text('🐈‍⬛', style: TextStyle(fontSize: 24)),
                  title: Text('Push isn\'t available on this device yet'),
                  subtitle: Text('Your choices here still apply on your phone.'),
                ),
              ),
            ),
          SwitchListTile(
            title: const Text('Push notifications'),
            subtitle: const Text('Lamar only meows when it matters.'),
            value: on,
            onChanged: (v) => _save(settings.copyWith(enabled: v)),
          ),
          const Divider(),
          _Header('Tell me when'),
          SwitchListTile(
            secondary: const Text('🛒', style: TextStyle(fontSize: 22)),
            title: const Text('Someone heads to the store'),
            subtitle: const Text('So you can add what you need'),
            value: settings.shopping,
            onChanged: on ? (v) => _save(settings.copyWith(shopping: v)) : null,
          ),
          SwitchListTile(
            secondary: const Text('📝', style: TextStyle(fontSize: 22)),
            title: const Text('Someone adds things'),
            subtitle: const Text('Bundled, never one ping per item'),
            value: settings.itemsAdded,
            onChanged: on ? (v) => _save(settings.copyWith(itemsAdded: v)) : null,
          ),
          SwitchListTile(
            secondary: const Text('👋', style: TextStyle(fontSize: 22)),
            title: const Text('Someone joins a list'),
            value: settings.memberJoined,
            onChanged: on ? (v) => _save(settings.copyWith(memberJoined: v)) : null,
          ),
          if (lists.isNotEmpty) ...[
            const Divider(),
            _Header('Lists'),
            for (final l in lists)
              SwitchListTile(
                secondary: Text(l.emoji, style: const TextStyle(fontSize: 22)),
                title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(muted.contains(l.id) ? 'Muted' : 'Notifying'),
                value: !muted.contains(l.id),
                onChanged: on ? (v) => _mute(muted, l.id, !v) : null,
              ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}
