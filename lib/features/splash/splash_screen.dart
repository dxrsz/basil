import 'package:flutter/material.dart';

/// Matches the native launch background (Android `splash_background`,
/// iOS LaunchScreen.storyboard) so the handoff is seamless.
const splashBackground = Color(0xFFFBFAF6);

/// One full loop of the dancing-cat GIF (12 frames × 130 ms).
const splashMinDuration = Duration(milliseconds: 1560);

const _catAsset = 'assets/images/dancing_cat.gif';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: splashBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image(
              image: AssetImage(_catAsset),
              width: 168,
              // Keep the pixel art crisp when scaled.
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
              semanticLabel: 'A dancing cat',
            ),
            SizedBox(height: 20),
            Text(
              'Basil',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1F2A1F),
                decoration: TextDecoration.none,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Warming up the kitchen…',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF5E6B5E),
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
