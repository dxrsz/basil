// End-to-end check of offline item changes against the live project.
//
// Two throwaway users share a list. User A goes "offline" (realtime socket
// disconnected and every request failing as if there were no network),
// makes changes through the Outbox, "restarts the app" (a fresh Outbox over
// the same storage), and reconnects. User B watches with liveRows and must
// see exactly the replayed result: nothing early, nothing resurrected, and
// nothing that was added and removed while offline. Cleans up after itself.
//
//   dart run tool/offline_check.dart
//
// Needs env.json (URL + publishable key) and the service-role key in
// ~/.supabase_basil_service_key (only used to create/delete the test users).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:lamars_groceries/data/live_query.dart';
import 'package:lamars_groceries/data/offline/kv_store.dart';
import 'package:lamars_groceries/data/offline/outbox.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';

late final String url;
late final String publishable;
late final String service;

Future<String> createUser(String email, String password) async {
  final res = await http.post(
    Uri.parse('$url/auth/v1/admin/users'),
    headers: {'apikey': service, 'Authorization': 'Bearer $service', 'Content-Type': 'application/json'},
    body: jsonEncode({'email': email, 'password': password, 'email_confirm': true}),
  );
  if (res.statusCode >= 300) throw 'create user: ${res.body}';
  return (jsonDecode(res.body) as Map)['id'] as String;
}

Future<void> deleteUser(String id) => http.delete(
  Uri.parse('$url/auth/v1/admin/users/$id'),
  headers: {'apikey': service, 'Authorization': 'Bearer $service'},
);

/// Records every emission of a stream and lets you wait for a condition.
class Watch<T> {
  Watch(Stream<T> stream) {
    sub = stream.listen((v) {
      latest = v;
      history.add(v);
      _changed.add(null);
    });
  }
  late final StreamSubscription<T> sub;
  T? latest;
  final history = <T>[];
  final _changed = StreamController<void>.broadcast();

  Future<bool> until(bool Function(T v) test, {Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final v = latest;
      if (v != null && test(v)) return true;
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) return false;
      await _changed.stream.first.timeout(left, onTimeout: () {});
    }
  }
}

var failures = 0;
void report(String what, bool ok) {
  if (!ok) failures++;
  stdout.writeln('  ${ok ? '✓' : '✗ FAIL'}  $what');
}

