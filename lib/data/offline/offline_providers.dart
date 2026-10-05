import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../config.dart';
import '../providers.dart';
import 'kv_store.dart';
import 'outbox.dart';

export 'outbox.dart' show SyncState, OutboxRejection;

/// [KeyValueStore] over shared_preferences (localStorage on web), which loads
/// everything at startup so reads are synchronous.
class PrefsKeyValueStore implements KeyValueStore {
  PrefsKeyValueStore._(this._prefs);

  final SharedPreferencesWithCache _prefs;

  static Future<KeyValueStore> open() async => PrefsKeyValueStore._(
    await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions()),
  );

  @override
  String? get(String key) => _prefs.getString(key);

  @override
  Iterable<String> get keys => _prefs.keys;

  @override
  Future<void> set(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// The device's persistent store. main() swaps in the real one before the app
/// starts; until then (and in tests) it's in memory.
KeyValueStore sharedKeyValueStore = MemoryKeyValueStore();

/// Loads the persistent store; never fails (falls back to memory).
Future<void> initOfflineStorage() async {
  try {
    sharedKeyValueStore = await PrefsKeyValueStore.open();
  } catch (e) {
    debugPrint('Offline storage unavailable, using memory: $e');
  }
}

final keyValueStoreProvider = Provider<KeyValueStore>((ref) => sharedKeyValueStore);

/// Last known rows for the signed-in user (null when signed out).
final rowCacheProvider = Provider<RowCache?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return null;
  final cache = RowCache(ref.watch(keyValueStoreProvider), userId: uid);
  ref.onDispose(cache.dispose);
  return cache;
});

/// Platform "is there a network at all" signal (airplane mode, no Wi-Fi or
/// cellular). Bad signal with a network still present is caught by requests
/// failing.
///
/// A factory, not a stream: each listener needs its own single-subscription
/// stream (with the current state first). Sharing one stream crashed with
/// "Stream has already been listened to" when the outbox was rebuilt for a
/// different signed-in user.
final networkAvailableProvider = Provider<Stream<bool> Function()>((ref) => _networkAvailable);

Stream<bool> _networkAvailable() async* {
  final connectivity = Connectivity();
  bool up(List<ConnectivityResult> r) => r.any((c) => c != ConnectivityResult.none);
  yield up(await connectivity.checkConnectivity());
  yield* connectivity.onConnectivityChanged.map(up);
}

/// Cheap "can we reach Supabase?" check.
final connectionProbeProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    final res = await http
        .get(Uri.parse('${Config.supabaseUrl}/auth/v1/health'), headers: {'apikey': Config.supabaseKey})
        .timeout(const Duration(seconds: 6));
    return res.statusCode < 500;
  },
);

/// Queued item changes for the signed-in user (null when signed out).
final outboxProvider = Provider<Outbox?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return null;
  final outbox = Outbox(
    store: ref.watch(keyValueStoreProvider),
    userId: uid,
    run: supabaseItemRunner(ref.watch(supabaseProvider)),
    probe: ref.watch(connectionProbeProvider),
  );
  final network = ref
      .watch(networkAvailableProvider)()
      .listen(outbox.setNetworkAvailable, onError: (Object e) => debugPrint('connectivity: $e'));
  final lifecycle = AppLifecycleListener(onResume: outbox.checkConnection);
  unawaited(outbox.checkConnection());
  ref.onDispose(() {
    network.cancel();
    lifecycle.dispose();
    outbox.dispose();
  });
  return outbox;
});

class _SyncStateNotifier extends Notifier<SyncState> {
  @override
  SyncState build() {
    final outbox = ref.watch(outboxProvider);
    if (outbox == null) return const SyncState();
    final sub = outbox.states.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return outbox.state;
  }
}

/// Online/offline, how many changes are waiting, and "just synced".
final syncStateProvider = NotifierProvider<_SyncStateNotifier, SyncState>(_SyncStateNotifier.new);

/// Ids of items in a list with changes that haven't reached the server yet.
final pendingItemIdsProvider = StreamProvider.family<Set<String>, String>((ref, listId) async* {
  final outbox = ref.watch(outboxProvider);
  if (outbox == null) {
    yield const {};
    return;
  }
  yield outbox.pendingIds(listId);
  await for (final _ in outbox.changes) {
    yield outbox.pendingIds(listId);
  }
});

/// Changes the server turned down after the screen that made them moved on.
final outboxRejectionsProvider = StreamProvider<OutboxRejection>((ref) {
  final outbox = ref.watch(outboxProvider);
  return outbox == null ? const Stream.empty() : outbox.rejections;
});
