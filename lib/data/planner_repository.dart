import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/planner/planner_models.dart';
import 'live_query.dart';
import 'providers.dart';
import 'repository.dart';

/// Supabase I/O for the meal planner: kitchen profile, meal memory and the
/// plan-meals edge function. Kept beside [Repository] rather than in it so the
/// planner stays self-contained.
class PlannerRepository {
  PlannerRepository(this._db, this._repo);

  final SupabaseClient _db;
  final Repository _repo;

  String? get _uid => _db.auth.currentUser?.id;

  // --------------------------------------------------------------- profile

  /// The signed-in user's tastes, or null if they've never filled them in.
  Future<TasteProfile?> fetchTasteProfile() async {
    final uid = _uid;
    if (uid == null) return null;
    final row = await _db.from('taste_profiles').select().eq('user_id', uid).maybeSingle();
    return row == null ? null : TasteProfile.fromJson(row);
  }

  Future<void> saveTasteProfile(TasteProfile p) => _db.from('taste_profiles').upsert({'user_id': _uid, ...p.toJson()});

  /// The list's household settings, or null if nobody has set them yet.
  Future<KitchenSettings?> fetchKitchenSettings(String listId) async {
    final row = await _db.from('kitchen_settings').select().eq('list_id', listId).maybeSingle();
    return row == null ? null : KitchenSettings.fromJson(row);
  }

  Future<void> saveKitchenSettings(String listId, KitchenSettings s) =>
      _db.from('kitchen_settings').upsert({'list_id': listId, 'updated_by': _uid, ...s.toJson()});

  // ----------------------------------------------------------- meal memory

  Stream<List<MealEvent>> watchMealEvents(String listId) => liveRows(
    _db,
    table: 'meal_events',
    column: 'list_id',
    value: listId,
    orderBy: 'created_at',
    ascending: false,
  ).map((rows) => rows.map(MealEvent.fromJson).toList());

  Future<void> logEvent(String listId, MealEventKind kind, String mealName, {String? recipeId, String? detail}) =>
      _db.from('meal_events').insert({
        'list_id': listId,
        'recipe_id': recipeId,
        'meal_name': mealName,
        'kind': kind.name,
        'detail': detail,
        'user_id': _uid,
      });

  /// 👍 (1) or 👎 (-1). Replaces the user's earlier rating of this meal, and
  /// counts as having cooked it (once: changing your mind the same week
  /// doesn't log a second cook).
  Future<void> rate(String listId, String recipeId, String mealName, int rating) async {
    await _db.from('meal_events').delete().eq('recipe_id', recipeId).eq('user_id', _uid!).eq('kind', 'rated');
    await _db
        .from('meal_events')
        .delete()
        .eq('recipe_id', recipeId)
        .eq('user_id', _uid!)
        .eq('kind', 'cooked')
        .gte('created_at', DateTime.now().toUtc().subtract(const Duration(days: 3)).toIso8601String());
    await _db.from('meal_events').insert([
      {'list_id': listId, 'recipe_id': recipeId, 'meal_name': mealName, 'kind': 'cooked', 'user_id': _uid},
      {
        'list_id': listId,
        'recipe_id': recipeId,
        'meal_name': mealName,
        'kind': 'rated',
        'rating': rating,
        'user_id': _uid,
      },
    ]);
  }

  /// Saves an idea as a normal meal on the list, remembers that it was kept,
  /// and only now asks for its photo (so swapping ideas costs no images).
  Future<String> keepMeal(String listId, MealIdea idea, {String? detail}) async {
    final id = await _repo.saveRecipe(listId: listId, name: idea.name, ingredients: idea.toRecipeIngredients());
    await logEvent(listId, MealEventKind.kept, idea.name, recipeId: id, detail: detail);
    unawaited(_repo.generateImage(id).catchError((_) {}));
    return id;
  }

  // -------------------------------------------------------------------- AI

  Future<MealPlan> _plan(Map<String, dynamic> body) async {
    final res = await _db.functions.invoke('plan-meals', body: body);
    return MealPlan.fromJson(res.data as Map<String, dynamic>);
  }

  Future<MealPlan> planWeek(String listId) => _plan({'list_id': listId, 'mode': 'week'});

  /// A different idea for `week[index]` (the plan's only meal), avoiding
  /// [avoid] (earlier swaps), with the week's reuse notes recomputed.
  Future<MealPlan> swap(String listId, List<MealIdea> week, int index, {List<String> avoid = const []}) async {
    final plan = await _plan({
      'list_id': listId,
      'mode': 'swap',
      'week': week.map((m) => m.toJson()).toList(),
      'index': index,
      'avoid': avoid,
    });
    return plan;
  }

  /// `week[index]` reworked: "lighter", "faster", "use the slow cooker"…
  Future<MealPlan> nudge(String listId, List<MealIdea> week, int index, String nudge) async {
    final plan = await _plan({
      'list_id': listId,
      'mode': 'nudge',
      'week': week.map((m) => m.toJson()).toList(),
      'index': index,
      'nudge': nudge,
    });
    return plan;
  }

  /// "Nope!": a replacement for `week[index]` that fixes [reason]. The server
  /// also remembers the reason (and may update the caller's taste profile,
  /// returned as `learned` so it can be undone).
  Future<({MealPlan plan, NopeLearned? learned})> nope(
    String listId,
    List<MealIdea> week,
    int index,
    NopeReason reason, {
    List<String> avoid = const [],
  }) async {
    final res = await _db.functions.invoke(
      'plan-meals',
      body: {
        'list_id': listId,
        'mode': 'nope',
        'week': week.map((m) => m.toJson()).toList(),
        'index': index,
        'reason': reason.toJson(),
        'avoid': avoid,
      },
    );
    final data = res.data as Map<String, dynamic>;
    return (plan: MealPlan.fromJson(data), learned: NopeLearned.fromJson(data['learned']));
  }

  /// Undoes what a "Nope!" saved to the profile.
  Future<void> undoNope(NopeLearned learned) async {
    final p = await fetchTasteProfile();
    if (p == null) return;
    await saveTasteProfile(
      learned.kind == 'ingredient'
          ? p.copyWith(
              dislikes: [
                for (final d in p.dislikes)
                  if (d.toLowerCase() != learned.value) d,
              ],
            )
          : p.copyWith(spice: int.tryParse(learned.value) ?? p.spice),
    );
  }

  /// 2-3 dinners that use up what they [have].
  Future<MealPlan> tonight(String listId, List<String> have) =>
      _plan({'list_id': listId, 'mode': 'tonight', 'have': have});
}

final plannerRepositoryProvider = Provider<PlannerRepository>(
  (ref) => PlannerRepository(ref.watch(supabaseProvider), ref.watch(repositoryProvider)),
);

/// The signed-in user's tastes (null until they've done the profile).
final tasteProfileProvider = FutureProvider<TasteProfile?>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(plannerRepositoryProvider).fetchTasteProfile();
});

/// A list's household settings (null until someone has set them).
final kitchenSettingsProvider = FutureProvider.family<KitchenSettings?, String>(
  (ref, listId) => ref.watch(plannerRepositoryProvider).fetchKitchenSettings(listId),
);

/// A list's meal memory, newest first, live.
final mealEventsProvider = StreamProvider.family<List<MealEvent>, String>(
  (ref, listId) => ref.watch(plannerRepositoryProvider).watchMealEvents(listId),
);
