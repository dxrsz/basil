import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/models.dart';
import '../util/categories.dart';

/// All reads/writes against Supabase. Widgets go through providers.dart;
/// mutations come straight here.
class Repository {
  Repository(this._db);

  final SupabaseClient _db;

  String? get userId => _db.auth.currentUser?.id;

  // ------------------------------------------------------------------ auth

  Future<void> signIn(OAuthProvider provider) async {
    await _db.auth.signInWithOAuth(
      provider,
      redirectTo: Config.authRedirect,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
  }

  Future<void> signOut() => _db.auth.signOut();

  /// OAuth providers switched on in the Supabase dashboard, so the sign-in
  /// screen only offers ones that will work (e.g. Apple before it's set up).
  static Future<Set<OAuthProvider>> enabledProviders() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse('${Config.supabaseUrl}/auth/v1/settings'));
      req.headers.set('apikey', Config.supabaseKey);
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final external = (body['external'] as Map<String, dynamic>?) ?? const {};
      return {
        for (final p in const [OAuthProvider.apple, OAuthProvider.google])
          if (external[p.name] == true) p,
      };
    } finally {
      client.close();
    }
  }

  // ----------------------------------------------------------------- lists

  Stream<List<String>> watchMyListIds() {
    final uid = userId;
    if (uid == null) return Stream.value(const []);
    return _db
        .from('list_members')
        .stream(primaryKey: ['list_id', 'user_id'])
        .eq('user_id', uid)
        .map((rows) => rows.map((r) => r['list_id'] as String).toList()..sort());
  }

  Stream<List<ShoppingList>> watchLists(List<String> ids) {
    if (ids.isEmpty) return Stream.value(const []);
    return _db
        .from('lists')
        .stream(primaryKey: ['id'])
        .inFilter('id', ids)
        .order('created_at')
        .map((rows) => rows.map(ShoppingList.fromJson).toList());
  }

  Future<String> createList(String name, String emoji) async {
    final id = await _db.rpc('create_list', params: {'p_name': name, 'p_emoji': emoji});
    return id as String;
  }

  Future<void> updateList(String id, {required String name, required String emoji}) =>
      _db.from('lists').update({'name': name, 'emoji': emoji}).eq('id', id);

  Future<void> deleteList(String id) => _db.from('lists').delete().eq('id', id);

  Future<void> leaveList(String id) =>
      _db.from('list_members').delete().eq('list_id', id).eq('user_id', userId!);

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
    return _db
        .from('list_members')
        .stream(primaryKey: ['list_id', 'user_id'])
        .eq('list_id', listId)
        // The realtime payload has no profile data, so re-read with the join.
        .asyncMap((_) async {
          final rows = await _db
              .from('list_members')
              .select('user_id, role, profiles(display_name, avatar_url)')
              .eq('list_id', listId)
              .order('joined_at');
          return rows.map(Member.fromJson).toList();
        });
  }

  // ----------------------------------------------------------------- items

  Stream<List<Item>> watchItems(String listId) {
    return _db
        .from('items')
        .stream(primaryKey: ['id'])
        .eq('list_id', listId)
        .order('created_at')
        .map((rows) => rows.map(Item.fromJson).toList());
  }

  Future<void> addItem(String listId, String input) {
    final parsed = parseItemInput(input);
    return _db.from('items').insert({
      'list_id': listId,
      'name': parsed.name,
      'quantity': parsed.quantity,
      'category': categorize(parsed.name),
    });
  }

  Future<void> updateItem(String id, {required String name, String? quantity}) {
    return _db.from('items').update({
      'name': name,
      'quantity': (quantity?.trim().isEmpty ?? true) ? null : quantity!.trim(),
      'category': categorize(name),
    }).eq('id', id);
  }

  Future<void> setChecked(String id, bool checked) =>
      _db.from('items').update({'checked': checked}).eq('id', id);

  Future<void> deleteItem(String id) => _db.from('items').delete().eq('id', id);

  Future<void> restoreItem(Item item) => _db.from('items').insert({
        'id': item.id,
        'list_id': item.listId,
        'name': item.name,
        'quantity': item.quantity,
        'category': item.category,
        'checked': item.checked,
        'recipe_id': item.recipeId,
      });

  Future<int> clearChecked(String listId) async =>
      (await _db.rpc('clear_checked_items', params: {'p_list_id': listId})) as int;

  // --------------------------------------------------------------- recipes

  Stream<List<Recipe>> watchRecipes(String listId) {
    return _db
        .from('recipes')
        .stream(primaryKey: ['id'])
        .eq('list_id', listId)
        .order('created_at', ascending: false)
        .map((rows) => rows.map(Recipe.fromJson).toList());
  }

  Stream<List<Ingredient>> watchIngredients(String listId) {
    return _db
        .from('recipe_ingredients')
        .stream(primaryKey: ['id'])
        .eq('list_id', listId)
        .order('position')
        .map((rows) => rows.map(Ingredient.fromJson).toList());
  }

  Future<String> saveRecipe({
    required String listId,
    String? recipeId,
    required String name,
    required List<Ingredient> ingredients,
  }) async {
    final id = await _db.rpc('save_recipe', params: {
      'p_list_id': listId,
      'p_recipe_id': recipeId,
      'p_name': name,
      'p_ingredients': ingredients.map((i) => i.toJson()).toList(),
    });
    return id as String;
  }

  Future<void> deleteRecipe(String id) => _db.from('recipes').delete().eq('id', id);

  Future<int> addRecipeToList(String recipeId) async =>
      (await _db.rpc('add_recipe_to_list', params: {'p_recipe_id': recipeId})) as int;

  Future<int> removeRecipeFromList(String recipeId) async =>
      (await _db.rpc('remove_recipe_from_list', params: {'p_recipe_id': recipeId})) as int;

  // -------------------------------------------------------------------- AI

  /// Kicks off image generation. The edge function returns immediately and
  /// the finished image arrives through the recipes realtime stream.
  Future<void> generateImage(String recipeId, {bool force = false}) async {
    await _db.functions.invoke(
      'generate-recipe-image',
      body: {'recipe_id': recipeId, 'force': force},
    );
  }

  Future<List<Suggestion>> suggestIngredients({
    required String meal,
    required List<String> ingredients,
    required List<String> dismissed,
    bool autofill = false,
  }) async {
    final res = await _db.functions.invoke('suggest-ingredients', body: {
      'meal': meal,
      'ingredients': ingredients,
      'dismissed': dismissed,
      'mode': autofill ? 'autofill' : 'review',
    });
    final data = res.data as Map<String, dynamic>;
    return (data['suggestions'] as List)
        .cast<Map<String, dynamic>>()
        .map(Suggestion.fromJson)
        .toList();
  }
}

/// Turns Supabase exceptions into something worth showing a person.
String friendlyError(Object e) {
  if (e is PostgrestException) return e.message;
  if (e is FunctionException) {
    final details = e.details;
    if (details is Map && details['error'] is String) return details['error'] as String;
    return 'Something went wrong (${e.status})';
  }
  if (e is AuthException) return e.message;
  return 'Something went wrong. Check your connection and try again.';
}
