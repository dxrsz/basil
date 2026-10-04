import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../widgets/empty_state.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  OAuthProvider? _busy;

  Future<void> _signIn(OAuthProvider provider) async {
    setState(() => _busy = provider);
    try {
      await ref.read(repositoryProvider).signIn(provider);
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Apple first on iOS, per Apple's guidelines.
    final order = Platform.isIOS
        ? [OAuthProvider.apple, OAuthProvider.google]
        : [OAuthProvider.google, OAuthProvider.apple];
    // Only offer providers that are switched on in Supabase. If the check
    // fails (e.g. offline), show them all rather than none.
    final enabled = ref.watch(enabledProvidersProvider);
    final providers = switch (enabled) {
      AsyncData(:final value) => order.where(value.contains).toList(),
      AsyncError() => order,
      _ => const <OAuthProvider>[],
    };

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Text('🌿', style: TextStyle(fontSize: 48)),
              ),
              const SizedBox(height: 28),
              Text('Basil', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(
                'Shared grocery lists that know what\'s for dinner.',
                style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              const _Feature(icon: Icons.group_outlined, text: 'Shop together, updated live'),
              const _Feature(icon: Icons.restaurant_menu, text: 'Turn meals into lists in one tap'),
              const _Feature(icon: Icons.auto_awesome_outlined, text: 'Catch the ingredient you forgot'),
              const Spacer(flex: 3),
              if (enabled.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 17),
                  child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                ),
              for (final p in providers) ...[
                _ProviderButton(
                  provider: p,
                  busy: _busy == p,
                  onPressed: _busy == null ? () => _signIn(p) : null,
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Text(text, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({required this.provider, required this.busy, required this.onPressed});

  final OAuthProvider provider;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isApple = provider == OAuthProvider.apple;
    final label = isApple ? 'Continue with Apple' : 'Continue with Google';
    final child = busy
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              isApple
                  ? const Icon(Icons.apple, size: 22)
                  : const Text('G', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          );

    if (isApple) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: dark ? Colors.white : Colors.black,
          foregroundColor: dark ? Colors.black : Colors.white,
          minimumSize: const Size.fromHeight(54),
        ),
        onPressed: onPressed,
        child: child,
      );
    }
    return OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
      onPressed: onPressed,
      child: child,
    );
  }
}
