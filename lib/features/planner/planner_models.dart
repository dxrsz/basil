import '../../models/models.dart';

// ------------------------------------------------------------- catalogues

/// (key, label, emoji). Keys are stored in the database and understood by the
/// plan-meals edge function; labels are only for display.
typedef Choice = ({String key, String label, String emoji});

const dietChoices = <Choice>[
  (key: 'vegetarian', label: 'Vegetarian', emoji: '🥕'),
  (key: 'vegan', label: 'Vegan', emoji: '🌱'),
  (key: 'pescatarian', label: 'Pescatarian', emoji: '🐟'),
  (key: 'gluten_free', label: 'Gluten-free', emoji: '🌾'),
  (key: 'dairy_free', label: 'Dairy-free', emoji: '🥛'),
  (key: 'nut_allergy', label: 'Nut allergy', emoji: '🥜'),
  (key: 'shellfish_allergy', label: 'Shellfish allergy', emoji: '🦐'),
  (key: 'halal', label: 'Halal', emoji: '☪️'),
  (key: 'kosher', label: 'Kosher', emoji: '✡️'),
];

const applianceChoices = <Choice>[
  (key: 'oven', label: 'Oven / sheet pan', emoji: '♨️'),
  (key: 'air_fryer', label: 'Air fryer', emoji: '🌪️'),
  (key: 'slow_cooker', label: 'Slow cooker', emoji: '🐢'),
  (key: 'pressure_cooker', label: 'Instant Pot', emoji: '⏱️'),
  (key: 'rice_cooker', label: 'Rice cooker', emoji: '🍚'),
  (key: 'grill', label: 'Grill', emoji: '🔥'),
  (key: 'wok', label: 'Wok', emoji: '🥢'),
  (key: 'dutch_oven', label: 'Dutch oven', emoji: '🍲'),
  (key: 'blender', label: 'Blender', emoji: '🥤'),
  (key: 'stand_mixer', label: 'Stand mixer', emoji: '🎂'),
];

const cuisineChoices = <Choice>[
  (key: 'Mexican', label: 'Mexican', emoji: '🌮'),
  (key: 'Italian', label: 'Italian', emoji: '🍝'),
  (key: 'Chinese', label: 'Chinese', emoji: '🥡'),
  (key: 'Japanese', label: 'Japanese', emoji: '🍣'),
  (key: 'Korean', label: 'Korean', emoji: '🥘'),
  (key: 'Thai', label: 'Thai', emoji: '🍜'),
  (key: 'Vietnamese', label: 'Vietnamese', emoji: '🥖'),
  (key: 'Indian', label: 'Indian', emoji: '🍛'),
  (key: 'Mediterranean', label: 'Mediterranean', emoji: '🫒'),
  (key: 'Middle Eastern', label: 'Middle Eastern', emoji: '🧆'),
  (key: 'American', label: 'American', emoji: '🍔'),
  (key: 'French', label: 'French', emoji: '🥐'),
];

const spiceLabels = ['No heat', 'Mild', 'Medium', 'Bring it on'];

String applianceLabel(String key) =>
    applianceChoices.firstWhere((c) => c.key == key, orElse: () => (key: key, label: key, emoji: '')).label;

// ----------------------------------------------------------------- profile

/// The personal half of the kitchen profile: belongs to the signed-in user.
class TasteProfile {
  const TasteProfile({
    this.diets = const {},
    this.dislikes = const [],
    this.cuisines = const {},
    this.spice = 1,
    this.adventurous = 50,
  });

  final Set<String> diets;
  final List<String> dislikes;
  final Set<String> cuisines;
  final int spice; // 0..3
  final int adventurous; // 0 = comfort food .. 100 = surprise me

  factory TasteProfile.fromJson(Map<String, dynamic> j) => TasteProfile(
    diets: {...(j['diets'] as List? ?? const []).cast<String>()},
    dislikes: [...(j['dislikes'] as List? ?? const []).cast<String>()],
    cuisines: {...(j['cuisines'] as List? ?? const []).cast<String>()},
    spice: (j['spice'] as int?) ?? 1,
    adventurous: (j['adventurous'] as int?) ?? 50,
  );

  Map<String, dynamic> toJson() => {
    'diets': diets.toList(),
    'dislikes': dislikes,
    'cuisines': cuisines.toList(),
    'spice': spice,
    'adventurous': adventurous,
  };

  TasteProfile copyWith({
    Set<String>? diets,
    List<String>? dislikes,
    Set<String>? cuisines,
    int? spice,
    int? adventurous,
  }) => TasteProfile(
    diets: diets ?? this.diets,
    dislikes: dislikes ?? this.dislikes,
    cuisines: cuisines ?? this.cuisines,
    spice: spice ?? this.spice,
    adventurous: adventurous ?? this.adventurous,
  );
}

/// The household half of the kitchen profile: belongs to the shared list.
class KitchenSettings {
  const KitchenSettings({
    this.householdSize = 2,
    this.dinnersPerWeek = 5,
    this.timeBudget = 30,
    this.leftovers = true,
    this.batchCook = false,
    this.appliances = const {'oven'},
    this.wantMore = const {},
  });

