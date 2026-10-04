import 'package:flutter/material.dart';

const _emojis = ['🛒', '🏠', '🥗', '🌮', '🍝', '🥘', '🎉', '🏕️', '👶', '🐶', '💪', '🌱'];

/// Bottom sheet for creating or renaming a list.
Future<({String name, String emoji})?> showListFormSheet(
  BuildContext context, {
  String? initialName,
  String? initialEmoji,
}) {
  return showModalBottomSheet<({String name, String emoji})>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ListFormSheet(initialName: initialName, initialEmoji: initialEmoji),
  );
}

class _ListFormSheet extends StatefulWidget {
  const _ListFormSheet({this.initialName, this.initialEmoji});

  final String? initialName;
  final String? initialEmoji;

  @override
  State<_ListFormSheet> createState() => _ListFormSheetState();
}

class _ListFormSheetState extends State<_ListFormSheet> {
  late final _name = TextEditingController(text: widget.initialName);
  late String _emoji = widget.initialEmoji ?? _emojis.first;

  bool get _editing => widget.initialName != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, emoji: _emoji));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_editing ? 'Edit list' : 'New list', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'e.g. Weekly groceries'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _emojis)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _emoji = e),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: e == _emoji ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                      border: Border.all(color: e == _emoji ? scheme.primary : Colors.transparent, width: 2),
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 22)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _submit, child: Text(_editing ? 'Save' : 'Create list')),
        ],
      ),
    );
  }
}
