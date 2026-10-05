import 'package:flutter/material.dart';

import '../../data/import_repository.dart';
import '../../widgets/lamar.dart';

/// Where an import was started, which decides what applying it does.
enum ImportTarget {
  /// Shopping or Meals tab: items go on the list, or a recipe becomes a saved meal.
  shopping,

  /// The meal editor: everything becomes this meal's ingredients.
  editor,
}

/// What the user decided in the review sheet.
class ImportDecision {
  const ImportDecision({required this.asMeal, required this.mealName, required this.items, this.addToList = false});

  /// Save as a meal (name + ingredients) rather than adding items to the list.
  final bool asMeal;
  final String mealName;
  final List<ImportedItem> items;

  /// Meals only: also put the ingredients on the shopping list.
  final bool addToList;
}

/// Shows what Lamar extracted; nothing is written until the user taps the button.
Future<ImportDecision?> showImportReview(BuildContext context, ImportResult result, ImportTarget target) {
  return showModalBottomSheet<ImportDecision>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ImportReviewSheet(result: result, target: target),
  );
}

class _Row {
  _Row(ImportedItem item, {required this.selected})
    : name = TextEditingController(text: item.name),
      qty = TextEditingController(text: item.quantity ?? ''),
      low = item.low;

  final TextEditingController name;
  final TextEditingController qty;
  final bool low;
  bool selected;
  final key = UniqueKey();

  void dispose() {
    name.dispose();
    qty.dispose();
  }
}

class ImportReviewSheet extends StatefulWidget {
  const ImportReviewSheet({super.key, required this.result, required this.target});

  final ImportResult result;
  final ImportTarget target;

  @override
  State<ImportReviewSheet> createState() => _ImportReviewSheetState();
}

class _ImportReviewSheetState extends State<ImportReviewSheet> {
  late final List<_Row> _rows;
  late final _mealName = TextEditingController(text: widget.result.mealName ?? '');
  late bool _asMeal = widget.target == ImportTarget.editor || widget.result.kind == ImportKind.recipe;
  bool _addToList = true;
  final _focusLast = FocusNode();

  bool get _pantry => widget.result.kind == ImportKind.pantry;

  @override
  void initState() {
    super.initState();
    // From the fridge, start with only what looks like it's running out.
    final pickLow = _pantry && widget.target != ImportTarget.editor;
    _rows = [for (final i in widget.result.items) _Row(i, selected: pickLow ? i.low : true)];
    _mealName.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    _mealName.dispose();
    _focusLast.dispose();
    super.dispose();
  }

  List<ImportedItem> get _kept => [
    for (final r in _rows)
      if (r.selected && r.name.text.trim().isNotEmpty)
        ImportedItem(name: r.name.text.trim(), quantity: r.qty.text.trim().isEmpty ? null : r.qty.text.trim()),
  ];

  void _addRow() {
    setState(() => _rows.add(_Row(const ImportedItem(name: ''), selected: true)));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusLast.requestFocus());
  }

  void _remove(_Row r) {
    setState(() => _rows.remove(r));
    r.dispose();
  }

  void _apply() {
    Navigator.pop(
      context,
      ImportDecision(asMeal: _asMeal, mealName: _mealName.text.trim(), items: _kept, addToList: _addToList),
    );
  }

  (String, String) get _heading {
    if (widget.result.items.isEmpty) {
      return switch (widget.result.kind) {
        ImportKind.recipe => (
          'Lamar couldn\'t find a recipe',
          'Try another link, or copy the ingredients and paste them instead.',
        ),
        _ => ('Lamar couldn\'t find anything to add', 'Try a clearer photo, or paste the list as text.'),
      };
    }
    return switch (widget.result.kind) {
      ImportKind.list => ('Lamar read your list', 'Fix anything he got wrong. Nothing is added until you say so.'),
      ImportKind.recipe => ('Lamar found a recipe', 'Check the ingredients. Nothing is saved until you say so.'),
      ImportKind.pantry => (
        'Lamar peeked in the fridge',
        'He ticked what looks like it\'s running low. Pick anything else you need.',
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (title, subtitle) = _heading;
    final kept = _kept;
    final host = widget.result.url == null ? null : Uri.tryParse(widget.result.url!)?.host.replaceFirst('www.', '');
    final empty = widget.result.items.isEmpty && _rows.isEmpty;
    final canApply = kept.isNotEmpty && (!_asMeal || _mealName.text.trim().isNotEmpty);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;

    final String applyLabel;
    if (widget.target == ImportTarget.editor) {
      applyLabel = 'Use ${kept.length} ingredient${kept.length == 1 ? '' : 's'}';
    } else if (_asMeal) {
      applyLabel = 'Save meal';
    } else {
      applyLabel = 'Add ${kept.length} to the list';
    }

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  const Lamar(width: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        if (host != null && host.isNotEmpty)
                          Text(
                            'From $host',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!empty)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  children: [
                    if (widget.target != ImportTarget.editor)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, icon: Icon(Icons.checklist_rounded), label: Text('List items')),
                            ButtonSegment(value: true, icon: Icon(Icons.restaurant_menu), label: Text('A meal')),
                          ],
                          selected: {_asMeal},
                          showSelectedIcon: false,
                          onSelectionChanged: (s) => setState(() => _asMeal = s.first),
                        ),
                      ),
                    if (_asMeal) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                        child: TextField(
                          controller: _mealName,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(labelText: 'Meal name', hintText: 'e.g. Banana bread'),
                        ),
                      ),
                      if (widget.target != ImportTarget.editor)
                        SwitchListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          value: _addToList,
                          onChanged: (v) => setState(() => _addToList = v),
                          title: const Text('Put ingredients on the shopping list'),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: Text('Ingredients', style: theme.textTheme.titleSmall),
                      ),
                    ],
                    for (var i = 0; i < _rows.length; i++)
                      _ItemRow(
                        key: _rows[i].key,
                        row: _rows[i],
                        focusNode: i == _rows.length - 1 ? _focusLast : null,
                        onChanged: () => setState(() {}),
                        onRemove: () => _remove(_rows[i]),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _addRow,
                        icon: const Icon(Icons.add),
                        label: const Text('Add another'),
                      ),
                    ),
                  ],
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: empty
                    ? OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))
                    : FilledButton(onPressed: canApply ? _apply : null, child: Text(applyLabel)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({super.key, required this.row, required this.onChanged, required this.onRemove, this.focusNode});

  final _Row row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const dense = InputDecoration(
      isDense: true,
      filled: false,
      border: UnderlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(vertical: 8),
    );
    return Row(
      children: [
        Checkbox(
          value: row.selected,
          shape: const CircleBorder(),
          onChanged: (v) {
            row.selected = v ?? false;
            onChanged();
          },
        ),
        Expanded(
          flex: 3,
          child: TextField(
            controller: row.name,
            focusNode: focusNode,
            textCapitalization: TextCapitalization.sentences,
            decoration: dense.copyWith(
              hintText: 'Item',
              suffixIcon: row.low
                  ? Tooltip(
                      message: 'Looks like it\'s running low',
                      child: Icon(Icons.hourglass_bottom, size: 16, color: scheme.secondary),
                    )
                  : null,
              suffixIconConstraints: const BoxConstraints(minWidth: 20, minHeight: 20),
            ),
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: TextField(
            controller: row.qty,
            decoration: dense.copyWith(hintText: 'Qty'),
          ),
        ),
        IconButton(
          tooltip: 'Remove',
          visualDensity: VisualDensity.compact,
          onPressed: onRemove,
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    );
  }
}
