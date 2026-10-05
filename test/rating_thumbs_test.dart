import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/features/planner/meal_memory.dart';
import 'package:lamars_groceries/theme.dart';

void main() {
  Future<List<int>> pump(
    WidgetTester tester,
    int? selected, {
    Size size = const Size(412, 915),
    double text = 1,
  }) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)),
          child: child!,
        ),
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: Text('How was Taco bowls with a long name?')),
              RatingThumbs(selected: selected, onRate: taps.add),
            ],
          ),
        ),
      ),
    );
    return taps;
  }

  double opacityOf(WidgetTester tester, String emoji) =>
      tester.widget<Opacity>(find.ancestor(of: find.text(emoji), matching: find.byType(Opacity))).opacity;

  testWidgets('unrated: both thumbs full strength and tappable', (tester) async {
    final taps = await pump(tester, null);
    expect(opacityOf(tester, '👍'), 1);
    expect(opacityOf(tester, '👎'), 1);
    await tester.tap(find.text('👎'));
    expect(taps, [-1]);
  });

  testWidgets('voted: the pick is marked, the other fades but can change the vote', (tester) async {
    final taps = await pump(tester, 1);
    expect(opacityOf(tester, '👍'), 1);
    expect(opacityOf(tester, '👎'), lessThan(0.5));
    expect(find.byTooltip('Your vote'), findsOneWidget);
    await tester.tap(find.text('👍')); // already chosen: no-op
    await tester.tap(find.text('👎'));
    expect(taps, [-1]);
  });

  testWidgets('fits at 360x640 with text x1.3', (tester) async {
    await pump(tester, -1, size: const Size(360, 640), text: 1.3);
    expect(tester.takeException(), isNull);
  });

  test('rating text', () {
    expect(ratingText(1), 'You loved it');
    expect(ratingText(-1), 'Not one for you');
  });
}
