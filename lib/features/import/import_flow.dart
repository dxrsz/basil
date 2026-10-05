import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/import_repository.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/lamar.dart';
import 'import_review_sheet.dart';

export 'import_review_sheet.dart' show ImportDecision, ImportTarget;

/// Snap or paste to add, start to finish: pick a source, let Lamar read it,
/// review, then apply to the list (or save a meal). Never writes anything
/// the user didn't confirm in the review sheet.
Future<void> importToList(BuildContext context, WidgetRef ref, {required String listId, String? initialText}) async {
  final router = GoRouter.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final decision = await runImport(context, ref, target: ImportTarget.shopping, initialText: initialText);
  if (decision == null || decision.items.isEmpty) return;

  try {
    if (decision.asMeal) {
      final repo = ref.read(repositoryProvider);
      final id = await repo.saveRecipe(
        listId: listId,
        name: decision.mealName,
        ingredients: [
          for (var i = 0; i < decision.items.length; i++)
            Ingredient(name: decision.items[i].name, quantity: decision.items[i].quantity, position: i),
        ],
      );
      if (decision.addToList) await repo.addRecipeToList(id);
      // Same as the meal editor: the photo arrives via realtime when ready.
      unawaited(repo.generateImage(id).catchError((_) {}));
      router.go('/lists/$listId/recipes/$id');
      messenger.showSnackBar(SnackBar(content: Text('Saved ${decision.mealName}. Lamar is snapping a photo of it.')));
    } else {
      final existing = ref.read(itemsProvider(listId)).value ?? const <Item>[];
      final added = await ref.read(importRepositoryProvider).addItems(listId, decision.items, existing: existing);
      final skipped = decision.items.length - added;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              added == 0
                  ? 'Everything was already on the list'
                  : 'Added $added item${added == 1 ? '' : 's'}'
                        '${skipped > 0 ? ' ($skipped already on the list)' : ''}',
            ),
          ),
        );
    }
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}

/// Source -> Lamar reads it -> review. Returns what the user kept, or null.
Future<ImportDecision?> runImport(
  BuildContext context,
  WidgetRef ref, {
  required ImportTarget target,
  String? initialText,
}) async {
  final source = await showModalBottomSheet<_Source>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _SourceSheet(target: target, initialText: initialText),
  );
  if (source == null || !context.mounted) return null;

  final importer = ref.read(importRepositoryProvider);
  final hint = target == ImportTarget.editor ? ImportKind.recipe : null;
  final Future<ImportResult> Function() read;
  final String reading;
  switch (source) {
    case _PhotoSource(:final camera):
      final Uint8List? bytes;
      try {
        bytes = await _pickPhoto(camera);
      } on PlatformException catch (_) {
        if (context.mounted) {
          showError(
            context,
            camera
                ? 'Lamar needs camera access for that. You can allow it in Settings.'
                : 'Lamar couldn\'t open your photos. You can allow access in Settings.',
          );
        }
        return null;
      }
      if (bytes == null) return null;
      read = () => importer.fromImage(bytes!, hint: hint);
      reading = 'Squinting at your photo…';
    case _TextSource(:final text):
      final link = linkIn(text);
      if (link != null) {
        read = () => importer.fromUrl(link);
        reading = 'Fetching the recipe…';
      } else {
        read = () => importer.fromText(text, hint: hint);
        reading = 'Reading what you pasted…';
      }
  }
  if (!context.mounted) return null;

  final result = await _withReadingDialog(context, reading, read);
  if (result == null || !context.mounted) return null;
  return showImportReview(context, result, target);
}

Future<Uint8List?> _pickPhoto(bool camera) async {
  // Downscale and recompress on the device: long edge ≤ 1600 px, JPEG. That's
  // plenty for reading handwriting and keeps uploads to a few hundred KB.
  final file = await ImagePicker().pickImage(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 80,
    requestFullMetadata: false,
  );
  return file?.readAsBytes();
}

/// Runs [work] behind a cancellable "Lamar is reading" dialog. Errors are
/// shown as a snackbar; returns null on error or cancel.
Future<ImportResult?> _withReadingDialog(
  BuildContext context,
  String message,
  Future<ImportResult> Function() work,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => _ReadingDialog(message: message),
    ).then((_) => open = false),
  );
  try {
    final result = await work();
    if (!open) return null; // cancelled
    navigator.pop();
    return result;
  } catch (e) {
    if (!open) return null;
    navigator.pop();
    if (context.mounted) showError(context, friendlyError(e));
    return null;
  }
}

class _ReadingDialog extends StatelessWidget {
  const _ReadingDialog({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Lamar(width: 96),
          const SizedBox(height: 16),
          Text('Lamar is on it', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

// ------------------------------------------------------------------ source

sealed class _Source {
  const _Source();
}

class _PhotoSource extends _Source {
  const _PhotoSource({required this.camera});

  final bool camera;
}

class _TextSource extends _Source {
  const _TextSource(this.text);

  final String text;
}

class _SourceSheet extends StatefulWidget {
  const _SourceSheet({required this.target, this.initialText});

  final ImportTarget target;
  final String? initialText;

  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  late final _text = TextEditingController(text: widget.initialText ?? '');

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      showError(context, 'Nothing to paste. Copy a recipe link or a list first.');
      return;
    }
    _text.text = text;
  }

  void _submit() {
    final text = _text.text.trim();
    if (text.isNotEmpty) Navigator.pop(context, _TextSource(text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final forMeal = widget.target == ImportTarget.editor;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                forMeal ? 'Import from a photo or link' : 'Snap or paste',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                forMeal
                    ? 'Lamar can read a recipe card, a cookbook page or a recipe link.'
                    : 'Lamar can read a shopping list, a recipe, or what\'s in your fridge. '
                          'You\'ll check everything before it\'s added.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              subtitle: Text(forMeal ? 'A recipe card or cookbook page' : 'A list, a recipe card, or your fridge'),
              onTap: () => Navigator.pop(context, const _PhotoSource(camera: true)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              subtitle: const Text('Screenshots work too'),
              onTap: () => Navigator.pop(context, const _PhotoSource(camera: false)),
            ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: forMeal ? 'Paste a recipe link or recipe' : 'Paste a recipe link or a list',
                  prefixIcon: const Icon(Icons.link),
                  suffixIcon: _text.text.isEmpty
                      ? IconButton(tooltip: 'Paste', icon: const Icon(Icons.content_paste), onPressed: _paste)
                      : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _text.clear),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _text.text.trim().isEmpty ? null : _submit,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Have Lamar read it'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
