// End-to-end checks for sharing on the linked project: invite-link joins,
// presence authorization, device-token RLS, and the push queue (batching,
// dedupe, settings/mutes, the notify function's auth and no-FCM behaviour).
// Creates throwaway users (…@example.invalid) and deletes them afterwards.
//
//   dart run tool/sharing_check.dart
//
// Needs env.json (URL + publishable key) and the service-role key in
// ~/.supabase_basil_service_key (only used to create/delete the test users
// and to read the server-only queue tables).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:lamars_groceries/features/join/join_link.dart';
import 'package:lamars_groceries/features/presence/presence.dart';
import 'package:supabase/supabase.dart';

late final String url;
late final String publishable;
late final String service;

Map<String, String> get _admin => {'apikey': service, 'Authorization': 'Bearer $service'};

Future<String> createUser(String email, String password, String name) async {
  final res = await http.post(
    Uri.parse('$url/auth/v1/admin/users'),
    headers: {..._admin, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'email': email,
      'password': password,
      'email_confirm': true,
      'user_metadata': {'full_name': name},
    }),
  );
  if (res.statusCode >= 300) throw 'create user: ${res.body}';
  return (jsonDecode(res.body) as Map)['id'] as String;
}

Future<void> deleteUser(String id) => http.delete(Uri.parse('$url/auth/v1/admin/users/$id'), headers: _admin);

/// Service-role read of a server-only table.
Future<List<dynamic>> adminSelect(String table, String query) async {
  final res = await http.get(Uri.parse('$url/rest/v1/$table?$query'), headers: _admin);
  if (res.statusCode >= 300) throw 'select $table: ${res.body}';
  return jsonDecode(res.body) as List;
}

Future<dynamic> adminRpc(String fn, Map<String, dynamic> params) async {
  final res = await http.post(
    Uri.parse('$url/rest/v1/rpc/$fn'),
    headers: {..._admin, 'Content-Type': 'application/json'},
    body: jsonEncode(params),
  );
  if (res.statusCode >= 300) throw 'rpc $fn: ${res.body}';
  return jsonDecode(res.body);
}

var failures = 0;
void report(String what, bool ok) {
  if (!ok) failures++;
  stdout.writeln('  ${ok ? '✓' : '✗ FAIL'}  $what');
}

Future<bool> throwsSomething(Future<dynamic> Function() f) async {
  try {
    await f();
    return false;
  } catch (_) {
    return true;
  }
}

/// Joins [topic] and reports the subscribe outcome plus everything it sees.
class PresenceProbe {
  PresenceProbe(this.db, String topic, {required bool private, required this.userId}) {
    channel = db.channel(
      topic,
      opts: RealtimeChannelConfig(private: private, key: userId),
    );
    channel
        .onPresenceSync((_) {
          seen = parsePresence([
            for (final s in channel.presenceState())
              for (final p in s.presences) p.payload,
          ]);
          _changed.add(null);
        })
        .subscribe((status, error) {
          this.status = status;
          if (status == RealtimeSubscribeStatus.subscribed) {
            channel.track({'user_id': userId, 'shopping': shopping});
          }
          _changed.add(null);
        });
  }

  final SupabaseClient db;
  final String userId;
  late final RealtimeChannel channel;
  bool shopping = false;
  RealtimeSubscribeStatus? status;
  List<PresentUser> seen = const [];
  final _changed = StreamController<void>.broadcast();

