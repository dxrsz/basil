// End-to-end check that realtime list updates (especially deletes) reach other
// members of a list. Creates two throwaway users on the linked project, shares
// a list between them, and compares Supabase's stock `.stream()` with
// `liveRows` while user A edits and user B watches. Cleans up after itself.
//
//   dart run tool/realtime_check.dart
//
// Needs env.json (URL + publishable key) and the service-role key in
// ~/.supabase_basil_service_key (only used to create/delete the test users).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:lamars_groceries/data/live_query.dart';
import 'package:supabase/supabase.dart';

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

/// Records the latest emission of a stream and lets you wait for a condition.
class Watch<T> {
  Watch(Stream<T> stream) {
    sub = stream.listen((v) {
      latest = v;
      _changed.add(null);
    });
  }
  late final StreamSubscription<T> sub;
  T? latest;
  final _changed = StreamController<void>.broadcast();

  Future<bool> until(bool Function(T v) test, {Duration timeout = const Duration(seconds: 6)}) async {
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
void report(String what, bool ok, {bool expectedToFail = false}) {
  final mark = ok ? '✓' : (expectedToFail ? '✗ (expected: the bug)' : '✗ FAIL');
  if (!ok && !expectedToFail) failures++;
  stdout.writeln('  $mark  $what');
}

Future<void> main() async {
  final env = jsonDecode(File('env.json').readAsStringSync()) as Map;
  url = env['SUPABASE_URL'] as String;
  publishable = env['SUPABASE_PUBLISHABLE_KEY'] as String;
  service = File('${Platform.environment['HOME']}/.supabase_basil_service_key').readAsStringSync().trim();

  final rnd = Random.secure();
  String pw() => base64Url.encode(List.generate(18, (_) => rnd.nextInt(256)));
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final ids = <String>[];
  final a = SupabaseClient(url, publishable), b = SupabaseClient(url, publishable);

  try {
    final pa = pw(), pb = pw();
    ids.add(await createUser('rt-a-$stamp@example.invalid', pa));
    ids.add(await createUser('rt-b-$stamp@example.invalid', pb));
    await a.auth.signInWithPassword(email: 'rt-a-$stamp@example.invalid', password: pa);
    await b.auth.signInWithPassword(email: 'rt-b-$stamp@example.invalid', password: pb);

    final listId = await a.rpc('create_list', params: {'p_name': 'RT', 'p_emoji': '🧪'}) as String;
    final code = await a.rpc('create_list_invite', params: {'p_list_id': listId}) as String;
    await b.rpc('join_list', params: {'p_code': code});
    stdout.writeln('Two users sharing a list. User B watches; user A edits.\n');

    final stock = Watch(b.from('items').stream(primaryKey: ['id']).eq('list_id', listId));
    final live = Watch(liveRows(b, table: 'items', column: 'list_id', value: listId));
    final liveRecipes = Watch(liveRows(b, table: 'recipes', column: 'list_id', value: listId));
    bool has(List<Map<String, dynamic>> rows, String name) => rows.any((r) => r['name'] == name);
    await live.until((r) => true);
    await stock.until((r) => true);
    await Future<void>.delayed(const Duration(seconds: 2)); // let both channels finish subscribing

    await a.from('items').insert([
      {'list_id': listId, 'name': 'Milk'},
      {'list_id': listId, 'name': 'Eggs'},
      {'list_id': listId, 'name': 'Bread'},
    ]);
    stdout.writeln('A adds Milk, Eggs, Bread');
    report('stock .stream() sees the inserts', await stock.until((r) => has(r, 'Milk') && has(r, 'Bread')));
    report('liveRows sees the inserts', await live.until((r) => has(r, 'Milk') && has(r, 'Bread')));

    await a.from('items').update({'checked': true}).eq('list_id', listId).eq('name', 'Eggs');
    stdout.writeln('A checks off Eggs');
    report('liveRows sees the check', await live.until((r) => r.any((x) => x['name'] == 'Eggs' && x['checked'] == true)));

    await a.from('items').delete().eq('list_id', listId).eq('name', 'Milk');
    stdout.writeln('A swipes Milk away');
    report('stock .stream() sees the delete', await stock.until((r) => !has(r, 'Milk')), expectedToFail: true);
    report('liveRows sees the delete', await live.until((r) => !has(r, 'Milk')));

    await a.rpc('clear_checked_items', params: {'p_list_id': listId});
    stdout.writeln('A taps "Clear" on checked items (Eggs)');
    report('liveRows sees the clear', await live.until((r) => !has(r, 'Eggs') && has(r, 'Bread')));

    final rid = await a.rpc(
      'save_recipe',
      params: {'p_list_id': listId, 'p_recipe_id': null, 'p_name': 'Toast', 'p_ingredients': [{'name': 'Bread'}]},
    );
    report('liveRows sees the new meal', await liveRecipes.until((r) => r.any((x) => x['id'] == rid)));
    await a.from('recipes').delete().eq('id', rid as String);
    stdout.writeln('A deletes the meal');
    report('liveRows sees the meal deleted', await liveRecipes.until((r) => r.every((x) => x['id'] != rid)));

    await stock.sub.cancel();
    await live.sub.cancel();
    await liveRecipes.sub.cancel();
    await a.from('lists').delete().eq('id', listId);
  } finally {
    await a.dispose();
    await b.dispose();
    for (final id in ids) {
      await deleteUser(id);
    }
    stdout.writeln('\nCleaned up ${ids.length} test users.');
  }
  stdout.writeln(failures == 0 ? 'All realtime checks passed.' : '$failures check(s) failed.');
  exit(failures == 0 ? 0 : 1);
}
