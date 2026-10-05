import 'dart:async';
import 'dart:convert';

import '../live_query.dart';

/// A small persistent string store. Reads are synchronous (implementations
/// load everything up front) so cached rows can be shown on the first frame.
abstract interface class KeyValueStore {
  String? get(String key);
  Iterable<String> get keys;
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// In-memory store: the default until the real one is loaded, and for tests.
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  String? get(String key) => values[key];

  @override
  Iterable<String> get keys => values.keys;

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// Last known query results for one user, persisted so lists, items and meals
/// show up offline. Writes are batched: realtime can deliver bursts of events.
class RowCache implements LiveCache {
  RowCache(this._store, {required String userId, this.writeDelay = const Duration(milliseconds: 400)})
    : _prefix = 'rows:$userId:';

  final KeyValueStore _store;
  final String _prefix;
  final Duration writeDelay;
  final _dirty = <String, List<Map<String, dynamic>>>{};
  Timer? _timer;

  @override
  List<Map<String, dynamic>>? read(String key) {
    final pending = _dirty[key];
    if (pending != null) return [for (final r in pending) Map.of(r)];
    final raw = _store.get('$_prefix$key');
    if (raw == null) return null;
    try {
      return [for (final r in jsonDecode(raw) as List) Map<String, dynamic>.from(r as Map)];
    } catch (_) {
      return null; // a corrupt entry is just a cache miss
    }
  }

  @override
  void write(String key, List<Map<String, dynamic>> rows) {
    _dirty[key] = rows;
    _timer ??= Timer(writeDelay, flush);
  }

  /// Writes batched changes now.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final batch = Map.of(_dirty);
    _dirty.clear();
    for (final e in batch.entries) {
      await _store.set('$_prefix${e.key}', jsonEncode(e.value));
    }
  }

  /// Forgets everything cached for this user (on sign-out).
  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    _dirty.clear();
    for (final k in _store.keys.where((k) => k.startsWith(_prefix)).toList()) {
      await _store.remove(k);
    }
  }

  void dispose() {
    if (_dirty.isNotEmpty) flush();
    _timer?.cancel();
  }
}
