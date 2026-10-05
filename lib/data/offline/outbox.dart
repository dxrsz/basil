import 'dart:async';
import 'dart:convert';

import 'package:supabase/supabase.dart';

import 'kv_store.dart';

/// What a queued change does to the `items` table.
enum OpKind { insert, update, delete, clear }

/// One queued item mutation. Ops are replayed strictly in [seq] order.
class OutboxOp {
  OutboxOp({
    required this.seq,
    required this.kind,
    required this.listId,
    this.id,
    this.data = const {},
    this.ids = const [],
    this.attempts = 0,
    this.waiting = false,
  });

  final int seq;
  final OpKind kind;
  final String listId;

  /// The item, for insert/update/delete.
  final String? id;

  /// Insert: the full row. Update: the changed columns.
  final Map<String, dynamic> data;

  /// Clear: the items that were checked when the user tapped Clear.
  final List<String> ids;

  /// How many times a send was started. An op that has never been attempted
  /// can't have reached the server, so it's safe to cancel out locally.
  int attempts;

  /// Held up by the connection (queued offline, or a send failed), as
  /// opposed to just being sent. Only these are shown as "not synced yet",
  /// so normal online taps don't flicker a pending marker.
  bool waiting;

  Map<String, dynamic> toJson() => {
    'seq': seq,
    'kind': kind.name,
    'list_id': listId,
    'id': id,
    'data': data,
    'ids': ids,
    'attempts': attempts,
  };

  factory OutboxOp.fromJson(Map<String, dynamic> j) => OutboxOp(
    seq: j['seq'] as int,
    kind: OpKind.values.byName(j['kind'] as String),
    listId: j['list_id'] as String,
    id: j['id'] as String?,
    data: Map<String, dynamic>.from((j['data'] as Map?) ?? const {}),
    ids: ((j['ids'] as List?) ?? const []).cast<String>(),
    attempts: (j['attempts'] as int?) ?? 0,
    waiting: true, // it outlived an app run, so it was certainly held up
  );

  @override
  String toString() => 'OutboxOp#$seq(${kind.name} ${id ?? ids})';
}

/// Connection and sync status, for the banner and pending markers.
class SyncState {
  const SyncState({this.online = true, this.pending = 0, this.justSynced = false});

  final bool online;

  /// Changes held up by the connection, waiting to reach the server.
  final int pending;

  /// True for a moment after coming back online with everything sent.
  final bool justSynced;

  @override
  bool operator ==(Object other) =>
      other is SyncState && other.online == online && other.pending == pending && other.justSynced == justSynced;

  @override
  int get hashCode => Object.hash(online, pending, justSynced);

  @override
  String toString() => 'SyncState(online: $online, pending: $pending, justSynced: $justSynced)';
}

/// The server turned a queued change down (e.g. the list was deleted).
class OutboxRejection {
  const OutboxRejection(this.op, this.error);

  final OutboxOp op;
  final Object error;
}

typedef OpRunner = Future<void> Function(OutboxOp op);

/// Whether [e] means "couldn't reach the server, try again later" rather than
/// "the server said no".
bool isTransientError(Object e) {
  if (e is PostgrestException) {
    final code = e.code ?? '';
    if (code.startsWith('PGRST3')) return true; // JWT expired/invalid: refreshed on reconnect
    // A 3-character code is an HTTP status (a body that wasn't JSON, e.g. from
    // a proxy). Postgres SQLSTATEs are five characters: the server said no.
    final status = code.length == 3 ? int.tryParse(code) : null;
    return status != null && (status >= 500 || status == 408 || status == 429 || status == 401);
  }
  if (e is Error) return false; // a bug, not the network; retrying won't help
  return true; // socket errors, timeouts, http.ClientException…
}

