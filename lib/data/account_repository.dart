import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'providers.dart';
import 'repository.dart';

/// Where the privacy policy lives (web/privacy.html, served by Vercel).
final privacyPolicyUrl = Uri.parse('https://lamarsgroceries.app/privacy.html');

/// The signed-in person's own profile row.
class MyProfile {
  const MyProfile({required this.displayName, required this.aiConsent});

  final String displayName;

  /// True / false once they've answered; null if never asked.
  final bool? aiConsent;

  factory MyProfile.fromRow(Map<String, dynamic> row) => MyProfile(
    displayName: (row['display_name'] as String?) ?? '',
    aiConsent: switch (row['ai_consent']) {
      'granted' => true,
      'declined' => false,
      _ => null,
    },
  );
}

/// Account-level things: profile, AI consent, connected sign-ins, export,
/// deletion.
class AccountRepository {
  AccountRepository(this._db, this._repo);

  final SupabaseClient _db;
  final Repository _repo;

  String get _uid => _db.auth.currentUser!.id;

  Future<MyProfile> profile() async =>
      MyProfile.fromRow(await _db.from('profiles').select('display_name, ai_consent').eq('id', _uid).single());

  Future<void> setDisplayName(String name) => _db.from('profiles').update({'display_name': name.trim()}).eq('id', _uid);

  Future<void> setAiConsent(bool granted) => _db
      .from('profiles')
      .update({
        'ai_consent': granted ? 'granted' : 'declined',
        'ai_consent_at': DateTime.now().toUtc().toIso8601String(),
      })
      .eq('id', _uid);

  Future<List<UserIdentity>> identities() => _db.auth.getUserIdentities();

  /// Connects another sign-in method to this account. Apple on iPhone uses
  /// the native sheet; everything else goes through the browser and comes
  /// back via the app's link (the auth stream then reports the new identity).
  Future<void> link(OAuthProvider provider) async {
    if (provider == OAuthProvider.apple && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final apple = await _repo.nativeAppleCredential();
      await _db.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.apple,
        idToken: apple.idToken,
        nonce: apple.rawNonce,
      );
      await _repo.afterNativeApple(apple.credential);
      return;
    }
    await _db.auth.linkIdentity(
      provider,
      redirectTo: kIsWeb ? Uri.base.origin : Config.authRedirect,
      authScreenLaunchMode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
    );
  }

  Future<void> unlink(UserIdentity identity) => _db.auth.unlinkIdentity(identity);

  /// Everything the app holds about them, as pretty-printed JSON.
  Future<String> exportData() async {
    final res = await _db.functions.invoke('export-data');
    return const JsonEncoder.withIndent('  ').convert(res.data);
  }

  /// Deletes the account on the server (shared lists pass to the next
  /// member, solo lists go, Apple sign-in is revoked), then forgets the
  /// session and offline cache on this device.
  Future<void> deleteAccount() async {
    await _db.functions.invoke('delete-account');
    try {
      await _repo.signOut();
    } catch (e) {
      // The server session is already gone; the local sign-out still happened.
      debugPrint('sign out after delete: $e');
    }
  }

  /// Browser Apple sign-ins (web, Android) hand Supabase a refresh token
  /// once, right after sign-in. Keep it server-side so deleting the account
  /// can revoke Sign in with Apple. (Native iPhone sign-in sends its
  /// authorization code instead; see Repository.afterNativeApple.)
  StreamSubscription<AuthState> keepAppleTokens() => _db.auth.onAuthStateChange.listen((s) {
    final token = s.session?.providerRefreshToken;
    if (token == null || (s.event != AuthChangeEvent.signedIn && s.event != AuthChangeEvent.userUpdated)) return;
    if (latestIdentityProvider(s.session!.user.identities ?? const []) != 'apple') return;
    unawaited(
      _db.functions
          .invoke('apple-token', body: {'refresh_token': token, 'client_id': 'com.lamarsgroceries.signin'})
          .catchError((Object e) {
            debugPrint('apple-token: $e');
            return FunctionResponse(status: 0);
          }),
    );
  }, onError: (Object _) {});
}

/// The provider of whichever identity signed in most recently: the one the
/// session's provider token belongs to.
String? latestIdentityProvider(List<UserIdentity> identities) {
  UserIdentity? latest;
  DateTime? latestAt;
  for (final i in identities) {
    final at = DateTime.tryParse(i.lastSignInAt ?? '');
    if (at != null && (latestAt == null || at.isAfter(latestAt))) {
      latest = i;
      latestAt = at;
    }
  }
  return latest?.provider;
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(ref.watch(supabaseProvider), ref.watch(repositoryProvider)),
);

final myProfileProvider = FutureProvider<MyProfile?>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return null;
  return ref.watch(accountRepositoryProvider).profile();
}, retry: (_, _) => null);

/// Connected sign-in methods; refreshes when auth changes (e.g. after linking).
final identitiesProvider = FutureProvider<List<UserIdentity>>((ref) async {
  ref.watch(authStateProvider);
  if (ref.watch(currentUserIdProvider) == null) return const [];
  return ref.watch(accountRepositoryProvider).identities();
}, retry: (_, _) => null);

/// Started from the app root alongside the sharing plumbing.
final appleTokenKeeperProvider = Provider<void>((ref) {
  final sub = ref.watch(accountRepositoryProvider).keepAppleTokens();
  ref.onDispose(sub.cancel);
});
