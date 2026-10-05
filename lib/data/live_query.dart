import 'dart:async';

import 'package:supabase/supabase.dart';

/// A live, realtime-backed view of the rows in [table] matching one filter.
///
/// Why not `SupabaseClient.from(t).stream()`? It subscribes to every event
/// with the same column filter, but Supabase can't filter DELETE events: a
/// delete's payload only carries the primary key, so `list_id=eq.X` never
/// matches and deletes are silently dropped. Rows deleted by anyone (including
/// you) lingered until the screen was rebuilt.
///
/// Here inserts and updates are subscribed with the filter, deletes without
/// one, and a delete is applied if its primary key is a row we hold. (RLS
/// isn't applied to delete events, so a client can see the ids of rows
/// deleted elsewhere; ids are random UUIDs and reveal nothing else.)
///
/// The full result is re-read whenever the channel (re)subscribes, so
/// anything missed while offline is picked up on reconnect.
Stream<List<Map<String, dynamic>>> liveRows(
  SupabaseClient db, {
  required String table,
  required String column,
  required Object value,
  List<String> primaryKey = const ['id'],
  String? orderBy,
  bool ascending = true,
}) {
  final isList = value is List;
  if (isList && value.isEmpty) return Stream.value(const []);

  final rows = <String, Map<String, dynamic>>{};
  String keyOf(Map<String, dynamic> r) => primaryKey.map((k) => '${r[k]}').join('|');
  bool matches(Map<String, dynamic> r) => isList ? value.contains(r[column]) : r[column] == value;

  late final StreamController<List<Map<String, dynamic>>> out;
  RealtimeChannel? channel;
  var fetching = false;
  final queued = <void Function()>[];

  void emit() {
    if (out.isClosed) return;
    final list = rows.values.toList();
    if (orderBy != null) {
      list.sort((a, b) {
        final c = Comparable.compare(a[orderBy] as Comparable, b[orderBy] as Comparable);
        return ascending ? c : -c;
      });
    }
    out.add(list);
  }

  // Events that arrive while a full re-read is in flight are applied after it,
  // so the (older) snapshot can't overwrite them.
  void apply(void Function() change) {
    if (fetching) {
      queued.add(change);
    } else {
      change();
      emit();
    }
  }

  Future<void> refetch() async {
    fetching = true;
    try {
      var query = db.from(table).select();
      query = isList ? query.inFilter(column, value) : query.eq(column, value);
      final data = await query;
      rows
        ..clear()
        ..addEntries(data.map((r) => MapEntry(keyOf(r), r)));
    } catch (e, st) {
      if (!out.isClosed) out.addError(e, st);
    } finally {
      fetching = false;
      for (final change in queued) {
        change();
      }
      queued.clear();
      emit();
    }
  }

  final filter = PostgresChangeFilter(
    type: isList ? PostgresChangeFilterType.inFilter : PostgresChangeFilterType.eq,
    column: column,
    value: value,
  );

  void upsert(PostgresChangePayload p) => apply(() {
    final r = p.newRecord;
    // An update can move a row out of our filter (e.g. list_id changed).
    matches(r) ? rows[keyOf(r)] = r : rows.remove(keyOf(r));
  });

  out = StreamController<List<Map<String, dynamic>>>(
    onListen: () {
      channel = db
          .channel('live:$table:$column:${value.hashCode}:${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: table,
            filter: filter,
            callback: upsert,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: table,
            filter: filter,
            callback: upsert,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: table,
            callback: (p) => apply(() => rows.remove(keyOf(p.oldRecord))),
          )
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) refetch();
          });
    },
    onCancel: () async {
      final c = channel;
      channel = null;
      if (c != null) await db.removeChannel(c);
      await out.close();
    },
  );
  return out.stream;
}
