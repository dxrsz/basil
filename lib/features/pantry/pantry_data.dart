import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../models/models.dart';

/// What a list's household said it already has, live.
final pantryProvider = StreamProvider.family<List<PantryStaple>, String>(
  (ref, listId) => ref.watch(repositoryProvider).watchPantry(listId),
);
