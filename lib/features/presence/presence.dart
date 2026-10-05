import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers.dart';
import '../../data/sharing_repository.dart';
import '../store/store_mode.dart';
import 'presence_state.dart';

export 'presence_state.dart';

/// "Who's shopping now": who else has a list open, and who's at the store.
///
/// Each open list joins the private Realtime channel `presence:list:<id>`.
/// Realtime Authorization (RLS on realtime.messages, see
/// 20261005140000_list_presence_auth.sql) only lets list members join it.
///
/// You count as shopping while store mode is open for the list
/// ([isInStoreModeProvider]); anything else can mark it with
/// `ref.read(shoppingNowProvider.notifier).setShopping(listId, true)` and clear
/// it with `false`. Starting to shop also pings the list's other members.

/// Lists the user is currently shopping (store mode). In memory only.
class ShoppingNow extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentUserIdProvider); // reset on sign-out / user switch
    return const {};
  }

  /// Marks the user as shopping [listId] (or not). Starting to shop also lets
  /// the list's other members know by push (the server rate-limits this).
  void setShopping(String listId, bool shopping) {
    if (state.contains(listId) == shopping) return;
    state = shopping ? {...state, listId} : ({...state}..remove(listId));
    if (shopping) {
      unawaited(
        ref.read(sharingRepositoryProvider).announceShopping(listId).catchError((Object e) {
          debugPrint('announce_shopping failed: $e');
        }),
      );
    }
  }
}

final shoppingNowProvider = NotifierProvider<ShoppingNow, Set<String>>(ShoppingNow.new);

/// Presence for one list. Watching it is what puts you "in" the list: the
/// channel is joined while something watches and left when nothing does.
class ListPresenceController extends Notifier<ListPresence> {
  ListPresenceController(this.listId);

  final String listId;
  RealtimeChannel? _channel;
  bool _subscribed = false;
  bool _visible = true;

  @override
  ListPresence build() {
    final uid = ref.watch(currentUserIdProvider);
    if (uid == null) return const ListPresence();
    final db = ref.watch(supabaseProvider);

    final channel = db.channel(presenceTopic(listId), opts: RealtimeChannelConfig(private: true, key: uid));
    _channel = channel;
    _subscribed = false;
    channel
        .onPresenceSync((_) {
          if (_channel != channel) return;
          final payloads = [
            for (final s in channel.presenceState())
              for (final p in s.presences) p.payload,
          ];
          state = ListPresence(parsePresence(payloads, me: uid));
        })
        .subscribe((status, error) {
          if (_channel != channel) return;
          _subscribed = status == RealtimeSubscribeStatus.subscribed;
          if (_subscribed) _track();
          if (error != null) debugPrint('presence ${presenceTopic(listId)}: $status $error');
        });

    // Shopping flag changes re-announce our presence payload.
    ref.listen(shoppingNowProvider.select((s) => s.contains(listId)), (_, _) => _track());
    ref.listen(isInStoreModeProvider(listId), (was, now) {
      _track();
      if (now && was != true && !ref.read(shoppingNowProvider).contains(listId)) {
        unawaited(
          ref.read(sharingRepositoryProvider).announceShopping(listId).catchError((Object e) {
            debugPrint('announce_shopping failed: $e');
          }),
        );
      }
    });

    // Don't show as "here" while the app is in the background.
    final lifecycle = AppLifecycleListener(
      onShow: () {
        _visible = true;
        _track();
      },
      onHide: () {
        _visible = false;
        if (_subscribed) unawaited(channel.untrack());
      },
    );

    ref.onDispose(() {
      lifecycle.dispose();
      if (_channel == channel) _channel = null;
      unawaited(db.removeChannel(channel));
    });
    return const ListPresence();
  }

  void _track() {
    final channel = _channel;
    final uid = ref.read(currentUserIdProvider);
    if (channel == null || !_subscribed || !_visible || uid == null) return;
    unawaited(
      channel.track({
        'user_id': uid,
        'shopping': ref.read(shoppingNowProvider).contains(listId) || ref.read(isInStoreModeProvider(listId)),
        'at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }
}

final listPresenceProvider = NotifierProvider.autoDispose.family<ListPresenceController, ListPresence, String>(
  ListPresenceController.new,
);
