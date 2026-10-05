import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/models.dart';
import '../util/categories.dart';
import '../util/item_merge.dart';
import 'live_query.dart';
import 'offline/kv_store.dart';
import 'offline/outbox.dart';

/// All reads/writes against Supabase. Widgets go through providers.dart;
/// mutations come straight here.
class Repository {
  Repository(this._db, {this._outbox, this._cache});

  final SupabaseClient _db;

  /// Item changes go through here so they work offline (null: write directly).
  final Outbox? _outbox;

  /// Last known rows, so screens open (and work) offline.
  final RowCache? _cache;

  /// For things that need the server (meals, AI): fail fast and kindly offline.
  void _requireOnline() {
    if (_outbox != null && !_outbox.online) throw const OfflineException();
  }

  String? get userId => _db.auth.currentUser?.id;

  // ------------------------------------------------------------------ auth

  Future<void> signIn(OAuthProvider provider) async {
    await _db.auth.signInWithOAuth(
      provider,
      // On web, come back to this page (same tab); on mobile, the app's URL scheme.
      redirectTo: kIsWeb ? Uri.base.origin : Config.authRedirect,
      authScreenLaunchMode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
    );
  }

  Future<void> signOut() async {
    await _cache?.clear();
    await _db.auth.signOut();
  }

  /// OAuth providers switched on in the Supabase dashboard, so the sign-in
  /// screen only offers ones that will work (e.g. Apple before it's set up).
  static Future<Set<OAuthProvider>> enabledProviders() async {
    final res = await http
        .get(Uri.parse('${Config.supabaseUrl}/auth/v1/settings'), headers: {'apikey': Config.supabaseKey})
        .timeout(const Duration(seconds: 5));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final external = (body['external'] as Map<String, dynamic>?) ?? const {};
    return {
      for (final p in const [OAuthProvider.apple, OAuthProvider.google])
        if (external[p.name] == true) p,
    };
  }

  // ----------------------------------------------------------------- lists

  Stream<List<String>> watchMyListIds() {
    final uid = userId;
    if (uid == null) return Stream.value(const []);
    return liveRows(
      _db,
      table: 'list_members',
      column: 'user_id',
      value: uid,
      primaryKey: ['list_id', 'user_id'],
      cache: _cache,
    ).map((rows) => rows.map((r) => r['list_id'] as String).toList()..sort());
  }

  Stream<List<ShoppingList>> watchLists(List<String> ids) {
    if (ids.isEmpty) return Stream.value(const []);
    return liveRows(
      _db,
      table: 'lists',
      column: 'id',
      value: ids,
      orderBy: 'created_at',
      cache: _cache,
    ).map((rows) => rows.map(ShoppingList.fromJson).toList());
  }

  Future<String> createList(String name, String emoji) async {
    final id = await _db.rpc('create_list', params: {'p_name': name, 'p_emoji': emoji});
    return id as String;
  }

  Future<void> updateList(String id, {required String name, required String emoji}) =>
      _db.from('lists').update({'name': name, 'emoji': emoji}).eq('id', id);

  Future<void> deleteList(String id) => _db.from('lists').delete().eq('id', id);

  Future<void> leaveList(String id) => _db.from('list_members').delete().eq('list_id', id).eq('user_id', userId!);

  Future<void> removeMember(String listId, String memberId) =>
      _db.from('list_members').delete().eq('list_id', listId).eq('user_id', memberId);

  Future<String> createInvite(String listId) async {
    final code = await _db.rpc('create_list_invite', params: {'p_list_id': listId});
    return code as String;
  }

  Future<String> joinList(String code) async {
    final id = await _db.rpc('join_list', params: {'p_code': code});
    return id as String;
  }

  Stream<List<Member>> watchMembers(String listId) {
    final cacheKey = 'members+profiles|$listId';
    return liveRows(
      _db,
      table: 'list_members',
      column: 'list_id',
      value: listId,
      primaryKey: ['list_id', 'user_id'],
      cache: _cache,
    )
    // The realtime payload has no profile data, so re-read with the join.
    .asyncMap((_) async {
      final List<Map<String, dynamic>> rows;
      try {
        rows = await _db
            .from('list_members')
            .select('user_id, role, profiles(display_name, avatar_url)')
            .eq('list_id', listId)
            .order('joined_at')
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        final cached = _cache?.read(cacheKey); // offline: who was on the list last time
        if (cached == null) rethrow;
        return cached.map(Member.fromJson).toList();
      }
      _cache?.write(cacheKey, rows);
      return rows.map(Member.fromJson).toList();
    });
  }

