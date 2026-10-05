import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lamars_groceries/data/live_query.dart';
import 'package:lamars_groceries/data/offline/kv_store.dart';
import 'package:lamars_groceries/data/offline/outbox.dart';
import 'package:supabase/supabase.dart';

/// A stand-in for the `items` table with the same semantics as the real
/// runner: inserts ignore duplicates, updates/deletes by id, clear deletes
/// only listed ids that are still checked.
class FakeServer {
  final rows = <String, Map<String, dynamic>>{};
  final log = <String>[];
  bool offline = false;

  /// Apply the op but lose the response (as if the connection dropped).
  bool dropNextResponse = false;
  Object? rejectNext;

  Future<void> run(OutboxOp op) async {
    if (offline) throw http.ClientException('Failed host lookup');
    if (rejectNext != null) {
      final e = rejectNext!;
      rejectNext = null;
      throw e;
    }
    log.add('${op.kind.name}:${op.id ?? op.ids.join(',')}');
    switch (op.kind) {
      case OpKind.insert:
        rows.putIfAbsent(op.id!, () => {...op.data});
      case OpKind.update:
        final r = rows[op.id];
        if (r != null) rows[op.id!] = {...r, ...op.data};
      case OpKind.delete:
        rows.remove(op.id);
      case OpKind.clear:
        for (final id in op.ids) {
          if (rows[id]?['checked'] == true) rows.remove(id);
        }
    }
    if (dropNextResponse) {
      dropNextResponse = false;
      throw TimeoutException('lost response');
    }
  }

  List<Map<String, dynamic>> list(String listId) => [
    for (final r in rows.values)
      if (r['list_id'] == listId) r,
  ];
}

Map<String, dynamic> item(String id, String name, {bool checked = false}) => {
  'id': id,
  'list_id': 'L',
  'name': name,
  'quantity': null,
  'category': 'Other',
  'checked': checked,
  'checked_by': null,
  'recipe_id': null,
  'created_at': '2026-10-05T10:00:00Z',
};

