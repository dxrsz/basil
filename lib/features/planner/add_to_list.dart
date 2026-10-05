import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../pantry/add_meal_flow.dart';
import 'planner_models.dart';

/// The one place the planner puts a meal's ingredients on the shopping list
/// (kept meals, "make again"), via the shared "Got this already?" flow.
/// Returns how many items were added, or null if they cancelled.
Future<int?> putMealOnList(BuildContext context, WidgetRef ref, Recipe recipe) =>
    showAddMealToListFlow(context, ref, recipe);

/// A just-kept idea as the saved meal it became, for [putMealOnList] before
/// the meal has arrived through realtime.
Recipe keptRecipe(String listId, String recipeId, MealIdea idea) => Recipe(
  id: recipeId,
  listId: listId,
  name: idea.name,
  imageUrl: null,
  imageStatus: ImageStatus.idle,
  createdAt: DateTime.now(),
  ingredients: [
    for (final i in idea.toRecipeIngredients())
      Ingredient(name: i.name, quantity: i.quantity, position: i.position, recipeId: recipeId),
  ],
);