Future<void> main() async {
  final env = jsonDecode(File('env.json').readAsStringSync()) as Map;
  url = env['SUPABASE_URL'] as String;
  publishable = env['SUPABASE_PUBLISHABLE_KEY'] as String;
  service = File('${Platform.environment['HOME']}/.supabase_basil_service_key').readAsStringSync().trim();

  final rnd = Random.secure();
  String pw() => base64Url.encode(List.generate(18, (_) => rnd.nextInt(256)));
  String uuid() => const Uuid().v4();

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final ids = <String>[];
  final a = SupabaseClient(url, publishable), b = SupabaseClient(url, publishable);
  final storage = MemoryKeyValueStore(); // A's device storage, kept across the "restart"
  Outbox? outbox;

  try {
    final pa = pw(), pb = pw();
    ids.add(await createUser('off-a-$stamp@example.invalid', pa));
    ids.add(await createUser('off-b-$stamp@example.invalid', pb));
    await a.auth.signInWithPassword(email: 'off-a-$stamp@example.invalid', password: pa);
    await b.auth.signInWithPassword(email: 'off-b-$stamp@example.invalid', password: pb);
    final uidA = a.auth.currentUser!.id;

    final listId = await a.rpc('create_list', params: {'p_name': 'Offline', 'p_emoji': '🧪'}) as String;
    final code = await a.rpc('create_list_invite', params: {'p_list_id': listId}) as String;
    await b.rpc('join_list', params: {'p_code': code});
    stdout.writeln('Two users sharing a list. User B watches; user A goes offline and edits.\n');

    // A's "network": while offline, every request fails like a dead connection.
    var offline = false;
    final realRun = supabaseItemRunner(a);
    Future<void> run(OutboxOp op) {
      if (offline) throw http.ClientException('Failed host lookup (simulated offline)');
      return realRun(op);
    }

    Outbox open() => Outbox(store: storage, userId: uidA, run: run, probe: () async => !offline);
    outbox = open();

    final live = Watch(liveRows(b, table: 'items', column: 'list_id', value: listId));
    Map<String, dynamic>? named(List<Map<String, dynamic>> rows, String name) =>
        rows.where((r) => r['name'] == name).firstOrNull;
    await live.until((_) => true);
    await Future<void>.delayed(const Duration(seconds: 2)); // let the channel finish subscribing

    // Starting point, made online through the outbox.
    final milk = uuid(), juice = uuid(), eggs = uuid(), bread = uuid();
    Map<String, dynamic> item(String id, String name) => {
      'id': id,
      'list_id': listId,
      'name': name,
      'category': 'Other',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    await outbox.insertItem(item(milk, 'Milk'));
    await outbox.insertItem(item(juice, 'Juice'));
    report('online adds reach B', await live.until((r) => named(r, 'Milk') != null && named(r, 'Juice') != null));

    // ---------------------------------------------------------- offline
    offline = true;
    a.realtime.disconnect();
    outbox.setNetworkAvailable(false);
    stdout.writeln('\nA goes offline (realtime disconnected, requests failing)');

    await outbox.insertItem(item(eggs, 'Eggs'));
    await outbox.updateItem(listId, eggs, {'name': 'Brown eggs'}); // edit before it ever synced
    await outbox.updateItem(listId, milk, {'checked': true});
    await outbox.updateItem(listId, milk, {'checked': true}); // double tap: idempotent
    await outbox.insertItem(item(bread, 'Bread'));
    await outbox.deleteItem(listId, bread); // added and removed offline: never sent
    await outbox.updateItem(listId, juice, {'name': 'Orange juice'});
    stdout.writeln('A: adds Eggs → renames to Brown eggs, checks Milk twice, adds+removes Bread, renames Juice');
    report('A\'s outbox holds 5 changes (Bread cancelled out)', outbox.queued.length == 5);

    final localView = outbox.apply(listId, await a.from('items').select().eq('list_id', listId));
    report(
      'A sees its changes locally at once',
      named(localView, 'Brown eggs') != null && named(localView, 'Milk')?['checked'] == true,
    );

    await b.from('items').delete().eq('id', juice);
    stdout.writeln('B (online) deletes Juice while A is offline');

    await Future<void>.delayed(const Duration(seconds: 2));
    report('B sees none of A\'s offline changes yet', named(live.latest!, 'Brown eggs') == null);

    // "Restart the app" while still offline: the queue must come back from storage.
    outbox.dispose();
    outbox = open();
    outbox.setNetworkAvailable(false);
    report('the queue survives an app restart', outbox.queued.length == 5);

    // ------------------------------------------------------- reconnect
    offline = false;
    outbox.setNetworkAvailable(true);
    await outbox.flush();
    stdout.writeln('\nA reconnects; the outbox replays');
    report('outbox drained', outbox.queued.isEmpty && outbox.online);

    report('B sees Brown eggs (added + edited offline)', await live.until((r) => named(r, 'Brown eggs') != null));
    report('B sees Milk checked', await live.until((r) => named(r, 'Milk')?['checked'] == true));
    report('Milk was stamped as checked by A', named(live.latest!, 'Milk')?['checked_by'] == uidA);
    report(
      'Juice (deleted by B) was not resurrected by A\'s offline edit',
      live.latest!.every((r) => r['id'] != juice) &&
          live.history.every((rows) => rows.every((r) => r['id'] != juice || r['name'] == 'Juice')),
    );
    report('Bread never reached the server', live.history.every((rows) => rows.every((r) => r['id'] != bread)));
    final server = await a.from('items').select('id').eq('list_id', listId);
    report('server has exactly Milk + Brown eggs', server.length == 2);

    // Clear checked while offline, then replay: only Milk goes.
    offline = true;
    outbox.setNetworkAvailable(false);
    await outbox.clearChecked(listId, [milk]);
    offline = false;
    outbox.setNetworkAvailable(true);
    await outbox.flush();
    report(
      'offline "Clear" removes only the checked item',
      await live.until((r) => r.length == 1 && named(r, 'Brown eggs') != null),
    );

    // Replaying an already-applied insert (lost response) must not duplicate or fail.
    await realRun(OutboxOp(seq: 999, kind: OpKind.insert, listId: listId, id: eggs, data: item(eggs, 'Eggs')));
    final again = await a.from('items').select().eq('id', eggs);
    report(
      'replayed insert is ignored (no duplicate, no overwrite)',
      again.length == 1 && again.single['name'] == 'Brown eggs',
    );

    // Cache hydration: a second liveRows over a populated cache emits before the server answers.
    final cache = RowCache(MemoryKeyValueStore(), userId: uidA);
    final warm = Watch(liveRows(a, table: 'items', column: 'list_id', value: listId, cache: cache));
    await warm.until((r) => r.length == 1);
    await warm.sub.cancel();
    final sw = Stopwatch()..start();
    final first = await liveRows(a, table: 'items', column: 'list_id', value: listId, cache: cache).first;
    report(
      'cached rows emit instantly (${sw.elapsedMilliseconds} ms)',
      first.length == 1 && sw.elapsedMilliseconds < 50,
    );

    await live.sub.cancel();
    await a.from('lists').delete().eq('id', listId);
  } finally {
    outbox?.dispose();
    await a.dispose();
    await b.dispose();
    for (final id in ids) {
      await deleteUser(id);
    }
    stdout.writeln('\nCleaned up ${ids.length} test users.');
  }
  stdout.writeln(failures == 0 ? 'All offline checks passed.' : '$failures check(s) failed.');
  exit(failures == 0 ? 0 : 1);
}
