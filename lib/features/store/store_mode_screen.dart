import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/offline/offline_providers.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../util/categories.dart';
import '../../widgets/connectivity_banner.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/lamar.dart';
import 'store_mode.dart';

/// "I'm at the store": the list as a big, one-handed checklist. Tap anywhere
/// on a row to put it in the cart; it slides away into a collapsed "In the
/// cart" section. When the last thing is in, Lamar dances.
class StoreModeScreen extends ConsumerStatefulWidget {
  const StoreModeScreen({super.key, required this.listId});

  final String listId;

  @override
  ConsumerState<StoreModeScreen> createState() => _StoreModeScreenState();
}

class _StoreModeScreenState extends ConsumerState<StoreModeScreen> {
  /// Just checked and sliding out, as they looked when tapped.
  final _leaving = <String, Item>{};
  var _cartOpen = false;

  /// "Something missing?" from the celebration: show the list instead.
  var _keepShopping = false;
  var _celebrated = false;

  late final StoreModeNotifier _storeMode;
  late final ScreenAwake _awake;

  @override
  void initState() {
    super.initState();
    _storeMode = ref.read(isInStoreModeProvider(widget.listId).notifier);
    _awake = ref.read(screenAwakeProvider);
    unawaited(_awake.set(true));
    // Providers can't change while the tree is building.
    Future.microtask(_storeMode.enter);
  }

  @override
  void dispose() {
    unawaited(_awake.set(false));
    final storeMode = _storeMode;
    Future.microtask(() {
      try {
        storeMode.exit();
      } catch (_) {
        // The app (and its providers) went away first.
      }
    });
    super.dispose();
  }

  Repository get _repo => ref.read(repositoryProvider);

