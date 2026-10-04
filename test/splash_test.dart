import 'package:basil/features/splash/splash_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('splash shows the dancing cat and wordmark', (tester) async {
    await tester.pumpWidget(const SplashScreen());
    expect(find.bySemanticsLabel('A dancing cat'), findsOneWidget);
    expect(find.text('Basil'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, 'assets/images/dancing_cat.gif');
  });
}
