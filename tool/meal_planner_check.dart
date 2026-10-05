// End-to-end check of the meal planner against the linked project: profiles
// and RLS, merged household restrictions, the plan-meals edge function (week,
// swap, nudge, tonight), quotas, and the meal memory. Creates throwaway users
// and deletes them afterwards. Makes 4 small text-model calls; no images.
//
//   dart run tool/meal_planner_check.dart
//
// Needs env.json (URL + publishable key) and the service-role key in
// ~/.supabase_basil_service_key (only used to create/delete the test users
// and to fill one user's quota).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

late final String url;
late final String publishable;
late final String service;

Map<String, String> get adminHeaders => {
  'apikey': service,
  'Authorization': 'Bearer $service',
  'Content-Type': 'application/json',
};

Future<String> createUser(String email, String password) async {
  final res = await http.post(
    Uri.parse('$url/auth/v1/admin/users'),
    headers: adminHeaders,
    body: jsonEncode({'email': email, 'password': password, 'email_confirm': true}),
  );
  if (res.statusCode >= 300) throw 'create user: ${res.body}';
  return (jsonDecode(res.body) as Map)['id'] as String;
}

Future<void> deleteUser(String id) => http.delete(Uri.parse('$url/auth/v1/admin/users/$id'), headers: adminHeaders);

var failures = 0;
void report(String what, bool ok, [String? extra]) {
  if (!ok) failures++;
  stdout.writeln('  ${ok ? '✓' : '✗ FAIL'}  $what${extra == null ? '' : '  ($extra)'}');
}

/// Calls plan-meals as [c]; returns (status, body).
Future<(int, Map<String, dynamic>)> plan(SupabaseClient c, Map<String, dynamic> body) async {
  final res = await http.post(
    Uri.parse('$url/functions/v1/plan-meals'),
    headers: {
      'apikey': publishable,
      'Authorization': 'Bearer ${c.auth.currentSession!.accessToken}',
      'Content-Type': 'application/json',
    },
    body: jsonEncode(body),
  );
  return (res.statusCode, jsonDecode(res.body) as Map<String, dynamic>);
}

const meatWords = ['chicken', 'beef', 'pork', 'bacon', 'sausage', 'turkey', 'lamb', 'ham', 'steak', 'prosciutto'];
const nutWords = ['peanut', 'almond', 'cashew', 'walnut', 'pecan', 'pistachio', 'hazelnut', 'pine nut'];

/// "Uses the rest of Monday's cilantro and lime": the named items must really
/// be in this meal.
bool noteIsTrue(Map<String, dynamic> meal) {
  final note = meal['reuse_note'] as String?;
  if (note == null) return true;
  final m = RegExp(r"^(?:Uses the rest of .+?'s |Shares the )(.+?)(?: with .+)?$").firstMatch(note);
  if (m == null) return false;
  final have = [for (final i in meal['ingredients'] as List) (i['name'] as String).toLowerCase()];
  final ok = m
      .group(1)!
      .replaceAll(' and more', '')
      .split(RegExp(r', | and '))
      .every((x) => have.any((h) => h.contains(x.trim()) || x.trim().contains(h)));
  if (!ok) stdout.writeln('     untrue note on ${meal['name']}: $note');
  return ok;
}