  // ----------------------------------------------------------------- items

  Stream<List<Item>> watchItems(String listId) {
    final rows = liveRows(_db, table: 'items', column: 'list_id', value: listId, orderBy: 'created_at', cache: _cache);
    final outbox = _outbox;
    return (outbox == null ? rows : _withOutbox(outbox, listId, rows)).map((rows) {
      for (final r in rows) {
        _knownItemLists[r['id'] as String] = listId;
      }
      return rows.map(Item.fromJson).toList();
    });
  }

  /// Server rows with queued (offline or in-flight) changes applied on top.
  static Stream<List<Map<String, dynamic>>> _withOutbox(
    Outbox outbox,
    String listId,
    Stream<List<Map<String, dynamic>>> rows,
  ) {
    late final StreamController<List<Map<String, dynamic>>> out;
    StreamSubscription<void>? serverSub, outboxSub;
    List<Map<String, dynamic>>? latest;
    void emit() {
      final r = latest;
      if (r != null && !out.isClosed) out.add(outbox.apply(listId, r));
    }

    out = StreamController(
      onListen: () {
        serverSub = rows.listen((r) {
          latest = r;
          emit();
        }, onError: out.addError);
        outboxSub = outbox.changes.listen((_) => emit());
      },
      onCancel: () async {
        await outboxSub?.cancel();
        await serverSub?.cancel();
      },
    );
    return out.stream;
  }

  /// Adds a typed item. If the same item (plural/case-insensitively) is
  /// already on the list to get, it's merged into that one instead and the
  /// quantities are combined; [AddItemResult.merged] says which happened.
  Future<AddItemResult> addItem(String listId, String input) async {
    final parsed = parseItemInput(input);
    final outbox = _outbox;
    // Offline, or older changes still queued (they must land first): add it
    // on this device and let the outbox sync it.
    if (outbox != null && (!outbox.online || outbox.queued.isNotEmpty)) return _addItemLocally(outbox, listId, parsed);
    try {
      final res = await _db
          .rpc(
            'add_item',
            params: {
              'p_list_id': listId,
              'p_name': parsed.name,
              'p_quantity': parsed.quantity,
              'p_category': categorize(parsed.name),
            },
          )
          .timeout(const Duration(seconds: 8));
      return AddItemResult.fromJson(res as Map<String, dynamic>);
    } catch (e) {
      if (outbox == null || !isTransientError(e)) rethrow;
      outbox.setNetworkAvailable(false); // couldn't reach the server: we're offline
      return _addItemLocally(outbox, listId, parsed);
    }
  }

  Future<void> updateItem(String id, {required String name, String? quantity, String? listId}) {
    final changes = {
      'name': name,
      'quantity': (quantity?.trim().isEmpty ?? true) ? null : quantity!.trim(),
      'category': categorize(name),
    };
    final outbox = _outbox;
    final list = listId ?? _listOf(id);
    if (outbox != null && list != null) return outbox.updateItem(list, id, changes);
    return _db.from('items').update(changes).eq('id', id);
  }

  Future<void> setChecked(String id, bool checked, {String? listId}) {
    final outbox = _outbox;
    final list = listId ?? _listOf(id);
    if (outbox != null && list != null) return outbox.updateItem(list, id, {'checked': checked});
    return _db.from('items').update({'checked': checked}).eq('id', id);
  }

  Future<void> deleteItem(String id, {String? listId}) {
    final outbox = _outbox;
    final list = listId ?? _listOf(id);
    if (outbox != null && list != null) return outbox.deleteItem(list, id);
    return _db.from('items').delete().eq('id', id);
  }

