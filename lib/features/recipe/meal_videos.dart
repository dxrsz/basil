import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;
import 'package:url_launcher/url_launcher.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';

/// Videos for a meal, keyed by its name so a rename looks again.
final mealVideosProvider = FutureProvider.family<List<RecipeVideo>, ({String recipeId, String name})>(
  (ref, key) => ref.watch(repositoryProvider).findVideos(key.recipeId),
  // Offline, "not set up" and quota limits won't fix themselves in a second;
  // the section offers Retry instead of Riverpod's automatic retries.
  retry: (_, _) => null,
);

/// "12:03", "1:02:03".
String formatDuration(int seconds) {
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// "950 views", "12K views", "1.2M views".
String formatViews(int views) {
  String short(double v) => v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1).replaceAll('.0', '');
  if (views >= 1000000) return '${short(views / 1000000)}M views';
  if (views >= 1000) return '${short(views / 1000)}K views';
  return '$views view${views == 1 ? '' : 's'}';
}

/// "Watch how to make it": a row of YouTube videos on a meal's page. Hidden
/// entirely while YouTube isn't set up (the function answers 503).
class MealVideos extends ConsumerWidget {
  const MealVideos({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final key = (recipeId: recipe.id, name: recipe.name);
    final videos = ref.watch(mealVideosProvider(key));
    if (videos.error case FunctionException(status: 503)) return const SizedBox.shrink();

    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final error = videos.hasValue ? null : videos.error;
    final Widget body = switch (videos) {
      _ when error != null => Row(
        children: [
          Expanded(
            child: Text(error is OfflineException ? 'Videos need a connection.' : friendlyError(error), style: muted),
          ),
          TextButton(onPressed: () => ref.invalidate(mealVideosProvider(key)), child: const Text('Retry')),
        ],
      ),
      AsyncData(:final value) when value.isEmpty => Text(
        'Lamar couldn\'t find a good video for this one.',
        style: muted,
      ),
      AsyncData(:final value) => SizedBox(
        height: 222,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: value.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) => _VideoCard(video: value[i]),
        ),
      ),
      _ => SizedBox(
        height: 222,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: 3,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, _) => const _VideoSkeleton(),
        ),
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Watch how to make it', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }
}

const _cardWidth = 220.0;

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.video});

  final RecipeVideo video;

  Future<void> _open(BuildContext context) async {
    final ok = await launchUrl(video.url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn\'t open YouTube')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _cardWidth,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: video.thumbnail,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
                      errorWidget: (_, _, _) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.smart_display_outlined),
                      ),
                    ),
                    const Center(child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white70)),
                    if (video.seconds > 0)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                          child: Text(
                            formatDuration(video.seconds),
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              video.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              [if (video.channel.isNotEmpty) video.channel, if (video.views > 0) formatViews(video.views)].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoSkeleton extends StatelessWidget {
  const _VideoSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double w) => Container(
      width: w,
      height: 12,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
    );
    return SizedBox(
      width: _cardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: DecoratedBox(
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(12)),
            ),
          ),
          bar(180),
          bar(120),
        ],
      ),
    );
  }
}
