import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router.dart';
import 'join/link_handler.dart';
import 'notifications/push.dart';

/// Starts the app-wide sharing plumbing: invite-link handling and push
/// notifications (tapping one opens its list). Watched from the app root.
final sharingBootstrapProvider = Provider<void>((ref) {
  ref.watch(linkHandlerProvider);
  final router = ref.watch(routerProvider);
  final push = ref.watch(pushServiceProvider);
  push.onOpenList = (listId) => router.go('/lists/$listId');
  unawaited(push.start());
});
