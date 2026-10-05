import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers.dart';
import '../../data/sharing_repository.dart';

/// Push notifications through Firebase Cloud Messaging (Android, and iOS via
/// APNs).
///
/// Firebase is optional: until `google-services.json` /
/// `GoogleService-Info.plist` are added (see README), initialising it fails
/// and everything here quietly does nothing. Web push isn't supported.
/// `--dart-define=DISABLE_PUSH=true` switches it off entirely.
class PushService {
  PushService(this._sharing, this._auth);

  static const _disabled = bool.fromEnvironment('DISABLE_PUSH');

  final SharingRepository _sharing;
  final GoTrueClient _auth;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _available = false;
  String? _registered;

  /// Called with a list id when the user taps a notification.
  void Function(String listId)? onOpenList;

  bool get available => _available;

  /// Initialises Firebase if it's configured. Safe to call more than once.
  Future<void> start() async {
    if (_available || _disabled || kIsWeb) return;
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('Push notifications off (Firebase not configured): $e');
      return;
    }
    _available = true;
    final fm = FirebaseMessaging.instance;

    // On iOS, show banners even when the app is open (Android shows nothing
    // in the foreground; the list updates live anyway).
    unawaited(fm.setForegroundNotificationPresentationOptions(alert: true, badge: false, sound: true));

    _subs
      ..add(fm.onTokenRefresh.listen((t) => _register(token: t)))
      ..add(FirebaseMessaging.onMessageOpenedApp.listen(_opened))
      ..add(
        _auth.onAuthStateChange.listen((s) {
          if (s.session != null) unawaited(_registerIfAllowed());
        }),
      );

    final initial = await fm.getInitialMessage();
    if (initial != null) _opened(initial);
    await _registerIfAllowed();
  }

  void _opened(RemoteMessage m) {
    final listId = m.data['list_id'];
    if (listId is String && listId.isNotEmpty) onOpenList?.call(listId);
  }

  /// Asks for permission the first time it's useful (after joining or sharing
  /// a list), then registers this device. Never asks again once answered.
  Future<void> requestPermissionIfNeeded() async {
    if (!_available) return;
    try {
      final fm = FirebaseMessaging.instance;
      var settings = await fm.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
        settings = await fm.requestPermission();
      }
      if (_allowed(settings.authorizationStatus)) await _register();
    } catch (e) {
      debugPrint('Push permission failed: $e');
    }
  }

  bool _allowed(AuthorizationStatus s) => s == AuthorizationStatus.authorized || s == AuthorizationStatus.provisional;

  Future<void> _registerIfAllowed() async {
    if (!_available || _auth.currentSession == null) return;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      if (_allowed(settings.authorizationStatus)) await _register();
    } catch (e) {
      debugPrint('Push registration skipped: $e');
    }
  }

  Future<void> _register({String? token}) async {
    if (_auth.currentSession == null) return;
    try {
      final t = token ?? await FirebaseMessaging.instance.getToken();
      if (t == null) return;
      await _sharing.registerDeviceToken(t, defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
      _registered = t;
    } catch (e) {
      debugPrint('Push token registration failed: $e');
    }
  }

  /// Call before signing out: stops this device getting the old account's
  /// notifications. Best effort, never blocks sign-out for long.
  Future<void> unregister() async {
    if (!_available) return;
    try {
      final t = _registered ?? await FirebaseMessaging.instance.getToken();
      if (t != null) await _sharing.deleteDeviceToken(t);
      await FirebaseMessaging.instance.deleteToken();
      _registered = null;
    } catch (e) {
      debugPrint('Push unregister failed: $e');
    }
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final push = PushService(ref.watch(sharingRepositoryProvider), ref.watch(supabaseProvider).auth);
  ref.onDispose(push.dispose);
  return push;
});

/// Signs out after unregistering this device from push.
Future<void> signOutAndUnregister(WidgetRef ref) async {
  await ref.read(pushServiceProvider).unregister().timeout(const Duration(seconds: 3), onTimeout: () {});
  await ref.read(repositoryProvider).signOut();
}
