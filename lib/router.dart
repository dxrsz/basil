import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/list/list_screen.dart';
import 'features/lists/lists_screen.dart';
import 'features/recipe/recipe_detail_screen.dart';
import 'features/recipe/recipe_editor_screen.dart';
import 'features/store/store_mode_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(supabaseProvider).auth;
  final refresh = _StreamListenable(auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = auth.currentSession != null;
      final atSignIn = state.matchedLocation == '/signin';
      if (!signedIn) return atSignIn ? null : '/signin';
      if (atSignIn) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
      GoRoute(
        path: '/',
        builder: (_, _) => const ListsScreen(),
        routes: [
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
            ],
          ),
        ],
      ),
    ],
  );
});

class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<dynamic> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
