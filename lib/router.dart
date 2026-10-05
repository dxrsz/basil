import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/join/join_routing.dart';
import 'features/join/join_screen.dart';
import 'features/list/list_screen.dart';
import 'features/lists/lists_screen.dart';
import 'features/notifications/notification_settings_screen.dart';
import 'features/planner/kitchen_profile_screen.dart';
import 'features/planner/planner_screen.dart';
import 'features/planner/tonight_screen.dart';
import 'features/recipe/recipe_detail_screen.dart';
import 'features/recipe/recipe_editor_screen.dart';
import 'features/store/store_mode_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(supabaseProvider).auth;
  final refresh = _StreamListenable(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    refreshListenable: refresh,
    // Signed-out users go to /signin; invite links (/join/CODE) continue after.
    redirect: (context, state) => authRedirect(signedIn: auth.currentSession != null, location: state.uri),
    routes: [
      GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
      GoRoute(
        path: '/join/:code',
        builder: (_, s) => JoinScreen(code: s.pathParameters['code']!),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) => const ListsScreen(),
        routes: [
          GoRoute(path: 'settings/notifications', builder: (_, _) => const NotificationSettingsScreen()),
          GoRoute(
            path: 'lists/:listId',
            builder: (_, s) => ListScreen(
              listId: s.pathParameters['listId']!,
              initialTab: s.uri.queryParameters['tab'] == 'recipes' ? 1 : 0,
            ),
            routes: [
              GoRoute(
                path: 'store',
                builder: (_, s) => StoreModeScreen(listId: s.pathParameters['listId']!),
              ),
              GoRoute(
                path: 'recipes/new',
                builder: (_, s) => RecipeEditorScreen(listId: s.pathParameters['listId']!),
              ),
              GoRoute(
                path: 'recipes/:recipeId',
                builder: (_, s) =>
                    RecipeDetailScreen(listId: s.pathParameters['listId']!, recipeId: s.pathParameters['recipeId']!),
                routes: [
                  GoRoute(
                    path: 'edit',
                    builder: (_, s) => RecipeEditorScreen(
                      listId: s.pathParameters['listId']!,
                      recipeId: s.pathParameters['recipeId']!,
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 'plan',
                builder: (_, s) => PlannerScreen(listId: s.pathParameters['listId']!),
                routes: [
                  GoRoute(
                    path: 'profile',
                    builder: (_, s) => KitchenProfileScreen(listId: s.pathParameters['listId']!),
                  ),
                ],
              ),
              GoRoute(
                path: 'tonight',
                builder: (_, s) => TonightScreen(listId: s.pathParameters['listId']!),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<dynamic> stream) {
    // Auth emits errors when a token refresh fails offline (e.g. a DNS blip at
    // the store); supabase_flutter retries on its own, so don't let them
    // surface as unhandled exceptions.
    _sub = stream.listen((_) => notifyListeners(), onError: (Object _) {});
  }

  late final StreamSubscription<dynamic> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
