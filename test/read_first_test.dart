import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/providers.dart';

final _slow = StreamProvider.family<int, String>((ref, id) async* {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  yield 42;
});

void main() {
  // Regression: ref.read(p.future) on a stream provider nobody listens to
  // never completes in Riverpod 3, which made every meal save wait 8 s.
  testWidgets('readFirst resolves an unlistened stream provider', (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    );
    int? value;
    readFirst(ref, _slow('a')).then((v) => value = v);
    await tester.pump(const Duration(milliseconds: 100));
    expect(value, 42);
  });
}
