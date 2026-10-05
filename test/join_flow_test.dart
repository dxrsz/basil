import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/data/repository.dart';
import 'package:lamars_groceries/features/join/join_routing.dart';
import 'package:lamars_groceries/features/join/join_screen.dart';
import 'package:lamars_groceries/features/join/link_handler.dart';
import 'package:lamars_groceries/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRepo extends Repository {
  _FakeRepo(super.db, this.result);

  final Future<String> Function(String code) result;
  final joined = <String>[];

  @override
  Future<String> joinList(String code) {
    joined.add(code);
    return result(code);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('LinkHandler', () {
    test('cold start: the launch link opens the join flow', () async {
      final went = <String>[];
      final h = LinkHandler(
        go: went.add,
        initialLink: () async => Uri.parse('https://lamarsgroceries.app/join/ABC234'),
        links: const Stream.empty(),
      );
      await h.start();
      expect(went, ['/join/ABC234']);
    });

    test('warm: links opened while running open the join flow', () async {
      final went = <String>[];
      final links = StreamController<Uri>();
      final h = LinkHandler(go: went.add, initialLink: () async => null, links: links.stream);
      await h.start();
      links.add(Uri.parse('lamarsgroceries://join/xyz789'));
      links.add(Uri.parse('lamarsgroceries://login-callback?code=abc')); // OAuth: not ours
      await pumpEventQueue();
      expect(went, ['/join/XYZ789']);
      h.dispose();
      await links.close();
    });

    test('the launch link replayed by the stream is handled once', () async {
      final went = <String>[];
      final link = Uri.parse('https://lamarsgroceries.app/join/ABC234');
      final h = LinkHandler(go: went.add, initialLink: () async => link, links: Stream.value(link));
      await h.start();
      await pumpEventQueue();
      expect(went, ['/join/ABC234']);
    });
  });

  group('join route', () {
    late SupabaseClient db;
    setUp(() => db = SupabaseClient('http://localhost:1', 'test-key'));
    tearDown(() => db.dispose());

    Future<GoRouter> pumpApp(
      WidgetTester tester, {
      required Repository repo,
      required ValueNotifier<bool> signedIn,
      required String initial,
    }) async {
      final router = GoRouter(
        initialLocation: initial,
        refreshListenable: signedIn,
        redirect: (_, s) => authRedirect(signedIn: signedIn.value, location: s.uri),
        routes: [
          GoRoute(
            path: '/signin',
            builder: (_, _) => const Scaffold(body: Text('sign in please')),
          ),
          GoRoute(
            path: '/join/:code',
            builder: (_, s) => JoinScreen(code: s.pathParameters['code']!),
          ),
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('my lists')),
            routes: [
              GoRoute(
                path: 'lists/:id',
                builder: (_, s) => Scaffold(body: Text('list ${s.pathParameters['id']}')),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [supabaseProvider.overrideWithValue(db), repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('signed in: joins and opens the list', (tester) async {
      final repo = _FakeRepo(db, (_) async => 'list-1');
      await pumpApp(tester, repo: repo, signedIn: ValueNotifier(true), initial: '/join/ABC234');
      expect(repo.joined, ['ABC234']);
      expect(find.text('list list-1'), findsOneWidget);
    });

    testWidgets('signed out: sign in first, then join', (tester) async {
      final repo = _FakeRepo(db, (_) async => 'list-2');
      final signedIn = ValueNotifier(false);
      final router = await pumpApp(tester, repo: repo, signedIn: signedIn, initial: '/join/ABC234');
      expect(find.text('sign in please'), findsOneWidget);
      expect(router.state.uri.toString(), '/signin?from=%2Fjoin%2FABC234');
      expect(repo.joined, isEmpty);

      signedIn.value = true; // auth state change refreshes the router
      await tester.pumpAndSettle();
      expect(repo.joined, ['ABC234']);
      expect(find.text('list list-2'), findsOneWidget);
    });

    testWidgets('warm link while running navigates into the join flow', (tester) async {
      final repo = _FakeRepo(db, (_) async => 'list-3');
      final router = await pumpApp(tester, repo: repo, signedIn: ValueNotifier(true), initial: '/');
      expect(find.text('my lists'), findsOneWidget);
      LinkHandler(
        go: router.go,
        initialLink: () async => null,
        links: const Stream.empty(),
      ).handle(Uri.parse('https://lamarsgroceries.app/join/ABC234'));
      await tester.pumpAndSettle();
      expect(find.text('list list-3'), findsOneWidget);
    });

    testWidgets('expired or invalid invite shows a friendly state', (tester) async {
      final repo = _FakeRepo(
        db,
        (_) async =>
            throw const PostgrestException(message: 'That invite code is invalid or has expired', code: 'P0002'),
      );
      await pumpApp(tester, repo: repo, signedIn: ValueNotifier(true), initial: '/join/ZZZ999');
      expect(find.text('That invite didn\'t work'), findsOneWidget);
      await tester.tap(find.text('Go to my lists'));
      await tester.pumpAndSettle();
      expect(find.text('my lists'), findsOneWidget);
    });

    testWidgets('network trouble offers a retry', (tester) async {
      var calls = 0;
      final repo = _FakeRepo(db, (_) async {
        if (calls++ == 0) throw Exception('offline');
        return 'list-4';
      });
      await pumpApp(tester, repo: repo, signedIn: ValueNotifier(true), initial: '/join/ABC234');
      expect(find.text('Couldn\'t join just now'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('list list-4'), findsOneWidget);
    });

    for (final (size, textScale) in [(const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
      testWidgets('join states fit at $size, text ×$textScale', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final never = Completer<String>();
        for (final result in <Future<String> Function(String)>[
          (_) => never.future,
          (_) async => throw const PostgrestException(message: 'expired', code: 'P0002'),
          (_) async => throw Exception('offline'),
        ]) {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                supabaseProvider.overrideWithValue(db),
                repositoryProvider.overrideWithValue(_FakeRepo(db, result)),
              ],
              child: MaterialApp(
                theme: buildTheme(Brightness.light),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: JoinScreen(key: UniqueKey(), code: 'ABC234'),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      });
    }
  });

  test('PendingJoin remembers a code across a reload, once', () async {
    await PendingJoin.remember('ABC234');
    expect(await PendingJoin.take(), 'ABC234');
    expect(await PendingJoin.take(), isNull);
  });
}