/// A persistent, ordered queue of item mutations.
///
/// Every change is queued first, shown at once via [apply] (an overlay on the
/// server rows), and sent in order. If the network is down the queue is kept
/// (on disk) and replayed when it comes back. Replays are safe to repeat:
/// inserts ignore duplicates, updates and deletes target an id (so editing an
/// item someone else deleted is a no-op, never a resurrection), and clearing
/// only deletes the specific items that were checked, and only if they still
/// are.
class Outbox {
  Outbox({
    required this._store,
    required this.userId,
    required this._run,
    this._probe,
    this.requestTimeout = const Duration(seconds: 10),
    this.retryEvery = const Duration(seconds: 5),
    this.waitForResult = const Duration(seconds: 2),
    this.settleFor = const Duration(seconds: 10),
    this.syncedFor = const Duration(milliseconds: 2500),
    this.maxServerErrorAttempts = 30,
  }) : _key = 'outbox:$userId' {
    final raw = _store.get(_key);
    if (raw != null) {
      try {
        _queue.addAll([
          for (final j in jsonDecode(raw) as List) OutboxOp.fromJson(Map<String, dynamic>.from(j as Map)),
        ]);
      } catch (_) {
        // Unreadable queue: nothing sensible to replay.
      }
    }
    _nextSeq = _queue.fold(0, (m, op) => op.seq > m ? op.seq : m) + 1;
    _state = SyncState(pending: _queue.length);
    if (_queue.isNotEmpty) scheduleMicrotask(flush);
  }

  final String userId;
  final KeyValueStore _store;
  final OpRunner _run;
  final Future<bool> Function()? _probe;
  final String _key;

  /// Give up on a request after this long (and retry later).
  final Duration requestTimeout;

  /// While offline, how often to retry / probe.
  final Duration retryEvery;

  /// How long a mutation call waits for the server before returning anyway.
  final Duration waitForResult;

  /// How long a sent change stays in the overlay waiting for realtime to
  /// echo it back (avoids a flash of the old value).
  final Duration settleFor;

  /// How long "Synced ✓" shows.
  final Duration syncedFor;

  /// Server errors (5xx) are retried, but not forever.
  final int maxServerErrorAttempts;

  final _queue = <OutboxOp>[];
  final _settling = <(OutboxOp, DateTime)>[];
  final _waiters = <int, Completer<void>>{};
  final _awaited = <int>{};
  late int _nextSeq;
  Future<void>? _flushing;
  var _flushAgain = false;
  Timer? _retryTimer;
  Timer? _settleTimer;
  Timer? _syncedTimer;
  var _recovering = false;
  var _online = true;
  var _disposed = false;

  final _changes = StreamController<void>.broadcast(sync: true);
  final _states = StreamController<SyncState>.broadcast();
  final _rejections = StreamController<OutboxRejection>.broadcast();
  late SyncState _state;

  /// Fires whenever the overlay may have changed.
  Stream<void> get changes => _changes.stream;

  Stream<SyncState> get states => _states.stream;
  SyncState get state => _state;

  /// Rejections nobody was waiting on (the caller had already moved on).
  Stream<OutboxRejection> get rejections => _rejections.stream;

  /// Queued ops, oldest first.
  List<OutboxOp> get queued => List.unmodifiable(_queue);

  bool get online => _online;

  // ------------------------------------------------------------- mutations

  /// Adds a new item (or puts back a deleted one). [row] must include `id`
  /// and `list_id`; ids are generated client-side so the item can be edited
  /// or deleted before it ever reaches the server.
  Future<void> insertItem(Map<String, dynamic> row) =>
      _enqueue(OpKind.insert, listId: row['list_id'] as String, id: row['id'] as String, data: row);

  Future<void> updateItem(String listId, String id, Map<String, dynamic> changes) =>
      _enqueue(OpKind.update, listId: listId, id: id, data: changes);

  Future<void> deleteItem(String listId, String id) => _enqueue(OpKind.delete, listId: listId, id: id);

  Future<void> clearChecked(String listId, Iterable<String> ids) =>
      _enqueue(OpKind.clear, listId: listId, ids: ids.toList());

  Future<void> _enqueue(
    OpKind kind, {
    required String listId,
    String? id,
    Map<String, dynamic> data = const {},
    List<String> ids = const [],
  }) async {
    if (_disposed) throw StateError('Outbox disposed');
    final op = OutboxOp(seq: _nextSeq++, kind: kind, listId: listId, id: id, data: data, ids: ids, waiting: !online);
    final cancelled = _cancelOut(op);
    if (!cancelled) _queue.add(op);
    await _persist();
    _changed();
    if (cancelled) return;

    // Offline: it waits in the queue (unsent, so it can still be cancelled
    // out) until the retry timer or the platform says we're back.
    if (!online) return;
    final waiter = _waiters[op.seq] = Completer<void>();
    waiter.future.ignore(); // nobody may be listening by the time it settles
    unawaited(flush());
    _awaited.add(op.seq);
    try {
      await waiter.future.timeout(waitForResult, onTimeout: () {});
    } finally {
      _awaited.remove(op.seq);
    }
  }