String? violation(Map<String, dynamic> meal) {
  final words = [
    meal['name'] as String,
    for (final i in meal['ingredients'] as List) (i as Map)['name'] as String,
  ].join(' | ').toLowerCase();
  for (final w in [...meatWords, ...nutWords, 'mushroom']) {
    if (words.contains(w)) return w;
  }
  return null;
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
  final a = SupabaseClient(url, publishable),
      b = SupabaseClient(url, publishable),
      c = SupabaseClient(url, publishable);

  try {
    for (final (name, client) in [('a', a), ('b', b), ('c', c)]) {
      final email = 'plan-$name-$stamp@example.invalid', p = pw();
      ids.add(await createUser(email, p));
      await client.auth.signInWithPassword(email: email, password: p);
    }
    final aId = ids[0];

    final listId = await a.rpc('create_list', params: {'p_name': 'Plan test', 'p_emoji': '🧪'}) as String;
    final code = await a.rpc('create_list_invite', params: {'p_list_id': listId}) as String;
    await b.rpc('join_list', params: {'p_code': code});
    stdout.writeln('A and B share a list; C is an outsider.\n');

    stdout.writeln('Profiles & RLS');
    await a.from('taste_profiles').upsert({
      'user_id': aId,
      'diets': ['vegetarian'],
      'dislikes': ['Mushrooms'],
      'cuisines': ['Mexican', 'Thai'],
      'spice': 2,
      'adventurous': 70,
    });
    await b.from('taste_profiles').upsert({
      'user_id': ids[1],
      'diets': ['nut_allergy'],
      'dislikes': ['olives'],
      'cuisines': ['Italian'],
      'spice': 1,
      'adventurous': 30,
    });
    await a.from('kitchen_settings').upsert({
      'list_id': listId,
      'household_size': 2,
      'dinners_per_week': 3,
      'time_budget': 30,
      'appliances': ['oven', 'air_fryer', 'rice_cooker'],
      'want_more': ['air_fryer'],
    });
    report('B cannot read A\'s taste profile', (await b.from('taste_profiles').select().eq('user_id', aId)).isEmpty);
    report(
      'B reads the shared kitchen settings',
      (await b.from('kitchen_settings').select().eq('list_id', listId)).length == 1,
    );
    report(
      'C cannot read the kitchen settings',
      (await c.from('kitchen_settings').select().eq('list_id', listId)).isEmpty,
    );
    var cWrite = false;
    try {
      await c.from('kitchen_settings').upsert({'list_id': listId, 'household_size': 9});
      cWrite = true;
    } catch (_) {}
    report('C cannot write the kitchen settings', !cWrite);

    final ctx = await b.rpc('planner_context', params: {'p_list_id': listId}) as Map<String, dynamic>;
    final diets = (ctx['diets'] as List).toSet();
    report('planner_context merges diets', diets.containsAll({'vegetarian', 'nut_allergy'}), '$diets');
    report('planner_context merges dislikes', (ctx['dislikes'] as List).toSet().containsAll({'mushrooms', 'olives'}));
    report('spice is the most cautious member\'s', ctx['spice'] == 1);
    var cCtx = false;
    try {
      await c.rpc('planner_context', params: {'p_list_id': listId});
      cCtx = true;
    } catch (_) {}
    report('C cannot read planner_context', !cCtx);

    stdout.writeln('\nplan-meals');
    var (status, body) = await plan(c, {'list_id': listId, 'mode': 'week'});
    report('outsider gets 403', status == 403, '$status');
    (status, body) = await plan(a, {'list_id': listId, 'mode': 'bogus'});
    report('bad mode is a 400', status == 400, '$status');
    (status, body) = await plan(a, {'list_id': listId, 'mode': 'tonight', 'have': <String>[]});
    report('tonight without ingredients is a 400', status == 400, '$status');

    final sw = Stopwatch()..start();
    (status, body) = await plan(a, {'list_id': listId, 'mode': 'week'});
    final week = ((body['meals'] as List?) ?? const []).cast<Map<String, dynamic>>();
    report(
      'week plan returns 3 meals',
      status == 200 && week.length == 3,
      '$status in ${sw.elapsedMilliseconds} ms${body['left_out'] == null ? '' : ', left out: ${body['left_out']}'}',
    );
    stdout.writeln('     “${body['summary']}”');
    for (final m in week) {
      stdout.writeln(
        '     ${m['day']}: ${m['name']} · ${m['minutes']} min · ${m['appliance']} · '
        '${(m['ingredients'] as List).map((i) => i['name']).join(', ')}'
        '${m['reuse_note'] != null ? '  ↺ ${m['reuse_note']}' : ''}',
      );
    }
    report('days are Mon/Wed/Fri', week.map((m) => m['day']).join(',') == 'Monday,Wednesday,Friday');
    final bad = week.map(violation).whereType<String>().toList();
    report('respects vegetarian + nut allergy + dislikes', bad.isEmpty, bad.join(', '));
    final names = [
      for (final m in week)
        for (final i in m['ingredients'] as List) (i['name'] as String).toLowerCase(),
    ];
    final shared = names.where((n) => names.where((x) => x == n).length > 1).toSet();
    report('reuses ingredients across nights', shared.isNotEmpty, shared.join(', '));
    final notes = week.where((m) => m['reuse_note'] != null).toList();
    report('reuse notes on shared nights', notes.isNotEmpty, '${notes.length}/${week.length}');
    report('every reuse note is true', week.every(noteIsTrue));

    (status, body) = await plan(a, {'list_id': listId, 'mode': 'swap', 'week': week, 'index': 1});
    final swapped = ((body['meals'] as List?) ?? const []).cast<Map<String, dynamic>>();
    report(
      'swap returns one different meal for the same night',
      status == 200 && swapped.length == 1 && swapped[0]['name'] != week[1]['name'] && swapped[0]['day'] == 'Wednesday',
      swapped.isEmpty ? '$status $body' : '${week[1]['name']} → ${swapped[0]['name']}',
    );
    report('swap recomputes every night\'s reuse note', (body['week_notes'] as List?)?.length == week.length);

    (status, body) = await plan(a, {'list_id': listId, 'mode': 'nudge', 'week': week, 'index': 0, 'nudge': 'faster'});
    final nudged = ((body['meals'] as List?) ?? const []).cast<Map<String, dynamic>>();
    report(
      'nudge "faster" returns a quicker meal',
      status == 200 && nudged.length == 1 && (nudged[0]['minutes'] as int) <= (week[0]['minutes'] as int),
      nudged.isEmpty ? '$status $body' : '${week[0]['minutes']} → ${nudged[0]['minutes']} min: ${nudged[0]['name']}',
    );

    (status, body) = await plan(b, {
      'list_id': listId,
      'mode': 'tonight',
      'have': ['Spinach', 'Feta', 'Eggs', 'Tortillas'],
    });
    final tonight = ((body['meals'] as List?) ?? const []).cast<Map<String, dynamic>>();
    report('tonight returns 2-3 ideas', status == 200 && tonight.length >= 2 && tonight.length <= 3, '$status');
    for (final m in tonight) {
      stdout.writeln('     ${m['name']}  ↺ ${m['reuse_note']}');
    }

    stdout.writeln('\nMeal memory');
    final kept = week[0];
    final rid = await a.rpc(
      'save_recipe',
      params: {
        'p_list_id': listId,
        'p_recipe_id': null,
        'p_name': kept['name'],
        'p_ingredients': [
          for (final i in kept['ingredients'] as List) {'name': i['name'], 'quantity': i['quantity']},
        ],
      },
    ) as String;
    await a.from('meal_events').insert({
      'list_id': listId,
      'recipe_id': rid,
      'meal_name': kept['name'],
      'kind': 'kept',
      'user_id': aId,
    });
    await a.from('meal_events').insert({
      'list_id': listId,
      'meal_name': week[1]['name'],
      'kind': 'swapped',
      'user_id': aId,
    });
    await a.rpc('add_recipe_to_list', params: {'p_recipe_id': rid});
    await a.rpc('remove_recipe_from_list', params: {'p_recipe_id': rid});
    await a.rpc('add_recipe_to_list', params: {'p_recipe_id': rid});
    final added = await a.from('meal_events').select().eq('recipe_id', rid).eq('kind', 'added');
    report('adding to the list logs one "added" event (repeats deduped)', added.length == 1, '${added.length}');

    // A meal whose only grocery is already on the list merges instead of inserting.
    await a.from('items').insert({'list_id': listId, 'name': 'Zucchini'});
    final toast = await a.rpc(
      'save_recipe',
      params: {
        'p_list_id': listId,
        'p_recipe_id': null,
        'p_name': 'Zucchini fritters',
        'p_ingredients': [
          {'name': 'Zucchini'},
        ],
      },
    ) as String;
    await a.rpc('add_recipe_to_list', params: {'p_recipe_id': toast});
    final merged = await a.from('meal_events').select().eq('recipe_id', toast).eq('kind', 'added');
    report('a meal merged into existing items still counts as added', merged.length == 1, '${merged.length}');
    final bSees = await b.from('meal_events').select().eq('list_id', listId);
    report('B sees the household\'s meal memory', bSees.length >= 3, '${bSees.length}');
    report('C sees none of it', (await c.from('meal_events').select().eq('list_id', listId)).isEmpty);

    var spoof = false;
    try {
      await b.from('meal_events').insert({'list_id': listId, 'meal_name': 'x', 'kind': 'kept', 'user_id': aId});
      spoof = true;
    } catch (_) {}
    report('B cannot log events as A', !spoof);
    var cInsert = false;
    try {
      await c.from('meal_events').insert({'list_id': listId, 'meal_name': 'x', 'kind': 'kept', 'user_id': ids[2]});
      cInsert = true;
    } catch (_) {}
    report('C cannot log events on the list', !cInsert);

    await b.from('meal_events').insert({
      'list_id': listId,
      'recipe_id': rid,
      'meal_name': kept['name'],
      'kind': 'rated',
      'rating': 1,
      'user_id': ids[1],
    });
    final ctx2 = await a.rpc('planner_context', params: {'p_list_id': listId}) as Map<String, dynamic>;
    report('a 👍 shows up as liked', (ctx2['liked'] as List).contains(kept['name']));
    report('a swap shows up as passed on', (ctx2['passed_on'] as List).contains(week[1]['name']));
    report('the kept meal counts as recent', (ctx2['recent'] as List).contains(kept['name']));

    stdout.writeln('\nQuota');
    final fill = await http.post(
      Uri.parse('$url/rest/v1/ai_usage'),
      headers: {...adminHeaders, 'Prefer': 'return=minimal'},
      body: jsonEncode([
        for (var i = 0; i < 30; i++) {'user_id': ids[2], 'kind': 'plan'},
      ]),
    );
    if (fill.statusCode >= 300) throw 'fill quota: ${fill.body}';
    final cList = await c.rpc('create_list', params: {'p_name': 'C', 'p_emoji': '🧪'}) as String;
    (status, body) = await plan(c, {'list_id': cList, 'mode': 'week'});
    report('over the burst limit gets a 429 in Lamar\'s voice', status == 429, '$status ${body['error']}');
    await c.from('lists').delete().eq('id', cList);

    await a.from('lists').delete().eq('id', listId);
  } finally {
    await a.dispose();
    await b.dispose();
    await c.dispose();
    for (final id in ids) {
      await deleteUser(id);
    }
    stdout.writeln('\nCleaned up ${ids.length} test users.');
  }
  stdout.writeln(failures == 0 ? 'All good.' : '$failures check(s) failed.');
  exit(failures == 0 ? 0 : 1);
}
