import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../util/categories.dart';
import '../../widgets/empty_state.dart';

/// Create or edit a meal: a name plus the ingredients you associate with it.
///
/// While you type, Basil asks the model what you've probably forgotten and
/// shows each idea as a card you can accept or dismiss. Dismissed ideas are
/// sent back with later requests so they don't reappear.
class RecipeEditorScreen extends ConsumerStatefulWidget {
  const RecipeEditorScreen({super.key, required this.listId, this.recipeId});

  final String listId;
  final String? recipeId;

  @override
  ConsumerState<RecipeEditorScreen> createState() => _RecipeEditorScreenState();
}

class _RecipeEditorScreenState extends ConsumerState<RecipeEditorScreen> {
  static const _reviewDelay = Duration(milliseconds: 1200);

  final _name = TextEditingController();
  final _ingredientInput = TextEditingController();
  final _ingredientFocus = FocusNode();

  final List<Ingredient> _ingredients = [];
  List<Suggestion> _suggestions = [];
  final Set<String> _dismissed = {};

  Timer? _debounce;
  int _reviewSeq = 0;
  bool _reviewing = false;
  bool _autofilling = false;
  bool _saving = false;
  bool _addToList = true;
  bool _loaded = false;
  String? _aiError;

  bool get _isNew => widget.recipeId == null;

  @override
  void initState() {
    super.initState();
    if (!_isNew) {
      final key = (listId: widget.listId, recipeId: widget.recipeId!);
      final existing = ref.read(recipeProvider(key));
      if (existing != null) {
        _populate(existing);
      } else {
        ref.listenManual(recipeProvider(key), (_, next) {
          if (next != null && !_loaded) setState(() => _populate(next));
        });
      }
    } else {
      _loaded = true;
    }
    // Added after populating so opening an existing meal doesn't call the model.
    _name.addListener(_onNameChanged);
  }

  void _populate(Recipe r) {
    _loaded = true;
    _lastNameReviewed = r.name;
    _name.text = r.name;
    _ingredients
      ..clear()
      ..addAll(r.ingredients);
    final items = ref.read(itemsProvider(widget.listId)).value ?? const <Item>[];
    _addToList = items.any((i) => i.recipeId == r.id && !i.checked);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _ingredientInput.dispose();
    _ingredientFocus.dispose();
    super.dispose();
  }

  Repository get _repo => ref.read(repositoryProvider);
  String get _meal => _name.text.trim();
  bool _has(String name) => _ingredients.any((i) => i.name.toLowerCase() == name.trim().toLowerCase());

  // ------------------------------------------------------------ AI review

  String _lastNameReviewed = '';

  void _onNameChanged() {
    if (_meal == _lastNameReviewed) return;
    setState(() {});
    _scheduleReview();
  }

  void _scheduleReview() {
    _debounce?.cancel();
    if (_meal.isEmpty || _ingredients.isEmpty) {
      _reviewSeq++; // drop any in-flight review
      setState(() {
        _reviewing = false;
        _suggestions = [];
      });
      return;
    }
    _debounce = Timer(_reviewDelay, _review);
  }

  Future<void> _review() async {
    final seq = ++_reviewSeq;
    _lastNameReviewed = _meal;
    setState(() {
      _reviewing = true;
      _aiError = null;
    });
    try {
      final result = await _repo.suggestIngredients(
        meal: _meal,
        ingredients: _ingredients.map((i) => i.name).toList(),
        dismissed: _dismissed.toList(),
      );
      if (!mounted || seq != _reviewSeq) return;
      setState(() => _suggestions = result.where((s) => !_has(s.name)).toList());
    } catch (e) {
      if (mounted && seq == _reviewSeq) setState(() => _aiError = friendlyError(e));
    } finally {
      if (mounted && seq == _reviewSeq) setState(() => _reviewing = false);
    }
  }

