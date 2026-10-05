import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/lamar.dart';

/// Matches the native launch background (Android `splash_background`,
/// iOS LaunchScreen.storyboard) so the handoff is seamless.
const splashBackground = tuxCream;

/// One full loop of the dancing-cat GIF (12 frames × 130 ms).
const splashMinDuration = Duration(milliseconds: 1560);

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Shown before MaterialApp exists, so supply the text direction ourselves.
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: splashBackground,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Lamar(width: 176),
              SizedBox(height: 20),
              Text(
                'Lamar\'s Groceries',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: tuxBlack,
                  decoration: TextDecoration.none,
                  letterSpacing: -0.5,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Lamar is checking the pantry…',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B6763),
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
