import 'package:flutter/material.dart';

/// Matches the native launch background (Android `splash_background`,
/// iOS LaunchScreen.storyboard) so the handoff is seamless.
const splashBackground = Color(0xFFFBFAF6);

/// One full loop of the dancing-cat GIF (12 frames × 130 ms).
const splashMinDuration = Duration(milliseconds: 1560);

const _catAsset = 'assets/images/dancing_cat.gif';

/// The GIF is stored at 1× (one image pixel per art pixel) and scaled up here
/// by a whole number of *physical* pixels, so every art pixel renders the same
/// size. Fractional nearest-neighbour scaling would reintroduce mixels.
const _catCells = Size(39, 43);
const _catTargetWidth = 176.0;

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dpr = View.of(context).devicePixelRatio;
    final physicalPerCell = (_catTargetWidth * dpr / _catCells.width).floorToDouble().clamp(1.0, double.infinity);
    final logicalPerCell = physicalPerCell / dpr;

    // Shown before MaterialApp exists, so supply the text direction ourselves.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: splashBackground,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image(
                image: const AssetImage(_catAsset),
                width: _catCells.width * logicalPerCell,
                height: _catCells.height * logicalPerCell,
                // The box is an exact multiple of the GIF; the default fit
                // (scaleDown) would never enlarge the 39×43 image to fill it.
                fit: BoxFit.fill,
                filterQuality: FilterQuality.none,
                gaplessPlayback: true,
                semanticLabel: 'A dancing cat',
              ),
              const SizedBox(height: 20),
              const Text(
                'Basil',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1F2A1F),
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Warming up the kitchen…',
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
      ),
    );
  }
}
