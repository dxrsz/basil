import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/offline/offline_providers.dart';

/// A quiet strip that appears while offline ("Lamar will sync when you're
/// back") and says "Synced ✓" for a moment once everything has gone out.
/// Takes no space when all is well.
class ConnectivityBanner extends ConsumerWidget {
  const ConnectivityBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncStateProvider);
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium;

    Widget? content;
    if (!sync.online) {
      final waiting = sync.pending == 0 ? '' : ' · ${sync.pending} change${sync.pending == 1 ? '' : 's'} waiting';
      content = _Strip(
        key: const ValueKey('offline'),
        color: scheme.surfaceContainerHighest,
        foreground: scheme.onSurface,
        icon: Icons.cloud_off_outlined,
        text: 'Offline — Lamar will sync when you\'re back$waiting',
        style: textStyle,
      );
    } else if (sync.pending > 0) {
      content = _Strip(
        key: const ValueKey('syncing'),
        color: scheme.surfaceContainerHigh,
        foreground: scheme.onSurfaceVariant,
        icon: Icons.cloud_upload_outlined,
        text: 'Back online — syncing ${sync.pending} change${sync.pending == 1 ? '' : 's'}…',
        style: textStyle,
      );
    } else if (sync.justSynced) {
      content = _Strip(
        key: const ValueKey('synced'),
        color: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        icon: Icons.cloud_done_outlined,
        text: 'Synced ✓',
        style: textStyle,
      );
    }

    return Semantics(
      liveRegion: true,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: content ?? const SizedBox(key: ValueKey('none'), width: double.infinity),
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    super.key,
    required this.color,
    required this.foreground,
    required this.icon,
    required this.text,
    required this.style,
  });

  final Color color;
  final Color foreground;
  final IconData icon;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: style?.copyWith(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "not synced yet" marker for an item with queued changes.
class PendingSyncIcon extends StatelessWidget {
  const PendingSyncIcon({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Waiting to sync',
      child: Icon(
        Icons.cloud_upload_outlined,
        size: size,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        semanticLabel: 'Waiting to sync',
      ),
    );
  }
}
