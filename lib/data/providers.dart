import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import 'repository.dart';

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

final repositoryProvider = Provider<Repository>((ref) => Repository(ref.watch(supabaseProvider)));

final enabledProvidersProvider = FutureProvider<Set<OAuthProvider>>((ref) => Repository.enabledProviders());

final authStateProvider = StreamProvider<AuthState>((ref) => ref.watch(supabaseProvider).auth.onAuthStateChange);

/// The signed-in user's id; rebuilds dependents when the user changes.
final currentUserIdProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(supabaseProvider).auth.currentUser?.id;
});

final _myListIdsProvider = StreamProvider<List<String>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(repositoryProvider).watchMyListIds();
});

/// Every list the user belongs to, live. Re-subscribes when they join or
/// leave a list (membership changes don't produce events on `lists` itself).
final listsProvider = StreamProvider<List<ShoppingList>>((ref) async* {
  final ids = await ref.watch(_myListIdsProvider.future);
  yield* ref.watch(repositoryProvider).watchLists(ids);
});

final listProvider = Provider.family<ShoppingList?, String>((ref, id) {
  final lists = ref.watch(listsProvider).value ?? const [];
  for (final l in lists) {
    if (l.id == id) return l;
  }
  return null;
});

final itemsProvider = StreamProvider.family<List<Item>, String>(
  (ref, listId) => ref.watch(repositoryProvider).watchItems(listId),
);

final membersProvider = StreamProvider.family<List<Member>, String>(
  (ref, listId) => ref.watch(repositoryProvider).watchMembers(listId),
);

final _ingredientsProvider = StreamProvider.family<List<Ingredient>, String>(
  (ref, listId) => ref.watch(repositoryProvider).watchIngredients(listId),
);

/// Recipes for a list, with their ingredients attached, newest first.
final recipesProvider = Provider.family<AsyncValue<List<Recipe>>, String>((ref, listId) {
  final recipes = ref.watch(_recipeRowsProvider(listId));
  final ingredients = ref.watch(_ingredientsProvider(listId));
  if (recipes.hasError) return AsyncError(recipes.error!, recipes.stackTrace!);
  final rows = recipes.value;
  final ings = ingredients.value;
  if (rows == null || ings == null) return const AsyncLoading();

  final byRecipe = <String, List<Ingredient>>{};
  for (final i in ings) {
    (byRecipe[i.recipeId!] ??= []).add(i);
  }
  return AsyncData([
    for (final r in rows) r.withIngredients((byRecipe[r.id] ?? [])..sort((a, b) => a.position.compareTo(b.position))),
  ]);
});

final _recipeRowsProvider = StreamProvider.family<List<Recipe>, String>(
  (ref, listId) => ref.watch(repositoryProvider).watchRecipes(listId),
);

final recipeProvider = Provider.family<Recipe?, ({String listId, String recipeId})>((ref, key) {
  final recipes = ref.watch(recipesProvider(key.listId)).value ?? const [];
  for (final r in recipes) {
    if (r.id == key.recipeId) return r;
  }
  return null;
});
