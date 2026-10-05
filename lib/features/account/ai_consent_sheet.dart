import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/account_repository.dart';
import '../../data/repository.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/lamar.dart';

/// What Lamar's AI helpers send to OpenAI, said plainly. Shared by the
/// first-run sheet and the Account screen.
const aiConsentDetails =
    'Meal ideas, ingredient checks, meal pictures, list tidying and photo '
    'imports are done by OpenAI. When you use them, the meal names, list '
    'items, taste notes and photos involved are sent to OpenAI to get an '
    'answer. OpenAI doesn\'t use them to train its models. Your email and '
    'name are never sent.';

/// Asked once, after the first sign-in: may Lamar use OpenAI for you?
/// Everything else in the app works either way. Returns their answer, or
/// null if they dismissed it (they'll be asked again next time).
Future<bool?> showAiConsentSheet(BuildContext context, WidgetRef ref) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  isDismissible: false,
  enableDrag: false,
  builder: (_) => const _AiConsentSheet(),
);

class _AiConsentSheet extends ConsumerStatefulWidget {
  const _AiConsentSheet();

  @override
  ConsumerState<_AiConsentSheet> createState() => _AiConsentSheetState();
}

class _AiConsentSheetState extends ConsumerState<_AiConsentSheet> {
  bool _busy = false;

  Future<void> _answer(bool granted) async {
    setState(() => _busy = true);
    try {
      await ref.read(accountRepositoryProvider).setAiConsent(granted);
      ref.invalidate(myProfileProvider);
      if (mounted) Navigator.of(context).pop(granted);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, friendlyError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: Lamar(width: 72)),
            const SizedBox(height: 12),
            Text(
              'Want Lamar\'s AI helpers?',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(aiConsentDetails, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              'Lists, sharing and meals work without them. You can change this any time in Account.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => launchUrl(privacyPolicyUrl, mode: LaunchMode.externalApplication),
                child: const Text('Privacy policy'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _busy ? null : () => _answer(true), child: const Text('Turn on AI helpers')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _busy ? null : () => _answer(false), child: const Text('Not now')),
          ],
        ),
      ),
    );
  }
}

/// Session flag so the sheet shows at most once per launch.
final _askedProvider = NotifierProvider<_Asked, bool>(_Asked.new);

class _Asked extends Notifier<bool> {
  @override
  bool build() => false;

  void set() => state = true;
}

/// Wraps the home screen: asks about AI once the profile loads and shows
/// they've never answered.
class AiConsentGate extends ConsumerWidget {
  const AiConsentGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile != null && profile.aiConsent == null && !ref.watch(_askedProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted || ref.read(_askedProvider)) return;
        ref.read(_askedProvider.notifier).set();
        showAiConsentSheet(context, ref);
      });
    }
    return child;
  }
}
