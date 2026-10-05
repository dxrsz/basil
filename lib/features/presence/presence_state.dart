// Pure presence state (no Flutter imports, so tools can use it too).

/// Someone else with the list open right now.
class PresentUser {
  const PresentUser({required this.userId, required this.shopping});

  final String userId;
  final bool shopping;

  @override
  bool operator ==(Object other) => other is PresentUser && other.userId == userId && other.shopping == shopping;

  @override
  int get hashCode => Object.hash(userId, shopping);

  @override
  String toString() => 'PresentUser($userId, shopping: $shopping)';
}

class ListPresence {
  const ListPresence([this.others = const []]);

  /// Other people with the list open (never you), shoppers first.
  final List<PresentUser> others;

  List<PresentUser> get shoppers => [
    for (final p in others)
      if (p.shopping) p,
  ];
}

/// Folds raw presence payloads (one per device/tab) into one entry per person,
/// excluding [me]. Someone is shopping if any of their devices says so.
/// Malformed payloads are ignored.
List<PresentUser> parsePresence(Iterable<Map<String, dynamic>> payloads, {String? me}) {
  final shopping = <String, bool>{};
  for (final p in payloads) {
    final id = p['user_id'];
    if (id is! String || id.isEmpty || id == me) continue;
    shopping[id] = (shopping[id] ?? false) || p['shopping'] == true;
  }
  final users = [for (final e in shopping.entries) PresentUser(userId: e.key, shopping: e.value)];
  // Shoppers first; otherwise keep a stable order so avatars don't jump.
  users.sort((a, b) => a.shopping == b.shopping ? a.userId.compareTo(b.userId) : (a.shopping ? -1 : 1));
  return users;
}

String presenceTopic(String listId) => 'presence:list:$listId';
