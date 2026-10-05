import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/widgets/deliberate_swipe.dart';

/// A finger dragging in small steps, as a real one does.
Future<void> swipe(WidgetTester tester, Finder target, Offset by, {int steps = 20}) async {
  final g = await tester.startGesture(tester.getCenter(target));
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble(), timeStamp: Duration(milliseconds: 16 * (i + 1)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
}

void main() {
  test('only long, mostly-sideways travel counts', () {
    expect(isDeliberateSwipe(200, 10, 400), isTrue);
    expect(isDeliberateSwipe(-200, 10, 400), isTrue);
    expect(isDeliberateSwipe(100, 0, 400), isFalse, reason: 'short flick');
    expect(isDeliberateSwipe(200, 150, 400), isFalse, reason: 'diagonal scroll');
  });

  Future<List<String>> pumpList(WidgetTester tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ListView(
              children: [
                for (final name in List.generate(30, (i) => 'item $i'))
                  if (!deleted.contains(name))
                    DeliberateSwipe(
                      key: ValueKey(name),
                      dismissKey: ValueKey('d-$name'),
                      onDismissed: () => setState(() => deleted.add(name)),
                      background: Container(color: Colors.red),
                      secondaryBackground: Container(color: Colors.red),
                      child: SizedBox(height: 56, child: Text(name)),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
    return deleted;
  }

  testWidgets('a short fast flick does not delete', (tester) async {
    final deleted = await pumpList(tester);
    // 120 px in 50 ms: well over Dismissible's fling speed, which alone would delete.
    await swipe(tester, find.text('item 2'), const Offset(120, 0), steps: 3);
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(find.text('item 2'), findsOneWidget);
  });

  testWidgets('a diagonal scroll does not delete', (tester) async {
    final deleted = await pumpList(tester);
    await swipe(tester, find.text('item 3'), const Offset(320, -260), steps: 8);
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
  });

  testWidgets('a vertical scroll does not delete', (tester) async {
    final deleted = await pumpList(tester);
    await swipe(tester, find.text('item 1'), const Offset(30, -300));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
  });

  testWidgets('a real swipe either way deletes', (tester) async {
    final deleted = await pumpList(tester);
    await swipe(tester, find.text('item 2'), const Offset(500, 0));
    await tester.pumpAndSettle();
    await swipe(tester, find.text('item 4'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(deleted, ['item 2', 'item 4']);
  });
}
