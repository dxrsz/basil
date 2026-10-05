import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/avatars.dart';
import 'presence.dart';

/// A slim strip under the list's app bar: who else has the list open, and a
/// highlight when someone is at the store. Takes no space when you're alone.
///
/// Being on screen is also what makes *you* present on the list.
class PresenceBar extends ConsumerWidget {
  const PresenceBar({super.key, required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(listPresenceProvider(listId));
    final members = ref.watch(membersProvider(listId)).value ?? const <Member>[];
    final byId = {for (final m in members) m.userId: m};

    // Only show people we can name (members); presence can arrive first.
    final here = [
      for (final p in presence.others)
        if (byId[p.userId] != null) (member: byId[p.userId]!, shopping: p.shopping),
    ];
    final shoppers = [
      for (final h in here)
        if (h.shopping) h.member,
    ];

    final Widget child;
    if (here.isEmpty) {
      child = const SizedBox(width: double.infinity);
    } else {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final shopping = shoppers.isNotEmpty;
      final fg = shopping ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
      child = Material(
        key: const ValueKey('presence-bar'),
        color: shopping ? scheme.tertiaryContainer : scheme.surfaceContainerLow,
        child: Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                AvatarStack(members: [for (final h in here) h.member], radius: 11, max: 4),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    shopping ? shoppingLine(shoppers) : hereLine([for (final h in here) h.member]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: shopping ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: child),
    );
  }
}

String _first(Member m) {
  final n = m.displayName.trim();
  return n.isEmpty ? 'Someone' : n.split(RegExp(r'\s+')).first;
}

/// "Sam is at the store 🛒", "Sam and Alex are at the store 🛒", …
String shoppingLine(List<Member> shoppers) => switch (shoppers.length) {
  1 => '${_first(shoppers[0])} is at the store 🛒',
  2 => '${_first(shoppers[0])} and ${_first(shoppers[1])} are at the store 🛒',
  _ => '${_first(shoppers[0])} and ${shoppers.length - 1} others are at the store 🛒',
};

/// "Sam is here too", "Sam and Alex are here too", "3 others are here too".
String hereLine(List<Member> here) => switch (here.length) {
  1 => '${_first(here[0])} is here too',
  2 => '${_first(here[0])} and ${_first(here[1])} are here too',
  _ => '${here.length} others are here too',
};
