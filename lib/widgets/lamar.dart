import 'package:flutter/widgets.dart';

/// Lamar, the tuxedo cat (and mascot), dancing.
///
/// The GIF is stored at 1× (one image pixel per art pixel, 39×43) and scaled
/// up by a whole number of *physical* pixels, so every art pixel renders the
/// same size. Fractional nearest-neighbour scaling would reintroduce mixels.
class Lamar extends StatelessWidget {
  const Lamar({super.key, required this.width});

  /// Approximate width in logical pixels; rounded down to a crisp multiple.
  final double width;

  static const _asset = 'assets/images/dancing_cat.gif';
  static const _cells = Size(39, 43);

  @override
  Widget build(BuildContext context) {
    final dpr = View.of(context).devicePixelRatio;
    final physicalPerCell = (width * dpr / _cells.width).floorToDouble().clamp(1.0, double.infinity);
    final logicalPerCell = physicalPerCell / dpr;
    return Image(
      image: const AssetImage(_asset),
      width: _cells.width * logicalPerCell,
      height: _cells.height * logicalPerCell,
      // The box is an exact multiple of the GIF; the default fit (scaleDown)
      // would never enlarge the 39×43 image to fill it.
      fit: BoxFit.fill,
      filterQuality: FilterQuality.none,
      gaplessPlayback: true,
      semanticLabel: 'Lamar the tuxedo cat, dancing',
    );
  }
}
