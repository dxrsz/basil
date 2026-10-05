import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/repository.dart';
import 'package:lamars_groceries/features/recipe/meal_videos.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

final _meal = Recipe(
  id: 'r',
  listId: 'l',
  name: 'Salmon power bowl',
  imageUrl: null,
  imageStatus: ImageStatus.idle,
  createdAt: DateTime(2026),
);

RecipeVideo _video(String id, String title) => RecipeVideo(
  id: id,
  title: title,
  channel: 'Lamar\'s Test Kitchen with a long channel name',
  thumbnail: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
  seconds: 723,
  views: 1234567,
);

void main() {
  test('formatting', () {
    expect(formatDuration(723), '12:03');
    expect(formatDuration(3723), '1:02:03');
    expect(formatDuration(59), '0:59');
    expect(formatViews(950), '950 views');
    expect(formatViews(1), '1 view');
    expect(formatViews(12400), '12K views');
    expect(formatViews(1234567), '1.2M views');
    expect(formatViews(2000000), '2M views');
    expect(RecipeVideo.fromJson({'id': 'abc'}).url.toString(), 'https://www.youtube.com/watch?v=abc');
  });

  Future<void> pump(WidgetTester tester, Future<List<RecipeVideo>> Function() load) async {
    tester.view.physicalSize = const Size(360, 640) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [mealVideosProvider.overrideWith((ref, _) => load())],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [MealVideos(recipe: _meal)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows video cards with duration, channel and views (fits 360x640, text x1.3)', (tester) async {
    await pump(
      tester,
      () async => [_video('a', 'The best salmon bowl you will ever make at home'), _video('b', 'Bowls')],
    );
    expect(find.text('Watch how to make it'), findsOneWidget);
    expect(find.text('12:03'), findsWidgets);
    expect(find.textContaining('1.2M views'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden entirely while YouTube is not set up (503)', (tester) async {
    await pump(tester, () async => throw const FunctionException(status: 503));
    expect(find.text('Watch how to make it'), findsNothing);
  });

  testWidgets('says so when nothing was found', (tester) async {
    await pump(tester, () async => const <RecipeVideo>[]);
    expect(find.textContaining('couldn\'t find a good video'), findsOneWidget);
  });

  testWidgets('offline and other errors offer a retry', (tester) async {
    await pump(tester, () async => throw const OfflineException());
    expect(find.text('Videos need a connection.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
