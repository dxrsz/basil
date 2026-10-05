// End-to-end check of merge-on-add, meals → list with "Got it" skips, pantry
// memory, and "Tidy up" against the linked Supabase project. Creates
// throwaway users (…@example.invalid), exercises the RPCs/edge function as
// them, and deletes them (which cascades their lists and usage rows).
//
//   dart run tool/pantry_tidy_check.dart            # one tidy-list OpenAI call
//   dart run tool/pantry_tidy_check.dart --no-ai    # skip the OpenAI call
//
// Needs env.json (URL + publishable key) and the service-role key in
// ~/.supabase_basil_service_key (only used to create/delete the test users and
// to pre-fill the test user's quota usage for the 429 check).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:lamars_groceries/util/item_merge.dart';
import 'package:supabase/supabase.dart';

late final String url;
late final String publishable;
late final String service;

Map<String, String> get _admin => {
  'apikey': service,
  'Authorization': 'Bearer $service',
  'Content-Type': 'application/json',
};

Future<String> createUser(String email, String password) async {
  final res = await http.post(
    Uri.parse('$url/auth/v1/admin/users'),
    headers: _admin,
    body: jsonEncode({'email': email, 'password': password, 'email_confirm': true}),
  );
  if (res.statusCode >= 300) throw 'create user: ${res.body}';
  return (jsonDecode(res.body) as Map)['id'] as String;
}

Future<void> deleteUser(String id) => http.delete(Uri.parse('$url/auth/v1/admin/users/$id'), headers: _admin);

var failures = 0;
void check(String what, bool ok, [Object? detail]) {
  if (!ok) failures++;
  stdout.writeln('  ${ok ? '✓' : '✗ FAIL'}  $what${ok || detail == null ? '' : '  → $detail'}');
}

Future<List<Map<String, dynamic>>> items(SupabaseClient c, String listId) async =>
    (await c.from('items').select().eq('list_id', listId).order('created_at')).cast<Map<String, dynamic>>();

Map<String, dynamic>? byName(List<Map<String, dynamic>> rows, String name) {
  final key = normalizeItemName(name);
  for (final r in rows) {
    if (normalizeItemName(r['name'] as String) == key) return r;
  }
  return null;
}

Future<int?> errorStatus(Future<Object?> Function() f) async {
  try {
    await f();
    return null;
  } on FunctionException catch (e) {
    return e.status;
  } on PostgrestException catch (e) {
    return int.tryParse(e.code ?? '') ?? -1;
  }
}