void main() {
  late FakeServer server;
  late MemoryKeyValueStore store;
  late Outbox outbox;
  var probeResult = true;

  Outbox make() => Outbox(
    store: store,
    userId: 'me',
    run: server.run,
    probe: () async => probeResult,
    retryEvery: const Duration(milliseconds: 20),
    waitForResult: const Duration(milliseconds: 200),
    syncedFor: const Duration(milliseconds: 50),
    settleFor: const Duration(milliseconds: 100),
  );

  setUp(() {
    server = FakeServer();
    store = MemoryKeyValueStore();
    probeResult = true;
    outbox = make();
  });
  tearDown(() => outbox.dispose());

  Future<void> goOffline() async {
    server.offline = true;
    probeResult = false;
    outbox.setNetworkAvailable(false);
  }

  Future<void> reconnect() async {
    server.offline = false;
    probeResult = true;
    outbox.setNetworkAvailable(true);
    await outbox.flush();
  }

  test('online changes go straight through, in order', () async {
    await outbox.insertItem(item('a', 'Milk'));
    await outbox.updateItem('L', 'a', {'checked': true});
    expect(server.log, ['insert:a', 'update:a']);
    expect(server.rows['a']!['checked'], true);
    expect(outbox.queued, isEmpty);
  });

  test('offline changes queue, show at once, and replay in order on reconnect', () async {
    await goOffline();
    await outbox.insertItem(item('a', 'Milk'));
    await outbox.insertItem(item('b', 'Eggs'));
    await outbox.updateItem('L', 'a', {'checked': true});
    await outbox.updateItem('L', 'b', {'name': 'Brown eggs'});
    expect(server.rows, isEmpty);
    expect(outbox.queued, hasLength(4));
    expect(outbox.state.online, false);
    expect(outbox.state.pending, 4);

    // The local view already has everything.
    final view = outbox.apply('L', const []);
    expect(view.map((r) => r['name']), ['Milk', 'Brown eggs']);
    expect(view.first['checked'], true);
    expect(view.first['checked_by'], 'me');
    expect(outbox.pendingIds('L'), {'a', 'b'});

    await reconnect();
    expect(server.log, ['insert:a', 'insert:b', 'update:a', 'update:b']);
    expect(server.rows['a']!['checked'], true);
    expect(server.rows['b']!['name'], 'Brown eggs');
    expect(outbox.queued, isEmpty);
    expect(outbox.pendingIds('L'), isEmpty);
  });

  test('the queue survives a restart', () async {
    await goOffline();
    await outbox.insertItem(item('a', 'Milk'));
    await outbox.updateItem('L', 'a', {'checked': true});
    outbox.dispose();

    server.offline = false;
    probeResult = true;
    outbox = make(); // a fresh app launch over the same storage
    expect(outbox.queued.map((o) => o.kind), [OpKind.insert, OpKind.update]);
    await outbox.flush();
    expect(server.rows['a']!['checked'], true);
    expect(outbox.queued, isEmpty);
    expect(store.get('outbox:me'), '[]');
  });

  test('replaying an op whose response was lost is harmless', () async {
    server.rows['a'] = item('a', 'Milk');
    server.dropNextResponse = true; // the check lands, but we never hear back
    await outbox.updateItem('L', 'a', {'checked': true});
    expect(outbox.queued, hasLength(1));
    expect(outbox.online, false);

    await outbox.insertItem(item('b', 'Eggs'));
    server.dropNextResponse = false;
    await reconnect();
    expect(server.log, ['update:a', 'update:a', 'insert:b']);
    expect(server.rows['a']!['checked'], true);
    expect(server.rows.keys, {'a', 'b'});
  });

  test('a lost insert response does not create a duplicate', () async {
    server.dropNextResponse = true;
    await outbox.insertItem(item('a', 'Milk'));
    await reconnect();
    expect(server.log, ['insert:a', 'insert:a']);
    expect(server.rows, hasLength(1));
  });

  test('checking twice is idempotent', () async {
    server.rows['a'] = item('a', 'Milk');
    await goOffline();
    await outbox.updateItem('L', 'a', {'checked': true});
    await outbox.updateItem('L', 'a', {'checked': true});
    await reconnect();
    expect(server.rows['a']!['checked'], true);
    expect(outbox.apply('L', server.list('L')).single['checked'], true);
  });

  test('editing an item someone else deleted does not resurrect it', () async {
    server.rows['a'] = item('a', 'Milk');
    await goOffline();
    await outbox.updateItem('L', 'a', {'name': 'Oat milk'});
    await outbox.updateItem('L', 'a', {'checked': true});
    server.rows.remove('a'); // someone else removes it meanwhile
    await reconnect();
    expect(server.rows, isEmpty);
    expect(outbox.queued, isEmpty);
    expect(outbox.apply('L', server.list('L')), isEmpty);
  });

  test('deleting offline wins over an edit made elsewhere', () async {
    server.rows['a'] = item('a', 'Milk');
    await goOffline();
    await outbox.deleteItem('L', 'a');
    server.rows['a'] = {...server.rows['a']!, 'name': 'Oat milk'};
    expect(outbox.apply('L', server.list('L')), isEmpty);
    await reconnect();
    expect(server.rows, isEmpty);
  });

  test('adding then deleting offline never touches the server', () async {
    await goOffline();
    await outbox.insertItem(item('a', 'Milk'));
    await outbox.updateItem('L', 'a', {'checked': true});
    await outbox.deleteItem('L', 'a');
    expect(outbox.queued, isEmpty);
    await reconnect();
    expect(server.log, isEmpty);
  });

  test('undoing an unsent delete cancels it', () async {
    server.rows['a'] = item('a', 'Milk');
    await goOffline();
    await outbox.deleteItem('L', 'a');
    expect(outbox.apply('L', server.list('L')), isEmpty);
    await outbox.insertItem(item('a', 'Milk'));
    expect(outbox.queued, isEmpty);
    expect(outbox.apply('L', server.list('L')), hasLength(1));
  });

  test('clear only removes what was checked, and only if it still is', () async {
    server.rows['a'] = item('a', 'Milk', checked: true);
    server.rows['b'] = item('b', 'Eggs', checked: true);
    server.rows['c'] = item('c', 'Bread');
    await goOffline();
    await outbox.clearChecked('L', ['a', 'b']);
    expect(outbox.apply('L', server.list('L')).map((r) => r['id']), ['c']);
    server.rows['b'] = {...server.rows['b']!, 'checked': false}; // someone needs more eggs
    await reconnect();
    expect(server.rows.keys, {'b', 'c'});
  });

  test('a rejected change is dropped and the rest still sync', () async {
    final rejections = <OutboxRejection>[];
    outbox.rejections.listen(rejections.add);
    await goOffline();
    await outbox.insertItem(item('a', 'Milk'));
    await outbox.insertItem(item('b', 'Eggs'));
    server.rejectNext = const PostgrestException(message: 'violates foreign key', code: '23503');
    await reconnect();
    await Future<void>.delayed(Duration.zero);
    expect(server.rows.keys, ['b']);
    expect(outbox.queued, isEmpty);
    expect(rejections.single.op.id, 'a');
  });

  test('a rejection while the caller waits is thrown to the caller', () async {
    server.rejectNext = const PostgrestException(message: 'nope', code: '42501');
    await expectLater(outbox.insertItem(item('a', 'Milk')), throwsA(isA<PostgrestException>()));
    expect(outbox.queued, isEmpty);
  });

  test('transient errors are recognised', () {
    expect(isTransientError(http.ClientException('x')), true);
    expect(isTransientError(TimeoutException('x')), true);
    expect(isTransientError(const PostgrestException(message: 'x', code: '503')), true);
    expect(isTransientError(const PostgrestException(message: 'jwt', code: 'PGRST303')), true);
    expect(isTransientError(const PostgrestException(message: 'x', code: '23503')), false);
    expect(isTransientError(ArgumentError('bug')), false);
  });

  test('sent changes stay in the overlay until the server echoes them', () async {
    server.rows['a'] = item('a', 'Milk');
    final stale = server.list('L').map((r) => {...r}).toList();
    await outbox.updateItem('L', 'a', {'checked': true});
    expect(outbox.queued, isEmpty);
    // Realtime hasn't delivered the update yet: still shown checked, not pending.
    expect(outbox.apply('L', stale).single['checked'], true);
    expect(outbox.pendingIds('L'), isEmpty);
    // Once the server rows reflect it, the settled op is dropped.
    outbox.apply('L', server.list('L'));
    expect(outbox.apply('L', stale).single['checked'], false);
  });

  test('sync state: offline, pending, then "synced" briefly on reconnect', () async {
    final states = <SyncState>[];
    outbox.states.listen(states.add);
    await goOffline();
    await outbox.insertItem(item('a', 'Milk'));
    await Future<void>.delayed(Duration.zero);
    expect(states.last, const SyncState(online: false, pending: 1));
    await reconnect();
    await Future<void>.delayed(Duration.zero);
    expect(states.last, const SyncState(online: true, pending: 0, justSynced: true));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(states.last, const SyncState(online: true, pending: 0));
  });

  test('the retry timer replays by itself once the server is reachable', () async {
    await goOffline();
    await outbox.insertItem(item('a', 'Milk'));
    server.offline = false; // no platform event: the periodic retry notices
    probeResult = true;
    for (var i = 0; i < 50 && outbox.queued.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(server.rows.keys, ['a']);
    expect(outbox.online, true);
  });

  group('RowCache', () {
    test('persists rows per user and survives a restart', () async {
      final cache = RowCache(store, userId: 'me');
      cache.write('items|list_id|L', [item('a', 'Milk')]);
      expect(cache.read('items|list_id|L')!.single['name'], 'Milk'); // before the batched write
      await cache.flush();
      final reopened = RowCache(store, userId: 'me');
      expect(reopened.read('items|list_id|L')!.single['name'], 'Milk');
      expect(RowCache(store, userId: 'someone-else').read('items|list_id|L'), isNull);
      await reopened.clear();
      expect(RowCache(store, userId: 'me').read('items|list_id|L'), isNull);
    });

    test('a corrupt entry is a miss', () {
      store.values['rows:me:k'] = '{not json';
      expect(RowCache(store, userId: 'me').read('k'), isNull);
    });
  });

  test('liveRows emits cached rows immediately, before the server answers', () async {
    // Nothing listens on this port: the server never answers, as when offline.
    final db = SupabaseClient('http://127.0.0.1:9', 'anon');
    final cache = RowCache(MemoryKeyValueStore(), userId: 'me');
    cache.write('items|list_id|L', [item('b', 'Eggs'), item('a', 'Milk')..['created_at'] = '2026-10-05T09:00:00Z']);
    final first = await liveRows(
      db,
      table: 'items',
      column: 'list_id',
      value: 'L',
      orderBy: 'created_at',
      cache: cache,
    ).first.timeout(const Duration(seconds: 1));
    expect(first.map((r) => r['name']), ['Milk', 'Eggs']);
    await db.dispose();
  });
}