  void _check(Item item) {
    HapticFeedback.mediumImpact();
    setState(() {
      _leaving[item.id] = item;
      _keepShopping = false;
    });
    _set(item, true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${item.name} is in the cart'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(label: 'Undo', onPressed: () => _uncheck(item)),
        ),
      );
  }

  void _uncheck(Item item) {
    HapticFeedback.selectionClick();
    if (mounted) setState(() => _leaving.remove(item.id));
    _set(item, false);
  }

  Future<void> _set(Item item, bool checked) async {
    try {
      await _repo.setChecked(item.id, checked, listId: item.listId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _leaving.remove(item.id));
      showError(context, friendlyError(e));
    }
  }

  void _left(String id) {
    if (mounted) setState(() => _leaving.remove(id));
  }

  Future<void> _finish({required List<Item> clear}) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (clear.isNotEmpty) {
      try {
        await _repo.clearChecked(widget.listId, ids: clear.map((i) => i.id));
      } catch (e) {
        if (mounted) showError(context, friendlyError(e));
        return;
      }
    }
    if (mounted) _exit();
  }

  void _exit() {
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      Navigator.of(context).maybePop();
    } else if (router.canPop()) {
      router.pop();
    } else {
      router.go('/lists/${widget.listId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(listProvider(widget.listId));
    final itemsAsync = ref.watch(itemsProvider(widget.listId));
    final pending = ref.watch(pendingItemIdsProvider(widget.listId)).value ?? const <String>{};

    Widget body;
    Widget? progress;
    final items = itemsAsync.value;
    if (items == null) {
      body = itemsAsync.hasError
          ? EmptyState(emoji: '😕', title: 'Couldn\'t load the list', message: friendlyError(itemsAsync.error!))
          : const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      body = EmptyState(
        emoji: '🧺',
        title: 'Nothing to shop for',
        message: 'Add a few things to the list first. I\'ll wait right here.',
        action: OutlinedButton(onPressed: _exit, child: const Text('Back to the list')),
      );
    } else {
      final toGet = [
        for (final i in items)
          if (_leaving.containsKey(i.id)) _leaving[i.id]! else if (!i.checked) i,
      ];
      final inCart = [
        for (final i in items)
          if (i.checked && !_leaving.containsKey(i.id)) i,
      ];
      final done = items.where((i) => i.checked || _leaving.containsKey(i.id)).length;
      progress = _Progress(done: done, total: items.length);

      final celebrate = toGet.isEmpty && !_keepShopping;
      if (celebrate && !_celebrated) {
        _celebrated = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => HapticFeedback.heavyImpact());
      } else if (!celebrate) {
        _celebrated = false;
      }

      body = celebrate
          ? _Celebration(
              line: _lamarLines[items.length % _lamarLines.length],
              onClearAndFinish: () => _finish(clear: inCart),
              onFinish: () => _finish(clear: const []),
              onKeepShopping: () => setState(() {
                _keepShopping = true;
                _cartOpen = true;
              }),
            )
          : _buildList(toGet, inCart, pending);
    }

    return Scaffold(
      appBar: AppBar(
        leading: CloseButton(onPressed: _exit),
        title: Text(list == null ? 'Shopping view' : '${list.emoji}  ${list.name}', overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          const ConnectivityBanner(),
          ?progress,
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _buildList(List<Item> toGet, List<Item> inCart, Set<String> pending) {
    final groups = <String, List<Item>>{};
    for (final i in toGet) {
      (groups[i.category] ??= []).add(i);
    }
    final categories = [
      ...categoryOrder.where(groups.containsKey),
      ...groups.keys.where((c) => !categoryOrder.contains(c)),
    ];

    return CustomScrollView(
      slivers: [
        if (toGet.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 32, 16, 8),
              child: Center(child: Text('🎉  Everything\'s in the cart', style: TextStyle(fontSize: 18))),
            ),
          ),
        for (final category in categories) ...[
          SliverToBoxAdapter(
            child: _AisleHeader(category: category, count: groups[category]!.length),
          ),
          SliverList.list(
            children: [
              for (final item in groups[category]!)
                _leaving.containsKey(item.id)
                    ? _SlideAway(
                        key: ValueKey('leaving-${item.id}'),
                        onDone: () => _left(item.id),
                        child: _StoreRow(item: item, checked: true, pending: pending.contains(item.id), onTap: () {}),
                      )
                    : _StoreRow(
                        key: ValueKey(item.id),
                        item: item,
                        checked: false,
                        pending: pending.contains(item.id),
                        onTap: () => _check(item),
                      ),
            ],
          ),
        ],
        if (inCart.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _CartHeader(
              count: inCart.length,
              open: _cartOpen,
              onTap: () => setState(() => _cartOpen = !_cartOpen),
            ),
          ),
          if (_cartOpen)
            SliverList.list(
              children: [
                for (final item in inCart)
                  _CartRow(
                    key: ValueKey('cart-${item.id}'),
                    item: item,
                    pending: pending.contains(item.id),
                    onTap: () => _uncheck(item),
                  ),
              ],
            ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

const _lamarLines = [
  'Purr-fect haul. I\'ll supervise the unpacking.',
  'Every last thing! This calls for a victory dance.',
  'All done. Was there tuna in there? Asking for a friend.',
  'Mission complete. Time for a well-earned nap (mine).',
];

class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: '$done of $total in the cart',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$done of $total in the cart',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              tween: Tween(end: total == 0 ? 0 : done / total),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              builder: (_, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 10,
                  color: scheme.secondary,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AisleHeader extends StatelessWidget {
  const _AisleHeader({required this.category, required this.count});

  final String category;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        '${categoryEmoji[category] ?? '🛍️'}  $category · $count',
        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// One thing to get: the whole row is the tap target.
class _StoreRow extends StatelessWidget {
  const _StoreRow({super.key, required this.item, required this.checked, required this.pending, required this.onTap});

  final Item item;
  final bool checked;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      checked: checked,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  checked ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 34,
                  color: checked ? scheme.secondary : scheme.outline,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: checked ? muted : scheme.onSurface,
                          decoration: checked ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (item.quantity != null)
                        Text(item.quantity!, style: theme.textTheme.bodyLarge?.copyWith(color: muted)),
                    ],
                  ),
                ),
                if (pending) const Padding(padding: EdgeInsets.only(left: 8), child: PendingSyncIcon(size: 20)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides a just-checked row off to the side, then closes the gap.
class _SlideAway extends StatefulWidget {
  const _SlideAway({super.key, required this.child, required this.onDone});

  final Widget child;
  final VoidCallback onDone;

  @override
  State<_SlideAway> createState() => _SlideAwayState();
}

class _SlideAwayState extends State<_SlideAway> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 450))
    ..forward().whenComplete(widget.onDone);

  late final _slide = Tween(begin: Offset.zero, end: const Offset(1.1, 0)).animate(
    CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.15, 0.75, curve: Curves.easeInCubic),
    ),
  );
  late final _size = Tween(begin: 1.0, end: 0.0).animate(
    CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.6, 1, curve: Curves.easeInOut),
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: SlideTransition(
          position: _slide,
          child: IgnorePointer(child: widget.child),
        ),
      ),
    );
  }
}

class _CartHeader extends StatelessWidget {
  const _CartHeader({required this.count, required this.open, required this.onTap});

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '🛒  In the cart ($count)',
                    style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                Icon(open ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Something already in the cart: tap to put it back on the list.
class _CartRow extends StatelessWidget {
  const _CartRow({super.key, required this.item, required this.pending, required this.onTap});

  final Item item;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      checked: true,
      hint: 'Tap to put it back on the list',
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.check_circle, size: 26, color: theme.colorScheme.secondary),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(color: muted, decoration: TextDecoration.lineThrough),
                  ),
                ),
                if (pending) const Padding(padding: EdgeInsets.only(left: 8), child: PendingSyncIcon()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Celebration extends StatelessWidget {
  const _Celebration({
    required this.line,
    required this.onClearAndFinish,
    required this.onFinish,
    required this.onKeepShopping,
  });

  final String line;
  final VoidCallback onClearAndFinish;
  final VoidCallback onFinish;
  final VoidCallback onKeepShopping;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: Lamar(width: 150)),
              const SizedBox(height: 16),
              Text(
                'Everything\'s in the cart!',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                line,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onClearAndFinish,
                icon: const Icon(Icons.done_all),
                label: const Text('Clear the cart & finish'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onFinish, child: const Text('Finish')),
              const SizedBox(height: 4),
              TextButton(onPressed: onKeepShopping, child: const Text('Something missing? Keep shopping')),
            ],
          ),
        ),
      ),
    );
  }
}