  /// Cancels [op] against an unsent opposite: deleting an item whose add
  /// hasn't gone out yet drops both, and so does undoing an unsent delete.
  bool _cancelOut(OutboxOp op) {
    if (op.kind == OpKind.delete) {
      final i = _queue.indexWhere((o) => o.kind == OpKind.insert && o.id == op.id && o.attempts == 0);
      if (i < 0) return false;
      // Everything after an unsent op is unsent too (the queue is FIFO).
      final from = _queue[i].seq;
      _queue.removeWhere((o) => o.id == op.id && o.attempts == 0 && o.seq >= from);
      return true;
    }
    if (op.kind == OpKind.insert) {
      final i = _queue.lastIndexWhere((o) => o.kind == OpKind.delete && o.id == op.id && o.attempts == 0);
      if (i < 0) return false;
      _queue.removeAt(i);
      return true;
    }
    return false;
  }

  // --------------------------------------------------------------- overlay

  /// [serverRows] (one list's items) with every unsent or just-sent change
  /// for that list applied on top.
  List<Map<String, dynamic>> apply(String listId, List<Map<String, dynamic>> serverRows) {
    final server = {for (final r in serverRows) r['id'] as String: r};
    _settling.removeWhere((s) => s.$1.listId == listId && _reflected(s.$1, server));

    final rows = {for (final r in serverRows) r['id'] as String: r};
    for (final op in [for (final s in _settling) s.$1, ..._queue]) {
      if (op.listId != listId) continue;
      switch (op.kind) {
        case OpKind.insert:
          rows.putIfAbsent(
            op.id!,
            () => {
              'quantity': null,
              'category': 'Other',
              'checked': false,
              'recipe_id': null,
              'created_at': DateTime.now().toUtc().toIso8601String(),
              ...op.data,
              'checked_by': op.data['checked'] == true ? userId : null,
            },
          );
        case OpKind.update:
          final row = rows[op.id];
          if (row == null) break; // deleted (here or elsewhere): stays deleted
          rows[op.id!] = {
            ...row,
            ...op.data,
            if (op.data.containsKey('checked') && op.data['checked'] != row['checked'])
              'checked_by': op.data['checked'] == true ? userId : null,
          };
        case OpKind.delete:
          rows.remove(op.id);
        case OpKind.clear:
          for (final id in op.ids) {
            if (rows[id]?['checked'] == true) rows.remove(id);
          }
      }
    }
    return rows.values.toList();
  }

  /// Ids of items in [listId] with changes held up by the connection.
  Set<String> pendingIds(String listId) => {
    for (final op in _queue)
      if (op.listId == listId && op.waiting) ...[?op.id, ...op.ids],
  };

  bool _reflected(OutboxOp op, Map<String, Map<String, dynamic>> server) {
    switch (op.kind) {
      case OpKind.insert:
        return server.containsKey(op.id);
      case OpKind.update:
        final row = server[op.id];
        return row == null || op.data.entries.every((e) => row[e.key] == e.value);
      case OpKind.delete:
        return !server.containsKey(op.id);
      case OpKind.clear:
        return op.ids.every((id) => server[id]?['checked'] != true);
    }
  }

  // ------------------------------------------------------------------ sync

  /// Sends queued changes in order. Safe to call any time; concurrent calls
  /// share one run.
  Future<void> flush() {
    final running = _flushing;
    if (running != null) {
      _flushAgain = true; // something may have been queued after it gave up
      return running;
    }
    return _flushing = _flushLoop().whenComplete(() => _flushing = null);
  }

  Future<void> _flushLoop() async {
    do {
      _flushAgain = false;
      await _flush();
    } while (_flushAgain && !_disposed);
  }

