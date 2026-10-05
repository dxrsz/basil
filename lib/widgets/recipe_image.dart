import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';

/// The AI-generated photo of a meal, with friendly states while it's being
/// generated or if generation failed.
class RecipeImage extends StatelessWidget {
  const RecipeImage({super.key, required this.recipe, this.onRetry, this.compact = false});

  final Recipe recipe;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final url = recipe.imageUrl;
    final generating = recipe.imageStatus == ImageStatus.generating;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (url != null)
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 400),
            placeholder: (_, _) => const _Placeholder(),
            errorWidget: (_, _, _) => const _Placeholder(),
          )
        else
          const _Placeholder(),
        if (generating) _Generating(compact: compact),
        if (recipe.imageStatus == ImageStatus.failed && url == null)
          Center(
            child: TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(compact ? 'Retry' : 'Couldn\'t make a photo. Retry'),
            ),
          ),
      ],
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: const Center(child: Text('🍽️', style: TextStyle(fontSize: 40))),
    );
  }
}

class _Generating extends StatefulWidget {
  const _Generating({required this.compact});

  final bool compact;

  @override
  State<_Generating> createState() => _GeneratingState();
}

class _GeneratingState extends State<_Generating> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.5 + 3 * t, -0.3),
              end: Alignment(-0.5 + 3 * t, 0.3),
              colors: [
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: 0.35),
                Colors.white.withValues(alpha: 0.0),
              ],
            ),
          ),
          child: child,
        );
      },
      child: Align(
        alignment: widget.compact ? Alignment.bottomLeft : Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    widget.compact ? 'Plating…' : 'Plating it up…',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
