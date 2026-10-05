import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import '../util/categories.dart';
import '../util/item_merge.dart';
import 'providers.dart';

/// What Lamar thinks an imported photo/link/text is.
enum ImportKind { list, recipe, pantry }

class ImportedItem {
  const ImportedItem({required this.name, this.quantity, this.low = false});

  final String name;
  final String? quantity;

  /// Fridge/pantry photos: looks nearly empty, so probably worth buying.
  final bool low;

  factory ImportedItem.fromJson(Map<String, dynamic> j) =>
      ImportedItem(name: j['name'] as String, quantity: j['quantity'] as String?, low: (j['low'] as bool?) ?? false);
}

class ImportResult {
  const ImportResult({required this.kind, required this.items, this.mealName, this.url});

  final ImportKind kind;
  final String? mealName;
  final List<ImportedItem> items;

  /// For links: the page it ended up reading (after redirects).
  final String? url;

  factory ImportResult.fromJson(Map<String, dynamic> j) => ImportResult(
    kind: ImportKind.values.asNameMap()[j['kind']] ?? ImportKind.list,
    mealName: j['meal_name'] as String?,
    items: ((j['items'] as List?) ?? const []).cast<Map<String, dynamic>>().map(ImportedItem.fromJson).toList(),
    url: j['url'] as String?,
  );
}

/// A pasted string that is just a link (possibly with a little text around it).
String? linkIn(String text) {
  final t = text.trim();
  final m = RegExp(r'(https?://|www\.)[^\s<>"]+', caseSensitive: false).firstMatch(t);
  if (m == null) return null;
  // A link inside a long paste (e.g. a whole recipe with a source URL) is text.
  if (t.length - m.group(0)!.length > 120) return null;
  final link = m.group(0)!;
  return link.toLowerCase().startsWith('www.') ? 'https://$link' : link;
}

/// Snap or paste to add: calls the import-items edge function and writes
/// the items the user kept. Separate from Repository to keep that file lean.
class ImportRepository {
  ImportRepository(this._db);

  final SupabaseClient _db;

  Future<ImportResult> _invoke(Map<String, dynamic> body) async {
    final res = await _db.functions.invoke('import-items', body: body);
    return ImportResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// [jpeg] should already be downscaled (see image_picker's maxWidth etc).
  Future<ImportResult> fromImage(Uint8List jpeg, {ImportKind? hint}) =>
      _invoke({'mode': 'image', 'image': base64Encode(jpeg), 'hint': ?hint?.name});

  Future<ImportResult> fromUrl(String url) => _invoke({'mode': 'url', 'url': url});

  Future<ImportResult> fromText(String text, {ImportKind? hint}) =>
      _invoke({'mode': 'text', 'text': text, 'hint': ?hint?.name});

  /// Adds items to the list, skipping any already on it (unchecked, same name).
  /// Returns how many were added.
  Future<int> addItems(String listId, List<ImportedItem> items, {Iterable<Item> existing = const []}) async {
    final have = {
      for (final i in existing)
        if (!i.checked) normalizeItemName(i.name),
    };
    final rows = <Map<String, dynamic>>[];
    for (final i in items) {
      final name = i.name.trim();
      if (name.isEmpty || !have.add(normalizeItemName(name))) continue;
      final qty = i.quantity?.trim();
      rows.add({
        'list_id': listId,
        'name': name,
        'quantity': (qty == null || qty.isEmpty) ? null : qty,
        'category': categorize(name),
      });
    }
    if (rows.isNotEmpty) await _db.from('items').insert(rows);
    return rows.length;
  }
}

final importRepositoryProvider = Provider<ImportRepository>((ref) => ImportRepository(ref.watch(supabaseProvider)));
