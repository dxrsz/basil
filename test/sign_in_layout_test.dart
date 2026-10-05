import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/features/auth/sign_in_screen.dart';
import 'package:lamars_groceries/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OAuthProvider;

void main() {
  // Regression: the two-line "Lamar's Groceries" title overflowed the
  // sign-in column by 50 px on a Pixel 9 Pro.
  for (final (size, textScale) in [(const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
    testWidgets('sign-in fits without overflow at $size, text ×$textScale', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            enabledProvidersProvider.overrideWith((ref) async => {OAuthProvider.google, OAuthProvider.apple}),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const SignInScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull); // a RenderFlex overflow surfaces here
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
    });
  }
}