  Future<void> restoreItem(Item item) {
    final row = {
      'id': item.id,
      'list_id': item.listId,
      'name': item.name,
      'quantity': item.quantity,
      'category': item.category,
      'checked': item.checked,
      'recipe_id': item.recipeId,
      'recipe_ids': item.recipeIds,
    };
    final outbox = _outbox;
    if (outbox != null) return outbox.insertItem({...row, 'created_at': item.createdAt.toUtc().toIso8601String()});
    return _db.from('items').insert(row);
  }

  /// Removes checked items. With [ids] (what the user saw checked) only those
  /// go, and it works offline; without, everything checked on the server.
  Future<int> clearChecked(String listId, {Iterable<String>? ids}) async {
    final outbox = _outbox;
    if (outbox != null && ids != null) {
      final targets = ids.toList();
      await outbox.clearChecked(listId, targets);
      return targets.length;
    }
    return (await _db.rpc('clear_checked_items', params: {'p_list_id': listId})) as int;
  }

  /// [addItem] without the server: merges into a matching unchecked item this
  /// device knows about (as `add_item` does), else adds a new one with a
  /// client-made id so it can be edited or removed before it syncs.
  Future<AddItemResult> _addItemLocally(Outbox outbox, String listId, ({String name, String? quantity}) parsed) async {
    final key = normalizeItemName(parsed.name);
    final known = outbox.apply(listId, _cache?.read('items|list_id|$listId') ?? const [])
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    for (final r in known) {
      if (r['checked'] == true || normalizeItemName(r['name'] as String) != key) continue;
      final id = r['id'] as String;
      final quantity = combineQuantities(r['quantity'] as String?, parsed.quantity);
      await outbox.updateItem(listId, id, {'quantity': quantity, 'manual': true});
      return AddItemResult(id: id, merged: true, name: r['name'] as String, quantity: quantity);
    }
    final id = const Uuid().v4();
    await outbox.insertItem({
      'id': id,
      'list_id': listId,
      'name': parsed.name,
      'quantity': parsed.quantity,
      'category': categorize(parsed.name),
      'manual': true,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    return AddItemResult(id: id, merged: false, name: parsed.name, quantity: parsed.quantity);
  }

  /// item id -> list id for every item seen, so item calls that don't pass a
  /// list id can still be queued.
  final _knownItemLists = <String, String>{};

  String? _listOf(String itemId) {
    for (final op in _outbox?.queued ?? const <OutboxOp>[]) {
      if (op.id == itemId) return op.listId;
    }
    return _knownItemLists[itemId];
  }

  // --------------------------------------------------------------- recipes

  Stream<List<Recipe>> watchRecipes(String listId) {
    return liveRows(
      _db,
      table: 'recipes',
      column: 'list_id',
      value: listId,
      orderBy: 'created_at',
      ascending: false,
    ).map((rows) => rows.map(Recipe.fromJson).toList());
  }

  Stream<List<Ingredient>> watchIngredients(String listId) {
    return liveRows(
      _db,
      table: 'recipe_ingredients',
      column: 'list_id',
      value: listId,
      orderBy: 'position',
    ).map((rows) => rows.map(Ingredient.fromJson).toList());
  }

  Future<String> saveRecipe({
    required String listId,
    String? recipeId,
    required String name,
    required List<Ingredient> ingredients,
  }) async {
    _requireOnline();
    final id = await _db.rpc(
      'save_recipe',
      params: {
        'p_list_id': listId,
        'p_recipe_id': recipeId,
        'p_name': name,
        'p_ingredients': ingredients.map((i) => i.toJson()).toList(),
      },
    );
    return id as String;
  }

  Future<void> deleteRecipe(String id) => _db.from('recipes').delete().eq('id', id);

  /// Puts a meal's ingredients on its list, merging with items already there
  /// and leaving out anything named in [skip] (things the household has).
  /// UI code should go through `showAddMealToListFlow` (features/pantry) so
  /// people get to say what they already have.
  Future<int> addRecipeToList(String recipeId, {List<String>? skip}) async => (await _db.rpc(
    'add_recipe_to_list',
    params: {'p_recipe_id': recipeId, if (skip != null && skip.isNotEmpty) 'p_skip': skip},
  )) as int;

  Future<int> removeRecipeFromList(String recipeId) async =>
      (await _db.rpc('remove_recipe_from_list', params: {'p_recipe_id': recipeId})) as int;

  // ---------------------------------------------------------------- pantry

  Stream<List<PantryStaple>> watchPantry(String listId) {
    return liveRows(
      _db,
      table: 'pantry_staples',
      column: 'list_id',
      value: listId,
      orderBy: 'name_key',
    ).map((rows) => rows.map(PantryStaple.fromJson).toList());
  }

  /// Records answers from the "Got this already?" review: [have] is
  /// remembered (or re-confirmed); [forget] is forgotten unless pinned.
  Future<void> rememberPantry(String listId, {required List<String> have, List<String> forget = const []}) =>
      _db.rpc('remember_pantry', params: {'p_list_id': listId, 'p_have': have, 'p_forget': forget});

  /// Adds (or pins) something the household always has.
  Future<void> addPantryStaple(String listId, String name) => _db.from('pantry_staples').upsert({
    'list_id': listId,
    'name': name.trim(),
    'always': true,
  }, onConflict: 'list_id,name_key');

  Future<void> setPantryAlways(String id, bool always) => _db
      .from('pantry_staples')
      .update({'always': always, 'confirmed_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', id);

  Future<void> deletePantryStaple(String id) => _db.from('pantry_staples').delete().eq('id', id);

  // ------------------------------------------------------------------ tidy

  /// Asks Lamar (the `tidy-list` edge function) for proposed clean-ups.
  Future<List<TidyProposal>> proposeTidy(String listId) async {
    final res = await _db.functions.invoke('tidy-list', body: {'list_id': listId});
    final data = res.data as Map<String, dynamic>;
    return (data['proposals'] as List).cast<Map<String, dynamic>>().map(TidyProposal.fromJson).toList();
  }

  /// Applies accepted proposals atomically; returns how many were applied
  /// (ones whose items changed in the meantime are skipped).
  Future<int> applyTidy(String listId, List<TidyProposal> accepted) async => (await _db.rpc(
    'apply_tidy',
    params: {'p_list_id': listId, 'p_changes': accepted.map((p) => p.toChange()).toList()},
  )) as int;

  // -------------------------------------------------------------------- AI

  /// Kicks off image generation. The edge function returns immediately and
  /// the finished image arrives through the recipes realtime stream.
  Future<void> generateImage(String recipeId, {bool force = false}) async {
    _requireOnline();
    await _db.functions.invoke('generate-recipe-image', body: {'recipe_id': recipeId, 'force': force});
  }

  Future<List<Suggestion>> suggestIngredients({
    required String meal,
    required List<String> ingredients,
    required List<String> dismissed,
    bool autofill = false,
  }) async {
    _requireOnline();
    final res = await _db.functions.invoke(
      'suggest-ingredients',
      body: {
        'meal': meal,
        'ingredients': ingredients,
        'dismissed': dismissed,
        'mode': autofill ? 'autofill' : 'review',
      },
    );
    final data = res.data as Map<String, dynamic>;
    return (data['suggestions'] as List).cast<Map<String, dynamic>>().map(Suggestion.fromJson).toList();
  }
}

class AddItemResult {
  const AddItemResult({required this.id, required this.merged, required this.name, required this.quantity});

  final String id;

  /// True when the item was combined with one already on the list.
  final bool merged;
  final String name;
  final String? quantity;

  factory AddItemResult.fromJson(Map<String, dynamic> j) => AddItemResult(
    id: j['id'] as String,
    merged: j['merged'] as bool,
    name: j['name'] as String,
    quantity: j['quantity'] as String?,
  );
}

/// Turns Supabase exceptions into something worth showing a person.
String friendlyError(Object e) {
  if (e is OfflineException) return e.message;
  if (e is PostgrestException) return e.message;
  if (e is FunctionException) {
    final details = e.details;
    if (details is Map && details['error'] is String) return details['error'] as String;
    return 'Something went wrong (${e.status})';
  }
  if (e is AuthException) return e.message;
  return 'Something went wrong. Check your connection and try again.';
}

/// Thrown at once, without trying, for things that need the server while
/// we're offline. The shopping list itself keeps working offline.
class OfflineException implements Exception {
  const OfflineException([this.message = 'Lamar needs a connection for that. Your list still works offline.']);

  final String message;

  @override
  String toString() => message;
}