Future<void> main(List<String> args) async {
  final env = jsonDecode(File('env.json').readAsStringSync()) as Map;
  url = env['SUPABASE_URL'] as String;
  publishable = env['SUPABASE_PUBLISHABLE_KEY'] as String;
  service = File('${Platform.environment['HOME']}/.supabase_basil_service_key').readAsStringSync().trim();
  final withAi = !args.contains('--no-ai');

  final rnd = Random.secure();
  String pw() => base64Url.encode(List.generate(18, (_) => rnd.nextInt(256)));
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final ids = <String>[];
  final a = SupabaseClient(url, publishable), b = SupabaseClient(url, publishable);

  try {
    final emailA = 'pantry-a-$stamp@example.invalid', emailB = 'pantry-b-$stamp@example.invalid';
    final pwA = pw(), pwB = pw();
    ids.add(await createUser(emailA, pwA));
    ids.add(await createUser(emailB, pwB));
    await a.auth.signInWithPassword(email: emailA, password: pwA);
    await b.auth.signInWithPassword(email: emailB, password: pwB);

    // ------------------------------------------------ SQL mirrors Dart
    stdout.writeln('SQL ↔ Dart test vectors');
    final cases = jsonDecode(File('test/fixtures/item_merge_cases.json').readAsStringSync()) as Map;
    var mismatches = 0;
    for (final c in (cases['names'] as List).cast<List>()) {
      final sql = await a.rpc('normalize_item_name', params: {'p_name': c[0]});
      if (sql != c[1] || normalizeItemName(c[0] as String) != c[1]) {
        mismatches++;
        stdout.writeln('     name ${jsonEncode(c[0])}: sql=${jsonEncode(sql)} expected=${jsonEncode(c[1])}');
      }
    }
    for (final c in (cases['combine'] as List).cast<List>()) {
      final sql = await a.rpc('combine_quantities', params: {'p_existing': c[0], 'p_added': c[1]});
      if (sql != c[2] || combineQuantities(c[0] as String?, c[1] as String?) != c[2]) {
        mismatches++;
        stdout.writeln(
          '     combine ${jsonEncode(c.sublist(0, 2))}: sql=${jsonEncode(sql)} expected=${jsonEncode(c[2])}',
        );
      }
    }
    check('all ${(cases['names'] as List).length + (cases['combine'] as List).length} vectors agree', mismatches == 0);

    // ------------------------------------------------------ add_item
    stdout.writeln('Merge on add');
    final list = await a.rpc('create_list', params: {'p_name': 'Pantry check', 'p_emoji': '🧪'}) as String;
    var r = await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'Avocados', 'p_quantity': '2'}) as Map;
    check('first add inserts', r['merged'] == false);
    r = await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'avocado', 'p_quantity': '1'}) as Map;
    check(
      '"avocado" merges into "Avocados"',
      r['merged'] == true && r['name'] == 'Avocados' && r['quantity'] == '3',
      r,
    );
    await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'Rice', 'p_quantity': '2 cups'});
    r = await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'rice', 'p_quantity': '1 cup'}) as Map;
    check('"2 cups" + "1 cup" → "3 cups"', r['quantity'] == '3 cups', r);
    await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'Cilantro', 'p_quantity': '1 bunch'});
    r = await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'cilantro', 'p_quantity': '2'}) as Map;
    check('incompatible units kept side by side', r['quantity'] == '1 bunch + 2', r);
    var rows = await items(a, list);
    check('no duplicates created', rows.length == 3, rows.map((e) => e['name']).toList());
    // Checked items don't absorb new adds.
    await a.from('items').update({'checked': true}).eq('id', byName(rows, 'cilantro')!['id'] as String);
    r = await a.rpc('add_item', params: {'p_list_id': list, 'p_name': 'Cilantro'}) as Map;
    check('a checked item is not merged into', r['merged'] == false);
    await a.rpc('clear_checked_items', params: {'p_list_id': list});

    check(
      'non-member can\'t add_item',
      await errorStatus(() => b.rpc('add_item', params: {'p_list_id': list, 'p_name': 'x'})) == 42501,
    );

    // --------------------------------------------- add_recipe_to_list
    stdout.writeln('Meals → list');
    final tacos = await a.rpc(
      'save_recipe',
      params: {
        'p_list_id': list,
        'p_recipe_id': null,
        'p_name': 'Tacos',
        'p_ingredients': [
          {'name': 'Olive oil', 'quantity': '2 tbsp'},
          {'name': 'Salt'},
          {'name': 'Avocado', 'quantity': '1'},
          {'name': 'Jasmine rice', 'quantity': '1 cup'},
          {'name': 'Tortillas', 'quantity': '1 pack'},
          {'name': 'Limes', 'quantity': '2'},
          {'name': 'lime', 'quantity': '1'},
        ],
      },
    ) as String;
    var n = await a.rpc(
      'add_recipe_to_list',
      params: {
        'p_recipe_id': tacos,
        'p_skip': ['olive oil', 'SALT'],
      },
    );
    rows = await items(a, list);
    check('returns added + merged count', n == 4, n); // avocado (merge), rice, tortillas, limes
    check('skipped "Got it" items stay off', byName(rows, 'Olive oil') == null && byName(rows, 'Salt') == null);
    final avo = byName(rows, 'avocado')!;
    check(
      'merged item is tagged with the meal',
      avo['quantity'] == '4' && (avo['recipe_ids'] as List).contains(tacos) && avo['recipe_id'] == tacos,
      avo,
    );
    check('repeated lines combine', byName(rows, 'lime')?['quantity'] == '3', byName(rows, 'lime'));
    final rice = byName(rows, 'jasmine rice')!;
    check('new items carry recipe_id + recipe_ids', rice['recipe_id'] == tacos && rice['manual'] == false, rice);
    n = await a.rpc(
      'add_recipe_to_list',
      params: {
        'p_recipe_id': tacos,
        'p_skip': ['Olive oil', 'salt'],
      },
    );
    check('re-adding is idempotent', n == 0 && (await items(a, list)).length == rows.length, n);

    final bowls = await a.rpc(
      'save_recipe',
      params: {
        'p_list_id': list,
        'p_recipe_id': null,
        'p_name': 'Rice bowls',
        'p_ingredients': [
          {'name': 'Jasmine rice', 'quantity': '2 cups'},
          {'name': 'Edamame', 'quantity': '1 bag'},
        ],
      },
    ) as String;
    // The original one-argument call (older app versions) still works.
    check('legacy signature works', await a.rpc('add_recipe_to_list', params: {'p_recipe_id': bowls}) == 2);
    rows = await items(a, list);
    final shared = byName(rows, 'jasmine rice')!;
    check(
      'item from two meals: quantities combined, both meals kept, first is primary',
      shared['quantity'] == '3 cups' &&
          (shared['recipe_ids'] as List).toSet().containsAll([tacos, bowls]) &&
          shared['recipe_id'] == tacos,
      shared,
    );

    // Checked-off ingredient isn't re-added mid-shop.
    await a.from('items').update({'checked': true}).eq('id', byName(rows, 'tortillas')!['id'] as String);
    await a.from('items').delete().eq('id', byName(rows, 'lime')!['id'] as String);
    n = await a.rpc(
      'add_recipe_to_list',
      params: {
        'p_recipe_id': tacos,
        'p_skip': ['Olive oil', 'salt'],
      },
    );
    rows = await items(a, list);
    check(
      'in-cart items aren\'t re-added; removed ones are',
      n == 1 && rows.where((e) => normalizeItemName(e['name'] as String) == 'tortilla').length == 1,
      n,
    );

    stdout.writeln('Taking a meal off the list');
    final removed = await a.rpc('remove_recipe_from_list', params: {'p_recipe_id': tacos});
    rows = await items(a, list);
    final riceAfter = byName(rows, 'jasmine rice')!;
    check('only-from-this-meal items removed (limes)', byName(rows, 'lime') == null && removed == 1, removed);
    check(
      'shared item stays, re-tagged to the other meal',
      riceAfter['recipe_id'] == bowls && (riceAfter['recipe_ids'] as List).length == 1,
      riceAfter,
    );
    final avoAfter = byName(rows, 'avocado')!;
    check(
      'item typed by hand stays, untagged',
      avoAfter['recipe_id'] == null && (avoAfter['recipe_ids'] as List).isEmpty,
      avoAfter,
    );
    check('checked items untouched', byName(rows, 'tortillas')?['checked'] == true);

    // Deleting a meal keeps its items (FK sets recipe_id null) and doesn't break.
    await a.from('recipes').delete().eq('id', bowls);
    rows = await items(a, list);
    check('deleting a meal keeps its items', byName(rows, 'jasmine rice')?['recipe_id'] == null);

    // Legacy insert with only recipe_id gets recipe_ids filled in.
    final legacy = await a
        .from('items')
        .insert({'list_id': list, 'name': 'Legacy', 'recipe_id': tacos})
        .select()
        .single();
    check(
      'trigger syncs recipe_ids for recipe_id-only writers',
      (legacy['recipe_ids'] as List).contains(tacos) && legacy['manual'] == false,
      legacy,
    );

    // -------------------------------------------------------- pantry
    stdout.writeln('Pantry memory');
    await a.rpc(
      'remember_pantry',
      params: {
        'p_list_id': list,
        'p_have': ['Tortilla chips', 'tortilla chip', 'Ghee'],
        'p_forget': <String>[],
      },
    );
    var pantry = (await a.from('pantry_staples').select().eq('list_id', list)).cast<Map<String, dynamic>>();
    check('remembered, deduped by normalised name', pantry.length == 2, pantry.map((e) => e['name_key']).toList());
    await a.from('pantry_staples').update({'always': true}).eq('list_id', list).eq('name_key', 'ghee');
    await a.rpc(
      'remember_pantry',
      params: {
        'p_list_id': list,
        'p_have': <String>[],
        'p_forget': ['Tortilla Chips', 'ghee'],
      },
    );
    pantry = (await a.from('pantry_staples').select().eq('list_id', list)).cast<Map<String, dynamic>>();
    check('forget removes answers but keeps pinned staples', pantry.length == 1 && pantry.single['name'] == 'Ghee');
    await a.from('pantry_staples').upsert({
      'list_id': list,
      'name': 'GHEE',
      'always': true,
    }, onConflict: 'list_id,name_key');
    check('upsert by name_key works', (await a.from('pantry_staples').select().eq('list_id', list)).length == 1);
    check('non-member can\'t read pantry', (await b.from('pantry_staples').select().eq('list_id', list)).isEmpty);
    check(
      'non-member can\'t remember_pantry',
      await errorStatus(
            () => b.rpc(
              'remember_pantry',
              params: {
                'p_list_id': list,
                'p_have': ['x'],
              },
            ),
          ) ==
          42501,
    );

    // ------------------------------------------------------------ tidy
    stdout.writeln('Tidy up');
    await a.from('items').delete().eq('list_id', list);
    Future<String> add(String name, [String? q]) async =>
        ((await a.rpc('add_item', params: {'p_list_id': list, 'p_name': name, 'p_quantity': q})) as Map)['id']
            as String;
    final thighs = await add('Chicken thighs', '1 lb');
    final chicken = await add('Chicken', '2 lb');
    final tomatos = await add('Tomatos', '3');
    await add('Milk', '1 gallon');
    await add('Oat milk', '1 carton');
    await add('Lemons', '2');
    await add('Limes', '2');

    check(
      'non-member gets 404 from tidy-list',
      await errorStatus(() => b.functions.invoke('tidy-list', body: {'list_id': list})) == 404,
    );
    check(
      'bad input gets 400',
      await errorStatus(() => a.functions.invoke('tidy-list', body: {'list_id': 'nope'})) == 400,
    );

    // Quota: B's own list, with B's tidy usage pre-filled to the burst limit.
    final listB = await b.rpc('create_list', params: {'p_name': 'Quota', 'p_emoji': '🧪'}) as String;
    await b.rpc('add_item', params: {'p_list_id': listB, 'p_name': 'Eggs'});
    await b.rpc('add_item', params: {'p_list_id': listB, 'p_name': 'Milk'});
    final fill = await http.post(
      Uri.parse('$url/rest/v1/ai_usage'),
      headers: _admin,
      body: jsonEncode([
        for (var i = 0; i < 20; i++) {'user_id': ids[1], 'kind': 'tidy'},
      ]),
    );
    check('pre-filled usage', fill.statusCode < 300, fill.body);
    try {
      await b.functions.invoke('tidy-list', body: {'list_id': listB});
      check('over the limit → 429', false, 'no error');
    } on FunctionException catch (e) {
      check('over the limit → 429 with Lamar\'s message', e.status == 429, '${e.status} ${e.details}');
      stdout.writeln('     ${e.details}');
    }

    if (withAi) {
      final res = await a.functions.invoke('tidy-list', body: {'list_id': list});
      final proposals = ((res.data as Map)['proposals'] as List).cast<Map<String, dynamic>>();
      stdout.writeln('     proposals: ${jsonEncode(proposals)}');
      final merge = proposals.where((p) {
        final ids = (p['item_ids'] as List).toSet();
        return p['kind'] == 'merge' && ids.contains(thighs) && ids.contains(chicken);
      }).firstOrNull;
      check('proposes merging the chicken', merge != null);
      final fix = proposals.where((p) => (p['item_ids'] as List).contains(tomatos)).firstOrNull;
      check('proposes fixing "Tomatos"', fix != null && (fix['name'] as String).toLowerCase() == 'tomatoes', fix);
      final bad = proposals.where((p) {
        final names = {for (final id in p['item_ids'] as List) id};
        return p['kind'] == 'merge' &&
            names.length > 1 &&
            (p['name'] as String).toLowerCase().contains('lem') &&
            (p['name'] as String).toLowerCase().contains('lim');
      });
      check('doesn\'t merge lemons with limes', bad.isEmpty);
    }

    // apply_tidy, independent of what the model said.
    final applied = await a.rpc(
      'apply_tidy',
      params: {
        'p_list_id': list,
        'p_changes': [
          {
            'keep_id': thighs,
            'remove_ids': [chicken],
            'name': 'Chicken thighs',
            'quantity': '3 lb',
          },
          {'keep_id': tomatos, 'remove_ids': <String>[], 'name': 'Tomatoes', 'quantity': '3'},
          {
            'keep_id': chicken, // already merged away above → skipped
            'remove_ids': <String>[],
            'name': 'Ghost',
          },
        ],
      },
    );
    rows = await items(a, list);
    check('apply_tidy applies valid changes, skips stale ones', applied == 2, applied);
    check(
      'merged + renamed',
      byName(rows, 'chicken thighs')?['quantity'] == '3 lb' &&
          byName(rows, 'chicken') == null &&
          byName(rows, 'tomatoes')?['category'] == 'Produce',
      rows.map((e) => '${e['name']}·${e['quantity']}').toList(),
    );
    check(
      'non-member can\'t apply_tidy',
      await errorStatus(
            () => b.rpc(
              'apply_tidy',
              params: {
                'p_list_id': list,
                'p_changes': [
                  {'keep_id': thighs, 'remove_ids': <String>[], 'name': 'pwned'},
                ],
              },
            ),
          ) ==
          42501,
    );
    // B can't smuggle A's items into a change on B's own list either.
    final smuggled = await b.rpc(
      'apply_tidy',
      params: {
        'p_list_id': listB,
        'p_changes': [
          {'keep_id': thighs, 'remove_ids': <String>[], 'name': 'pwned'},
        ],
      },
    );
    check('other lists\' items are ignored', smuggled == 0 && byName(await items(a, list), 'pwned') == null);

    // Deleting a list with merged, multi-meal items cascades cleanly.
    await a.from('lists').delete().eq('id', list);
    check('list delete cascades', (await a.from('items').select().eq('list_id', list)).isEmpty);
  } catch (e, st) {
    failures++;
    stdout.writeln('✗ FAIL  unexpected: $e\n$st');
  } finally {
    await a.dispose();
    await b.dispose();
    for (final id in ids) {
      await deleteUser(id);
    }
    stdout.writeln('Cleaned up ${ids.length} test users.');
  }
  stdout.writeln(failures == 0 ? 'All checks passed.' : '$failures check(s) FAILED.');
  exit(failures == 0 ? 0 : 1);
}