  Future<bool> until(bool Function() test, {Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!test()) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) return false;
      await _changed.stream.first.timeout(left, onTimeout: () {});
    }
    return true;
  }

  Future<void> close() => db.removeChannel(channel);
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
  final names = ['Ann', 'Ben', 'Cat', 'Dot'];
  final clients = [for (final _ in names) SupabaseClient(url, publishable)];
  final [a, b, c, d] = clients;
  final probes = <PresenceProbe>[];

  try {
    final uid = <String>[];
    for (var i = 0; i < names.length; i++) {
      final email = 'share-${names[i].toLowerCase()}-$stamp@example.invalid', p = pw();
      ids.add(await createUser(email, p, '${names[i]} Tester'));
      uid.add(ids.last);
      await clients[i].auth.signInWithPassword(email: email, password: p);
    }
    final [ua, ub, uc, ud] = uid;

    // ------------------------------------------------------------ invites
    stdout.writeln('Invite links');
    final listId = await a.rpc('create_list', params: {'p_name': 'Share check', 'p_emoji': '🧪'}) as String;
    final code = await a.rpc('create_list_invite', params: {'p_list_id': listId}) as String;
    final link = inviteLink(code);
    final parsed = joinCodeFromUri(Uri.parse(link))!;
    final joined = await b.rpc('join_list', params: {'p_code': parsed.toLowerCase()}) as String;
    report('B joins via $link', joined == listId);
    final bLists = await b.from('lists').select('id').eq('id', listId);
    report('B can now read the list', bLists.length == 1);
    report('bad code is refused', await throwsSomething(() => c.rpc('join_list', params: {'p_code': 'ZZZZZZ'})));

    // ----------------------------------------------------------- presence
    stdout.writeln('Presence');
    final topic = presenceTopic(listId);
    final pa = PresenceProbe(a, topic, private: true, userId: ua);
    final pb = PresenceProbe(b, topic, private: true, userId: ub)..shopping = true;
    probes.addAll([pa, pb]);
    report('A (member) subscribes', await pa.until(() => pa.status == RealtimeSubscribeStatus.subscribed));
    report('B (member) subscribes', await pb.until(() => pb.status == RealtimeSubscribeStatus.subscribed));
    report('A sees B shopping', await pa.until(() => pa.seen.any((p) => p.userId == ub && p.shopping)));
    report('B sees A', await pb.until(() => pb.seen.any((p) => p.userId == ua)));

    final pc = PresenceProbe(c, topic, private: true, userId: uc);
    probes.add(pc);
    await pc.until(() => pc.status != null && pc.status != RealtimeSubscribeStatus.subscribed);
    report(
      'C (non-member) is refused the private channel (${pc.status?.name})',
      pc.status != RealtimeSubscribeStatus.subscribed,
    );
    report('C sees nobody', pc.seen.isEmpty);

    final pcPublic = PresenceProbe(c, topic, private: false, userId: uc);
    probes.add(pcPublic);
    await pcPublic.until(() => pcPublic.status != null);
    await pcPublic.until(() => pcPublic.seen.any((p) => p.userId != uc), timeout: const Duration(seconds: 4));
    report(
      'C on a public channel with the same name sees no members (${pcPublic.status?.name})',
      !pcPublic.seen.any((p) => p.userId == ua || p.userId == ub),
    );
    await pa.until(() => false, timeout: const Duration(seconds: 2));
    report('members don\'t see C\'s public-channel presence', !pa.seen.any((p) => p.userId == uc));

    // -------------------------------------------------------- device tokens
    stdout.writeln('Device tokens');
    final tokA = 'test-token-a-$stamp', tokB = 'test-token-b-$stamp';
    await a.rpc('register_device_token', params: {'p_token': tokA, 'p_platform': 'android'});
    await b.rpc('register_device_token', params: {'p_token': tokB, 'p_platform': 'ios'});
    final bSees = await b.from('device_tokens').select('token');
    report('B reads only their own token', bSees.length == 1 && bSees.first['token'] == tokB);
    await b.from('device_tokens').delete().eq('token', tokA);
    final stillThere = await adminSelect('device_tokens', 'token=eq.$tokA&select=user_id');
    report('B can\'t delete A\'s token', stillThere.length == 1 && stillThere.first['user_id'] == ua);
    report(
      'B can\'t insert a token as A',
      await throwsSomething(
        () => b.from('device_tokens').insert({'token': 'forged-$stamp', 'user_id': ua, 'platform': 'ios'}),
      ),
    );
    report(
      'users can\'t call the server-only RPCs',
      await throwsSomething(() => b.rpc('claim_notifications')) &&
          await throwsSomething(
            () => b.rpc('notification_recipients', params: {'p_list_id': listId, 'p_actor': ub, 'p_kind': 'shopping'}),
          ) &&
          await throwsSomething(() => b.rpc('kick_notify')),
    );
    report('users can\'t read the queue', (await b.from('item_add_batches').select()).isEmpty);

    // --------------------------------------------------------------- queue
    stdout.writeln('Notification queue');
    await b.from('items').insert([
      for (final n in ['Oat milk', 'Eggs', 'Bread', 'Typo']) {'list_id': listId, 'name': n},
    ]);
    await b.from('items').delete().eq('list_id', listId).eq('name', 'Typo');
    var batches = await adminSelect('item_add_batches', 'list_id=eq.$listId&select=actor_id,item_count,names');
    report(
      'B\'s 4 adds − 1 undo fold into one batch of 3 (${jsonEncode(batches)})',
      batches.length == 1 && batches.first['actor_id'] == ub && batches.first['item_count'] == 3,
    );
    await a.from('items').insert({'list_id': listId, 'name': 'Cat treats'});
    batches = await adminSelect('item_add_batches', 'list_id=eq.$listId&actor_id=eq.$ua&select=item_count');
    report('A\'s add makes its own batch (B has a device)', batches.length == 1);

    report('B announces shopping', await b.rpc('announce_shopping', params: {'p_list_id': listId}) == true);
    report(
      '…a second time within 30 min is deduped',
      await b.rpc('announce_shopping', params: {'p_list_id': listId}) == false,
    );
    report(
      'C (non-member) can\'t announce',
      await throwsSomething(() => c.rpc('announce_shopping', params: {'p_list_id': listId})),
    );

    final code2 = await a.rpc('create_list_invite', params: {'p_list_id': listId}) as String;
    await d.rpc('join_list', params: {'p_code': code2});

    // Recipients honour settings and mutes (as the function sees them).
    Future<List<String>> recipients(String actor, String kind) async => [
      for (final r
          in await adminRpc('notification_recipients', {'p_list_id': listId, 'p_actor': actor, 'p_kind': kind}) as List)
        r['user_id'] as String,
    ];
    report(
      'B shopping → A notified, not B (actor)',
      (await recipients(ub, 'shopping')).toSet().containsAll([ua]) && !(await recipients(ub, 'shopping')).contains(ub),
    );
    await a.from('notification_settings').upsert({'user_id': ua, 'items_added': false});
    report('A turned off "adds" → not a recipient', !(await recipients(ub, 'items_added')).contains(ua));
    report('…but still gets "shopping"', (await recipients(ub, 'shopping')).contains(ua));
    await a.from('list_mutes').insert({'list_id': listId, 'user_id': ua});
    report('A muted the list → no "shopping" either', !(await recipients(ub, 'shopping')).contains(ua));
    await a.from('list_mutes').delete().eq('list_id', listId).eq('user_id', ua);
    await a.from('notification_settings').upsert({'user_id': ua, 'items_added': true});
    report(
      'C can\'t mute a list they\'re not on',
      await throwsSomething(() => c.from('list_mutes').insert({'list_id': listId, 'user_id': uc})),
    );

    // ---------------------------------------------------------- notify fn
    stdout.writeln('notify function');
    final noSecret = await http.post(Uri.parse('$url/functions/v1/notify'), body: '{"type":"flush"}');
    report('rejects calls without the secret (${noSecret.statusCode})', noSecret.statusCode == 401);
    final badSecret = await http.post(
      Uri.parse('$url/functions/v1/notify'),
      headers: {'x-notify-secret': 'nope', 'Authorization': 'Bearer $publishable'},
      body: '{"type":"flush"}',
    );
    report('rejects a wrong secret (${badSecret.statusCode})', badSecret.statusCode == 401);

    stdout.writeln('  …waiting for the 60 s debounce + 30 s cron to flush the queue');
    final deadline = DateTime.now().add(const Duration(seconds: 150));
    var outbox = <dynamic>[], pending = <dynamic>[];
    do {
      await Future<void>.delayed(const Duration(seconds: 5));
      outbox = await adminSelect('notification_outbox', 'list_id=eq.$listId&select=kind');
      pending = await adminSelect('item_add_batches', 'list_id=eq.$listId&select=item_count');
    } while ((outbox.isNotEmpty || pending.isNotEmpty) && DateTime.now().isBefore(deadline));
    report('shopping/join events were claimed by the function', outbox.isEmpty);
    report('item batches were claimed after the debounce', pending.isEmpty);
    stdout.writeln('  (see net._http_response for what the function composed)');

    for (final p in probes) {
      await p.close();
    }
    await a.from('lists').delete().eq('id', listId);
  } finally {
    for (final cl in clients) {
      await cl.dispose();
    }
    for (final id in ids) {
      await deleteUser(id);
    }
    stdout.writeln('\nCleaned up ${ids.length} test users.');
  }
  stdout.writeln(failures == 0 ? 'All sharing checks passed.' : '$failures check(s) failed.');
  exit(failures == 0 ? 0 : 1);
}
