import 'package:flutter/material.dart';

import 'planner_models.dart';

/// "Nope!" on a planned meal: Lamar guesses why (meal-specific guesses first,
/// e.g. "Not into tofu", then general ones), or they type it. Pops the chosen
/// [NopeReason].
class NopeSheet extends StatefulWidget {
  const NopeSheet({super.key, required this.idea});

  final MealIdea idea;

  @override
  State<NopeSheet> createState() => _NopeSheetState();
}

class _NopeSheetState extends State<NopeSheet> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _typed() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    Navigator.pop(context, NopeReason(kind: 'other', label: t));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final guesses = widget.idea.nopeGuesses;
    final general = generalNopeReasons.where((g) => !guesses.contains(g));

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nope to ${widget.idea.name}?',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Tell Lamar why. He\'ll swap it and remember for next time.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Lamar's guesses about this meal, highlighted.
                for (final g in guesses)
                  ActionChip(
                    avatar: Icon(Icons.auto_awesome, size: 16, color: scheme.secondary),
                    label: Text(g.label),
                    backgroundColor: scheme.secondaryContainer,
                    side: BorderSide.none,
                    onPressed: () => Navigator.pop(context, g),
                  ),
                for (final g in general) ActionChip(label: Text(g.label), onPressed: () => Navigator.pop(context, g)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: 'Something else? e.g. "we had fish yesterday"',
                suffixIcon: IconButton(tooltip: 'Send', icon: const Icon(Icons.send), onPressed: _typed),
              ),
              onSubmitted: (_) => _typed(),
            ),
          ],
        ),
      ),
    );
  }
}
