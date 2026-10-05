import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'providers.dart';

/// Push-notification and presence I/O (device tokens, notification settings,
/// list mutes, shopping announcements). Kept apart from [Repository] so the
/// sharing features stay in their own files.
class SharingRepository {
  SharingRepository(this._db);

  final SupabaseClient _db;

  String? get _uid => _db.auth.currentUser?.id;

  Future<void> registerDeviceToken(String token, String platform) =>
      _db.rpc('register_device_token', params: {'p_token': token, 'p_platform': platform});

  Future<void> deleteDeviceToken(String token) => _db.from('device_tokens').delete().eq('token', token);

  /// Tells the list's other members you've started shopping (push). The
  /// server sends at most one per person per list every 30 minutes.
  Future<void> announceShopping(String listId) => _db.rpc('announce_shopping', params: {'p_list_id': listId});

  Future<NotificationSettings> fetchSettings() async {
    final uid = _uid;
    if (uid == null) return const NotificationSettings();
    final row = await _db.from('notification_settings').select().eq('user_id', uid).maybeSingle();
    return row == null ? const NotificationSettings() : NotificationSettings.fromJson(row);
  }

  Future<void> saveSettings(NotificationSettings s) =>
      _db.from('notification_settings').upsert({'user_id': _uid, ...s.toJson()});

  Future<Set<String>> fetchMutedListIds() async {
    final uid = _uid;
    if (uid == null) return const {};
    final rows = await _db.from('list_mutes').select('list_id').eq('user_id', uid);
    return {for (final r in rows) r['list_id'] as String};
  }

  Future<void> setListMuted(String listId, bool muted) => muted
      ? _db.from('list_mutes').upsert({'list_id': listId, 'user_id': _uid})
      : _db.from('list_mutes').delete().eq('list_id', listId).eq('user_id', _uid!);
}

final sharingRepositoryProvider = Provider<SharingRepository>((ref) => SharingRepository(ref.watch(supabaseProvider)));

class NotificationSettings {
  const NotificationSettings({
    this.enabled = true,
    this.shopping = true,
    this.itemsAdded = true,
    this.memberJoined = true,
  });

  factory NotificationSettings.fromJson(Map<String, dynamic> j) => NotificationSettings(
    enabled: j['enabled'] as bool? ?? true,
    shopping: j['shopping'] as bool? ?? true,
    itemsAdded: j['items_added'] as bool? ?? true,
    memberJoined: j['member_joined'] as bool? ?? true,
  );

  final bool enabled;
  final bool shopping;
  final bool itemsAdded;
  final bool memberJoined;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'shopping': shopping,
    'items_added': itemsAdded,
    'member_joined': memberJoined,
  };

  NotificationSettings copyWith({bool? enabled, bool? shopping, bool? itemsAdded, bool? memberJoined}) =>
      NotificationSettings(
        enabled: enabled ?? this.enabled,
        shopping: shopping ?? this.shopping,
        itemsAdded: itemsAdded ?? this.itemsAdded,
        memberJoined: memberJoined ?? this.memberJoined,
      );
}
