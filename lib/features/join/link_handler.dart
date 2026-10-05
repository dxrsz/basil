import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../router.dart';
import 'join_link.dart';
import 'join_routing.dart';

/// Routes incoming join links (App Links, Universal Links and
/// `lamarsgroceries://join/CODE`) to the join flow, both for the link that
/// launched the app (cold start) and links opened while it's running.
///
/// The OAuth callback (`lamarsgroceries://login-callback`) is not a join link
/// and is left to supabase_flutter.
class LinkHandler {
  LinkHandler({required this.go, required this.initialLink, required this.links});

  final void Function(String location) go;

  /// The link that launched the app, if any (cold start).
  final Future<Uri?> Function() initialLink;

  /// Links opened while the app is running (warm).
  final Stream<Uri> links;
  StreamSubscription<Uri>? _sub;
  String? _last;
  DateTime _lastAt = DateTime(0);

  Future<void> start() async {
    // The initial link can arrive both ways (the stream replays it on some
    // platforms), so handle() drops quick duplicates.
    _sub = links.listen(handle, onError: (Object e) => debugPrint('Link stream error: $e'));
    try {
      handle(await initialLink());
    } catch (e) {
      debugPrint('Initial link error: $e');
    }
  }

  /// Navigates to the join flow if [uri] is a join link. Returns whether it was.
  bool handle(Uri? uri) {
    if (uri == null) return false;
    final route = joinRouteFor(uri);
    if (route == null) return false;
    final now = DateTime.now();
    if (route == _last && now.difference(_lastAt) < const Duration(seconds: 3)) return true;
    _last = route;
    _lastAt = now;
    go(route);
    return true;
  }

  void dispose() => _sub?.cancel();
}

/// Starts link handling for the running app. Watched once from the app root.
final linkHandlerProvider = Provider<void>((ref) {
  final router = ref.watch(routerProvider);

  if (kIsWeb) {
    // The browser URL already routes /join/CODE. Only resume a join that was
    // interrupted by signing in (the OAuth redirect lands back on "/").
    ref.listen(authStateProvider, (_, next) async {
      if (next.value?.session == null) return;
      final code = await PendingJoin.take();
      if (code != null && !router.state.uri.path.startsWith('/join/')) router.go('/join/$code');
    }, fireImmediately: true);
    return;
  }

  final appLinks = AppLinks();
  final handler = LinkHandler(go: router.go, initialLink: appLinks.getInitialLink, links: appLinks.uriLinkStream);
  unawaited(handler.start());
  ref.onDispose(handler.dispose);
});
