import 'package:flutter/material.dart';

import 'planner_models.dart';

/// One of Lamar's meal ideas: name, pitch, time, appliance, key ingredients
/// and (the point of planning a week at once) which leftovers it uses up.
class MealIdeaCard extends StatelessWidget {
  const MealIdeaCard({super.key, required this.idea, this.footer, this.badge, this.busy = false});

  final MealIdea idea;
  final Widget? footer;

  /// Shown top-right, e.g. a "Kept" pill.
  final Widget? badge;

  /// Dims the card under a spinner while Lamar rethinks it.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (idea.day != null)
                      Text(
                        idea.day!.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.secondary,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                    Text(idea.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 8), badge!],
            ],
          ),
          if (idea.pitch.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(idea.pitch, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Fact(icon: Icons.schedule, label: '${idea.minutes} min'),
              _Fact(icon: Icons.local_fire_department_outlined, label: _effort(idea.effort)),
              if (idea.appliance != null && idea.appliance!.isNotEmpty)
                _Fact(icon: Icons.kitchen_outlined, label: idea.appliance!),
            ],
          ),
          if (idea.reuseNote != null && idea.reuseNote!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
              child: Text(
                '♻️  ${idea.reuseNote}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onTertiaryContainer),
              ),
            ),
          ],
          if (idea.ingredients.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(idea.ingredients.map((i) => i.name).join(' · '), style: muted),
          ],
          if (footer != null) ...[const SizedBox(height: 8), footer!],
        ],
      ),
    );

    return Card(
      child: Stack(
        children: [
          AnimatedOpacity(opacity: busy ? 0.35 : 1, duration: const Duration(milliseconds: 200), child: content),
          if (busy) const Positioned.fill(child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }

  static String _effort(String effort) => switch (effort) {
    'medium' => 'Some effort',
    'project' => 'A project',
    _ => 'Easy',
  };
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, style: theme.textTheme.labelSmall, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