  Future<void> _autofill() async {
    if (_meal.isEmpty) return;
    _debounce?.cancel();
    final seq = ++_reviewSeq;
    setState(() {
      _autofilling = true;
      _aiError = null;
    });
    try {
      final result = await _repo.suggestIngredients(
        meal: _meal,
        ingredients: _ingredients.map((i) => i.name).toList(),
        dismissed: _dismissed.toList(),
        autofill: true,
      );
      if (!mounted || seq != _reviewSeq) return;
      final core = result.where((s) => s.severity == SuggestionSeverity.missing && !_has(s.name)).toList();
      final before = List<Ingredient>.of(_ingredients);
      HapticFeedback.lightImpact();
      setState(() {
        for (final s in core) {
          _ingredients.add(Ingredient(name: s.name, quantity: s.quantity));
        }
        _suggestions = result.where((s) => s.severity == SuggestionSeverity.optional && !_has(s.name)).toList();
        _lastNameReviewed = _meal;
      });
      if (core.isNotEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('Added ${core.length} ingredients'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => setState(() {
                _ingredients
                  ..clear()
                  ..addAll(before);
                _suggestions = [];
              }),
            ),
          ));
      }
    } catch (e) {
      if (mounted && seq == _reviewSeq) setState(() => _aiError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _autofilling = false);
    }
  }

  void _accept(Suggestion s) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_has(s.name)) _ingredients.add(Ingredient(name: s.name, quantity: s.quantity));
      _suggestions = _suggestions.where((x) => x != s).toList();
    });
  }

  void _acceptAll() {
    HapticFeedback.lightImpact();
    setState(() {
      for (final s in _suggestions) {
        if (!_has(s.name)) _ingredients.add(Ingredient(name: s.name, quantity: s.quantity));
      }
      _suggestions = [];
    });
  }

  void _dismiss(Suggestion s) {
    setState(() {
      _dismissed.add(s.name.toLowerCase());
      _suggestions = _suggestions.where((x) => x != s).toList();
    });
  }

  // ---------------------------------------------------------- ingredients

  void _addIngredient() {
    final text = _ingredientInput.text.trim();
    if (text.isEmpty) return;
    final parsed = parseItemInput(text);
    _ingredientInput.clear();
    _ingredientFocus.requestFocus();
    if (_has(parsed.name)) return;
    setState(() {
      _ingredients.add(Ingredient(name: parsed.name, quantity: parsed.quantity));
      // Typing something we were about to suggest answers that suggestion.
      _suggestions = _suggestions.where((s) => s.name.toLowerCase() != parsed.name.toLowerCase()).toList();
    });
    _scheduleReview();
  }

  void _removeIngredient(Ingredient i) {
    setState(() => _ingredients.remove(i));
    _scheduleReview();
  }

  // ----------------------------------------------------------------- save

  Future<void> _save() async {
    if (_meal.isEmpty) {
      showError(context, 'Give the meal a name first');
      return;
    }
    // Keep anything typed but not yet submitted.
    if (_ingredientInput.text.trim().isNotEmpty) _addIngredient();

    setState(() => _saving = true);
    try {
      final id = await _repo.saveRecipe(
        listId: widget.listId,
        recipeId: widget.recipeId,
        name: _meal,
        ingredients: [
          for (var i = 0; i < _ingredients.length; i++)
            Ingredient(name: _ingredients[i].name, quantity: _ingredients[i].quantity, position: i),
        ],
      );
      if (_addToList) {
        await _repo.addRecipeToList(id);
      } else if (!_isNew) {
        await _repo.removeRecipeFromList(id);
      }
      // Fire and forget: the photo shows up via realtime when it's ready, and
      // the function skips regeneration if the meal hasn't meaningfully changed.
      unawaited(_repo.generateImage(id).catchError((_) {}));
      if (mounted) context.go('/lists/${widget.listId}/recipes/$id');
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!_loaded) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }

    final missing = _suggestions.where((s) => s.severity == SuggestionSeverity.missing).toList();
    final optional = _suggestions.where((s) => s.severity == SuggestionSeverity.optional).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New meal' : 'Edit meal'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          TextField(
            controller: _name,
            autofocus: _isNew,
            textCapitalization: TextCapitalization.words,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            decoration: const InputDecoration(
              hintText: 'What\'s the meal?',
              filled: false,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'e.g. Taco bowls, Salmon power bowl, Sunday pancakes',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),

          Row(
            children: [
              Text('Ingredients', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_ingredients.isNotEmpty)
                TextButton.icon(
                  onPressed: _meal.isEmpty || _autofilling ? null : _autofill,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Fill in the rest'),
                ),
            ],
          ),
          const SizedBox(height: 8),

          if (_ingredients.isEmpty)
            _AutofillCard(
              meal: _meal,
              busy: _autofilling,
              onPressed: _meal.isEmpty || _autofilling ? null : _autofill,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final i in _ingredients)
                  InputChip(
                    label: Text(i.quantity == null ? i.name : '${i.name} · ${i.quantity}'),
                    onDeleted: () => _removeIngredient(i),
                  ),
              ],
            ),
          if (_autofilling && _ingredients.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _ingredientInput,
            focusNode: _ingredientFocus,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'Add an ingredient',
              prefixIcon: const Icon(Icons.add),
              suffixIcon: IconButton(icon: const Icon(Icons.keyboard_return), onPressed: _addIngredient),
            ),
            onSubmitted: (_) => _addIngredient(),
          ),

          // ---- suggestions
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_reviewing || _suggestions.isNotEmpty || _aiError != null) ...[
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        _reviewing ? 'Checking your list…' : 'Basil noticed',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (_reviewing) ...[
                        const SizedBox(width: 10),
                        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                      const Spacer(),
                      if (!_reviewing && _suggestions.length > 1)
                        TextButton(onPressed: _acceptAll, child: const Text('Add all')),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (_aiError != null)
                  Text(_aiError!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
                for (final s in missing)
                  _SuggestionCard(suggestion: s, onAccept: () => _accept(s), onDismiss: () => _dismiss(s)),
                if (optional.isNotEmpty) ...[
                  if (missing.isNotEmpty) const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in optional)
                        Tooltip(
                          message: s.reason,
                          triggerMode: TooltipTriggerMode.longPress,
                          child: ActionChip(
                            avatar: const Icon(Icons.add, size: 18),
                            label: Text('Maybe ${s.name.toLowerCase()}?'),
                            onPressed: () => _accept(s),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 28),
          Card(
            child: SwitchListTile(
              value: _addToList,
              onChanged: (v) => setState(() => _addToList = v),
              title: const Text('Put ingredients on the shopping list'),
              subtitle: const Text('Skips anything already on it'),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.photo_camera_outlined, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'After you save, Basil makes a photo of the finished meal using these ingredients.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AutofillCard extends StatelessWidget {
  const _AutofillCard({required this.meal, required this.busy, required this.onPressed});

  final String meal;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.6),
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              busy
                  ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Icon(Icons.auto_awesome, color: scheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      busy
                          ? 'Thinking about $meal…'
                          : meal.isEmpty
                              ? 'Name the meal and Basil can fill in the ingredients'
                              : 'Fill in ingredients for $meal',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Or add your own below. You can edit everything.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion, required this.onAccept, required this.onDismiss});

  final Suggestion suggestion;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF3A3020) : const Color(0xFFFFF3D6);
    final fg = dark ? const Color(0xFFFFD98A) : const Color(0xFF7A5200);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: 'Forgetting '),
                      TextSpan(text: suggestion.name.toLowerCase(), style: const TextStyle(fontWeight: FontWeight.w800)),
                      const TextSpan(text: '?'),
                    ]),
                    style: theme.textTheme.bodyLarge?.copyWith(color: fg),
                  ),
                  if (suggestion.reason.isNotEmpty)
                    Text(suggestion.reason, style: theme.textTheme.bodySmall?.copyWith(color: fg.withValues(alpha: 0.85))),
                ],
              ),
            ),
            IconButton(
              tooltip: 'No thanks',
              onPressed: onDismiss,
              icon: Icon(Icons.close, color: fg),
            ),
            IconButton.filled(
              tooltip: 'Add',
              style: IconButton.styleFrom(backgroundColor: fg, foregroundColor: bg),
              onPressed: onAccept,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
      ),
    );
  }
}
