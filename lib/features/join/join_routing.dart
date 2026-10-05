import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'join_link.dart';

/// The router's sign-in gate, with join links surviving sign-in:
/// signed out at `/join/CODE` → `/signin?from=/join/CODE` → (sign in) →
/// back to `/join/CODE`. Only join routes are carried through, so `from`
/// can't be used to bounce people somewhere unexpected.
String? authRedirect({required bool signedIn, required Uri location}) {
  final atSignIn = location.path == '/signin';
  if (!signedIn) {
    if (atSignIn) return null;
    final join = _joinRoute(location.path);
    if (join == null) return '/signin';
    // The web OAuth redirect reloads the page, losing `from`; remember it.
    if (kIsWeb) PendingJoin.remember(join.substring('/join/'.length));
    return Uri(path: '/signin', queryParameters: {'from': join}).toString();
  }
  if (atSignIn) return _joinRoute(location.queryParameters['from'] ?? '') ?? '/';
  return null;
}

String? _joinRoute(String path) => joinRouteFor(Uri(path: path));

/// Remembers a join code across the web OAuth redirect, which reloads the
/// page and loses the in-app location. Expires after an hour so an abandoned
/// sign-in doesn't join a list days later.
class PendingJoin {
  static const _key = 'pending_join';
  static const _ttl = Duration(hours: 1);

  static Future<void> remember(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, '$code|${DateTime.now().millisecondsSinceEpoch}');
    } catch (e) {
      debugPrint('PendingJoin.remember: $e');
    }
  }

  /// Returns and forgets the remembered code, if it's still fresh.
  static Future<String?> take() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;
      await prefs.remove(_key);
      final [code, at] = raw.split('|');
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(int.parse(at)));
      return age < _ttl ? normalizeInviteCode(code) : null;
    } catch (e) {
      debugPrint('PendingJoin.take: $e');
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }
}