  Future<void> _flush() async {
    while (_queue.isNotEmpty && !_disposed) {
      final op = _queue.first;
      op.attempts++;
      await _persist();
      Object? error;
      try {
        await _run(op).timeout(requestTimeout);
      } catch (e) {
        error = e;
      }
      if (_disposed) return;

      if (error == null) {
        _queue.remove(op);
        _settle(op);
        _complete(op);
        _setOnline(true);
      } else if (isTransientError(error) && !(error is PostgrestException && op.attempts >= maxServerErrorAttempts)) {
        // Can't reach the server. Everything stays queued, in order.
        for (final c in _waiters.values) {
          if (!c.isCompleted) c.complete();
        }
        _waiters.clear();
        _setOnline(false);
        _publish();
        return;
      } else {
        _queue.remove(op);
        final waiter = _waiters.remove(op.seq);
        if (_awaited.contains(op.seq) && waiter != null) {
          waiter.completeError(error);
        } else {
          waiter?.complete();
          if (!_rejections.isClosed) _rejections.add(OutboxRejection(op, error));
        }
      }
      await _persist();
      _changed();
    }
    _maybeSynced();
  }

  /// Network came back (or went away), per the platform.
  void setNetworkAvailable(bool available) {
    if (_disposed) return;
    if (!available) {
      _setOnline(false);
      _publish();
    } else {
      _retryNow();
    }
  }

  /// Asks the server whether we're online (e.g. at startup).
  Future<void> checkConnection() => _retryNow();

  Future<void> _retryNow() async {
    if (_disposed) return;
    // Probe first rather than resending: an attempt marks an op as possibly
    // sent, which stops it being cancelled out locally.
    final probe = _probe;
    if (probe != null) {
      bool ok;
      try {
        ok = await probe();
      } catch (_) {
        ok = false;
      }
      if (_disposed) return;
      if (!ok) {
        _setOnline(false);
        return _publish();
      }
    }
    _setOnline(true);
    if (_queue.isNotEmpty) return flush();
    _maybeSynced();
  }

  void _setOnline(bool value) {
    if (value == _online) return;
    _online = value;
    if (!value) {
      for (final op in _queue) {
        op.waiting = true;
      }
      _recovering = true;
      _retryTimer ??= Timer.periodic(retryEvery, (_) => _retryNow());
    } else {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  void _maybeSynced() {
    if (!_recovering || !online || _queue.isNotEmpty) return _publish();
    _recovering = false;
    _syncedTimer?.cancel();
    _publish(justSynced: true);
    _syncedTimer = Timer(syncedFor, () => _publish(justSynced: false));
  }

  void _settle(OutboxOp op) {
    _settling.add((op, DateTime.now()));
    _settleTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final cutoff = DateTime.now().subtract(settleFor);
      final before = _settling.length;
      _settling.removeWhere((s) => s.$2.isBefore(cutoff));
      if (_settling.length != before) _changed();
      if (_settling.isEmpty) {
        _settleTimer?.cancel();
        _settleTimer = null;
      }
    });
  }

  void _complete(OutboxOp op) {
    final c = _waiters.remove(op.seq);
    if (c != null && !c.isCompleted) c.complete();
  }

  void _changed() {
    if (_disposed) return;
    _changes.add(null);
    _publish();
  }

  void _publish({bool? justSynced}) {
    if (_disposed) return;
    final synced = justSynced ?? (_online && _state.justSynced);
    final next = SyncState(online: _online, pending: _queue.where((o) => o.waiting).length, justSynced: synced);
    if (next == _state) return;
    _state = next;
    _states.add(next);
  }

  Future<void> _persist() => _store.set(_key, jsonEncode([for (final op in _queue) op.toJson()]));

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _settleTimer?.cancel();
    _syncedTimer?.cancel();
    for (final c in _waiters.values) {
      if (!c.isCompleted) c.complete();
    }
    _changes.close();
    _states.close();
    _rejections.close();
  }
}

/// Sends an [OutboxOp] to Supabase. Every op is idempotent, so replaying one
/// whose response was lost does no harm.
OpRunner supabaseItemRunner(SupabaseClient db) => (op) async {
  final items = db.from('items');
  switch (op.kind) {
    case OpKind.insert:
      await items.upsert(op.data, onConflict: 'id', ignoreDuplicates: true);
    case OpKind.update:
      await items.update(op.data).eq('id', op.id!);
    case OpKind.delete:
      await items.delete().eq('id', op.id!);
    case OpKind.clear:
      if (op.ids.isEmpty) return;
      // Only what was checked when the user tapped Clear, and only if it
      // still is (someone may have unchecked it because they need more).
      await items.delete().inFilter('id', op.ids).eq('checked', true);
  }
};
