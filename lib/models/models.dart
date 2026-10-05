class ShoppingList {
  const ShoppingList({
    required this.id,
    required this.name,
    required this.emoji,
    required this.ownerId,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String emoji;
  final String ownerId;
  final DateTime createdAt;

  factory ShoppingList.fromJson(Map<String, dynamic> j) => ShoppingList(
    id: j['id'] as String,
    name: j['name'] as String,
    emoji: (j['emoji'] as String?) ?? '🛒',
    ownerId: j['owner_id'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
  );
}

class Item {
  const Item({
    required this.id,
    required this.listId,
    required this.name,
    required this.quantity,
    required this.category,
    required this.checked,
    required this.checkedBy,
    required this.recipeId,
    required this.createdAt,
  });

  final String id;
  final String listId;
  final String name;
  final String? quantity;
  final String category;
  final bool checked;
  final String? checkedBy;
  final String? recipeId;
  final DateTime createdAt;

  factory Item.fromJson(Map<String, dynamic> j) => Item(
    id: j['id'] as String,
    listId: j['list_id'] as String,
    name: j['name'] as String,
    quantity: j['quantity'] as String?,
    category: (j['category'] as String?) ?? 'Other',
    checked: (j['checked'] as bool?) ?? false,
    checkedBy: j['checked_by'] as String?,
    recipeId: j['recipe_id'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  Item copyWith({bool? checked}) => Item(
    id: id,
    listId: listId,
    name: name,
    quantity: quantity,
    category: category,
    checked: checked ?? this.checked,
    checkedBy: checkedBy,
    recipeId: recipeId,
    createdAt: createdAt,
  );
}

enum ImageStatus { idle, generating, ready, failed }

class Recipe {
  const Recipe({
    required this.id,
    required this.listId,
    required this.name,
    required this.imageUrl,
    required this.imageStatus,
    required this.createdAt,
    this.ingredients = const [],
  });

  final String id;
  final String listId;
  final String name;
  final String? imageUrl;
  final ImageStatus imageStatus;
  final DateTime createdAt;
  final List<Ingredient> ingredients;

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
    id: j['id'] as String,
    listId: j['list_id'] as String,
    name: j['name'] as String,
    imageUrl: j['image_url'] as String?,
    imageStatus: ImageStatus.values.asNameMap()[j['image_status']] ?? ImageStatus.idle,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  Recipe withIngredients(List<Ingredient> ingredients) => Recipe(
    id: id,
    listId: listId,
    name: name,
    imageUrl: imageUrl,
    imageStatus: imageStatus,
    createdAt: createdAt,
    ingredients: ingredients,
  );
}

class Ingredient {
  const Ingredient({required this.name, this.quantity, this.position = 0, this.recipeId});

  final String name;
  final String? quantity;
  final int position;
  final String? recipeId;

  factory Ingredient.fromJson(Map<String, dynamic> j) => Ingredient(
    name: j['name'] as String,
    quantity: j['quantity'] as String?,
    position: (j['position'] as int?) ?? 0,
    recipeId: j['recipe_id'] as String?,
  );

  Map<String, dynamic> toJson() => {'name': name, 'quantity': quantity};
}

class Member {
  const Member({required this.userId, required this.role, required this.displayName, required this.avatarUrl});

  final String userId;
  final String role;
  final String displayName;
  final String? avatarUrl;

  bool get isOwner => role == 'owner';

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  factory Member.fromJson(Map<String, dynamic> j) {
    final profile = (j['profiles'] as Map<String, dynamic>?) ?? const {};
    return Member(
      userId: j['user_id'] as String,
      role: j['role'] as String,
      displayName: (profile['display_name'] as String?)?.trim().isNotEmpty == true
          ? profile['display_name'] as String
          : 'Someone',
      avatarUrl: profile['avatar_url'] as String?,
    );
  }
}

enum SuggestionSeverity { missing, optional }

class Suggestion {
  const Suggestion({required this.name, required this.quantity, required this.reason, required this.severity});

  final String name;
  final String? quantity;
  final String reason;
  final SuggestionSeverity severity;

  factory Suggestion.fromJson(Map<String, dynamic> j) => Suggestion(
    name: j['name'] as String,
    quantity: j['quantity'] as String?,
    reason: (j['reason'] as String?) ?? '',
    severity: j['severity'] == 'missing' ? SuggestionSeverity.missing : SuggestionSeverity.optional,
  );
}