  final int householdSize;
  final int dinnersPerWeek;
  final int timeBudget; // 15 | 30 | 45 (45 = "45+")
  final bool leftovers;
  final bool batchCook;
  final Set<String> appliances;
  final Set<String> wantMore;

  factory KitchenSettings.fromJson(Map<String, dynamic> j) => KitchenSettings(
    householdSize: (j['household_size'] as int?) ?? 2,
    dinnersPerWeek: (j['dinners_per_week'] as int?) ?? 5,
    timeBudget: (j['time_budget'] as int?) ?? 30,
    leftovers: (j['leftovers'] as bool?) ?? true,
    batchCook: (j['batch_cook'] as bool?) ?? false,
    appliances: {...(j['appliances'] as List? ?? const []).cast<String>()},
    wantMore: {...(j['want_more'] as List? ?? const []).cast<String>()},
  );

  Map<String, dynamic> toJson() => {
    'household_size': householdSize,
    'dinners_per_week': dinnersPerWeek,
    'time_budget': timeBudget,
    'leftovers': leftovers,
    'batch_cook': batchCook,
    'appliances': appliances.toList(),
    // Only appliances they actually have can be ones they want to use more.
    'want_more': wantMore.intersection(appliances).toList(),
  };

  KitchenSettings copyWith({
    int? householdSize,
    int? dinnersPerWeek,
    int? timeBudget,
    bool? leftovers,
    bool? batchCook,
    Set<String>? appliances,
    Set<String>? wantMore,
  }) => KitchenSettings(
    householdSize: householdSize ?? this.householdSize,
    dinnersPerWeek: dinnersPerWeek ?? this.dinnersPerWeek,
    timeBudget: timeBudget ?? this.timeBudget,
    leftovers: leftovers ?? this.leftovers,
    batchCook: batchCook ?? this.batchCook,
    appliances: appliances ?? this.appliances,
    wantMore: wantMore ?? this.wantMore,
  );
}

// ------------------------------------------------------------- meal ideas

class IdeaIngredient {
  const IdeaIngredient({required this.name, this.quantity, this.perishable = false});

  final String name;
  final String? quantity;
  final bool perishable;

  factory IdeaIngredient.fromJson(Map<String, dynamic> j) => IdeaIngredient(
    name: j['name'] as String,
    quantity: j['quantity'] as String?,
    perishable: (j['perishable'] as bool?) ?? false,
  );

  Map<String, dynamic> toJson() => {'name': name, 'quantity': quantity, 'perishable': perishable};
}

/// A meal Lamar proposed: not saved anywhere until someone keeps it.
class MealIdea {
  const MealIdea({
    required this.name,
    this.pitch = '',
    this.minutes = 30,
    this.effort = 'easy',
    this.appliance,
    this.ingredients = const [],
    this.reuseNote,
    this.day,
  });

  final String name;
  final String pitch;
  final int minutes;
  final String effort; // easy | medium | project
  final String? appliance;
  final List<IdeaIngredient> ingredients;
  final String? reuseNote;
  final String? day;

  factory MealIdea.fromJson(Map<String, dynamic> j) => MealIdea(
    name: j['name'] as String,
    pitch: (j['pitch'] as String?) ?? '',
    minutes: (j['minutes'] as num?)?.toInt() ?? 30,
    effort: (j['effort'] as String?) ?? 'easy',
    appliance: j['appliance'] as String?,
    ingredients: [
      for (final i in (j['ingredients'] as List? ?? const [])) IdeaIngredient.fromJson(i as Map<String, dynamic>),
    ],
    reuseNote: j['reuse_note'] as String?,
    day: j['day'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'pitch': pitch,
    'minutes': minutes,
    'effort': effort,
    'appliance': appliance,
    'ingredients': ingredients.map((i) => i.toJson()).toList(),
    'reuse_note': reuseNote,
    'day': day,
  };

  MealIdea withNote(String? note, {String? day}) =>
      MealIdea.fromJson({...toJson(), 'reuse_note': note, 'day': day ?? this.day});

  /// The meal as recipe ingredients, ready for `save_recipe`.
  List<Ingredient> toRecipeIngredients() => [
    for (var i = 0; i < ingredients.length; i++)
      Ingredient(name: ingredients[i].name, quantity: ingredients[i].quantity, position: i),
  ];
}

class MealPlan {
  const MealPlan({required this.summary, required this.meals, this.weekNotes});

  final String summary;
  final List<MealIdea> meals;

  /// After a swap or nudge: every night's reuse note, recomputed for the
  /// changed week (what the other nights share may have changed too).
  final List<String?>? weekNotes;

