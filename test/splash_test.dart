import 'package:lamars_groceries/features/splash/splash_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('splash shows the dancing cat and wordmark', (tester) async {
    await tester.pumpWidget(const SplashScreen());
    expect(find.bySemanticsLabel('Lamar the tuxedo cat, dancing'), findsOneWidget);
    expect(find.text('Lamar\'s Groceries'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, 'assets/images/dancing_cat.gif');
  });
}