  factory MealPlan.fromJson(Map<String, dynamic> j) => MealPlan(
    summary: (j['summary'] as String?) ?? '',
    meals: [for (final m in (j['meals'] as List? ?? const [])) MealIdea.fromJson(m as Map<String, dynamic>)],
    weekNotes: (j['week_notes'] as List?)?.cast<String?>(),
  );
}

// ------------------------------------------------------------ meal memory

enum MealEventKind { kept, swapped, nudged, added, cooked, rated }

/// One entry in a list's meal memory.
class MealEvent {
  const MealEvent({
    required this.id,
    required this.listId,
    required this.recipeId,
    required this.mealName,
    required this.kind,
    required this.createdAt,
    this.rating,
    this.detail,
    this.userId,
  });

  final String id;
  final String listId;
  final String? recipeId;
  final String mealName;
  final MealEventKind kind;
  final int? rating; // 1 = 👍, -1 = 👎
  final String? detail;
  final String? userId;
  final DateTime createdAt;

  factory MealEvent.fromJson(Map<String, dynamic> j) => MealEvent(
    id: j['id'] as String,
    listId: j['list_id'] as String,
    recipeId: j['recipe_id'] as String?,
    mealName: j['meal_name'] as String,
    kind: MealEventKind.values.asNameMap()[j['kind']] ?? MealEventKind.added,
    rating: j['rating'] as int?,
    detail: j['detail'] as String?,
    userId: j['user_id'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String),
  );
}

/// When each meal was last on the list or cooked, by recipe id.
Map<String, DateTime> lastMadeByRecipe(Iterable<MealEvent> events) {
  final out = <String, DateTime>{};
  for (final e in events) {
    final id = e.recipeId;
    if (id == null) continue;
    if (e.kind != MealEventKind.added && e.kind != MealEventKind.cooked && e.kind != MealEventKind.rated) continue;
    final prev = out[id];
    if (prev == null || e.createdAt.isAfter(prev)) out[id] = e.createdAt;
  }
  return out;
}

/// The latest rating for a recipe, by anyone in the household (or only by
/// [userId], when given).
int? latestRating(Iterable<MealEvent> events, String recipeId, {String? userId}) {
  MealEvent? best;
  for (final e in events) {
    if (e.kind != MealEventKind.rated || e.recipeId != recipeId) continue;
    if (userId != null && e.userId != userId) continue;
    if (best == null || e.createdAt.isAfter(best.createdAt)) best = e;
  }
  return best?.rating;
}

/// "3 days", "3 weeks", "2 months".
String humanAgo(Duration d) {
  final days = d.inDays;
  if (days < 1) return 'today';
  if (days < 14) return '$days day${days == 1 ? '' : 's'}';
  if (days < 60) return '${days ~/ 7} weeks';
  return '${days ~/ 30} months';
}

/// "Last made today" / "Last made 3 weeks ago".
String lastMadeText(Duration d) => d.inDays < 1 ? 'Last made today' : 'Last made ${humanAgo(d)} ago';

class MakeAgain {
  const MakeAgain(this.recipe, this.since, {required this.liked});

  final Recipe recipe;
  final Duration since;
  final bool liked;

  String get message => 'You haven\'t made ${recipe.name} in ${humanAgo(since)}. Make again?';
}

/// Meals they've made before but not for a while, best first: ones they
/// liked, then the longest-forgotten. Anything rated 👎 last time, or still on
/// the list, is left out.
List<MakeAgain> makeAgainSuggestions({
  required List<Recipe> recipes,
  required List<MealEvent> events,
  required Set<String> onList,
  required DateTime now,
  Duration minGap = const Duration(days: 14),
}) {
  final lastMade = lastMadeByRecipe(events);
  final out = <MakeAgain>[];
  for (final r in recipes) {
    final last = lastMade[r.id];
    if (last == null || onList.contains(r.id)) continue;
    final since = now.difference(last);
    if (since < minGap) continue;
    final rating = latestRating(events, r.id);
    if (rating == -1) continue;
    out.add(MakeAgain(r, since, liked: rating == 1));
  }
  out.sort((a, b) {
    if (a.liked != b.liked) return a.liked ? -1 : 1;
    return b.since.compareTo(a.since);
  });
  return out;
}

/// Meals that went on the list a few days ago, have been shopped for, and
/// haven't been rated since: worth a "How was it?".
List<Recipe> pendingRatings({
  required List<Recipe> recipes,
  required List<MealEvent> events,
  required Set<String> onList,
  required DateTime now,
  Set<String> dismissed = const {},
}) {
  final out = <(Recipe, DateTime)>[];
  for (final r in recipes) {
    if (dismissed.contains(r.id) || onList.contains(r.id)) continue;
    DateTime? added;
    DateTime? rated;
    for (final e in events) {
      if (e.recipeId != r.id) continue;
      if (e.kind == MealEventKind.added && (added == null || e.createdAt.isAfter(added))) added = e.createdAt;
      if (e.kind == MealEventKind.rated && (rated == null || e.createdAt.isAfter(rated))) rated = e.createdAt;
    }
    if (added == null) continue;
    final age = now.difference(added);
    if (age < const Duration(days: 2) || age > const Duration(days: 10)) continue;
    if (rated != null && rated.isAfter(added)) continue;
    out.add((r, added));
  }
  out.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (r, _) in out) r];
}
