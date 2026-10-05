import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/account_repository.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../widgets/empty_state.dart';
import '../notifications/push.dart';
import 'ai_consent_sheet.dart';

/// Your name, how you sign in, AI helpers, your data, and leaving.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(myProfileProvider);
    final email = ref.watch(supabaseProvider).auth.currentUser?.email;

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          switch (profile) {
            AsyncData(:final value?) => _NameTile(name: value.displayName, email: email),
            AsyncError(:final error) => ListTile(title: Text(friendlyError(error))),
            _ => const ListTile(title: Text('Loading…')),
          },
          header('Sign-in methods'),
          const _Identities(),
          header('Lamar\'s AI helpers'),
          switch (profile) {
            AsyncData(:final value?) => _AiTile(on: value.aiConsent == true),
            _ => const SizedBox.shrink(),
          },
          header('Settings'),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Notifications'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/notifications'),
          ),
          header('Your data'),
          const _ExportTile(),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrl(privacyPolicyUrl, mode: LaunchMode.externalApplication),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () => signOutAndUnregister(ref),
          ),
          const _DeleteTile(),
        ],
      ),
    );
  }
}

class _NameTile extends ConsumerWidget {
  const _NameTile({required this.name, required this.email});

  final String name;
  final String? email;

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: name);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(helperText: 'What people on your lists see'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (next == null || next.trim().isEmpty || next.trim() == name || !context.mounted) return;
    try {
      await ref.read(accountRepositoryProvider).setDisplayName(next);
      ref.invalidate(myProfileProvider);
    } catch (e) {
      if (context.mounted) showError(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const CircleAvatar(child: Icon(Icons.person_outline)),
    title: Text(name.isEmpty ? 'Add your name' : name),
    subtitle: email == null ? null : Text(email!),
    trailing: const Icon(Icons.edit_outlined, size: 20),
    onTap: () => _edit(context, ref),
  );
}

String _providerLabel(String provider) => switch (provider) {
  'apple' => 'Apple',
  'google' => 'Google',
  _ => provider[0].toUpperCase() + provider.substring(1),
};

IconData _providerIcon(String provider) => switch (provider) {
  'apple' => Icons.apple,
  'google' => Icons.g_mobiledata,
  _ => Icons.login,
};

class _Identities extends ConsumerStatefulWidget {
  const _Identities();

  @override
  ConsumerState<_Identities> createState() => _IdentitiesState();
}

class _IdentitiesState extends ConsumerState<_Identities> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(identitiesProvider);
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink(UserIdentity identity) async {
    final label = _providerLabel(identity.provider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect $label?'),
        content: Text('You won\'t be able to sign in with $label any more. Your lists stay put.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok == true) await _run(() => ref.read(accountRepositoryProvider).unlink(identity));
  }

  @override
  Widget build(BuildContext context) {
    final identities = ref.watch(identitiesProvider);
    final enabled = ref.watch(enabledProvidersProvider).value ?? {OAuthProvider.apple, OAuthProvider.google};
    final list = identities.value;
    if (list == null) {
      return identities.hasError
          ? ListTile(title: Text(friendlyError(identities.error!)))
          : const ListTile(title: Text('Loading…'));
    }
    final have = {for (final i in list) i.provider};
    // Apple first on iOS, as on the sign-in screen.
    final order = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? [OAuthProvider.apple, OAuthProvider.google]
        : [OAuthProvider.google, OAuthProvider.apple];

    return Column(
      children: [
        for (final i in list)
          ListTile(
            leading: Icon(_providerIcon(i.provider)),
            title: Text(_providerLabel(i.provider)),
            subtitle: Text((i.identityData?['email'] as String?) ?? 'Connected'),
            // You need at least one way back in.
            trailing: list.length > 1
                ? TextButton(onPressed: _busy ? null : () => _unlink(i), child: const Text('Disconnect'))
                : null,
          ),
        for (final p in order)
          if (enabled.contains(p) && !have.contains(p.name))
            ListTile(
              leading: Icon(_providerIcon(p.name), color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: Text('Connect ${_providerLabel(p.name)}'),
              subtitle: const Text('Sign in either way, same lists'),
              trailing: const Icon(Icons.add_link),
              enabled: !_busy,
              onTap: () => _run(() => ref.read(accountRepositoryProvider).link(p)),
            ),
      ],
    );
  }
}

class _AiTile extends ConsumerStatefulWidget {
  const _AiTile({required this.on});

  final bool on;

  @override
  ConsumerState<_AiTile> createState() => _AiTileState();
}

class _AiTileState extends ConsumerState<_AiTile> {
  bool? _pending;

  Future<void> _set(bool on) async {
    setState(() => _pending = on);
    try {
      await ref.read(accountRepositoryProvider).setAiConsent(on);
      ref.invalidate(myProfileProvider);
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.auto_awesome_outlined),
          title: const Text('Use AI helpers'),
          subtitle: const Text('Meal ideas, ingredient checks, pictures, tidying, photo imports'),
          value: _pending ?? widget.on,
          onChanged: _pending == null ? _set : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            aiConsentDetails,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _ExportTile extends ConsumerStatefulWidget {
  const _ExportTile();

  @override
  ConsumerState<_ExportTile> createState() => _ExportTileState();
}

class _ExportTileState extends ConsumerState<_ExportTile> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(accountRepositoryProvider).exportData();
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final file = XFile.fromData(utf8.encode(json), mimeType: 'application/json', name: 'lamars-groceries-$day.json');
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [file.name],
          subject: 'My Lamar\'s Groceries data',
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) showError(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.download_outlined),
    title: const Text('Download my data'),
    subtitle: const Text('Your lists, meals and settings as a file'),
    trailing: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
    onTap: _busy ? null : _export,
  );
}

class _DeleteTile extends ConsumerStatefulWidget {
  const _DeleteTile();

  @override
  ConsumerState<_DeleteTile> createState() => _DeleteTileState();
}

class _DeleteTileState extends ConsumerState<_DeleteTile> {
  bool _busy = false;

  Future<void> _delete() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _ConfirmDelete());
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(pushServiceProvider).unregister().timeout(const Duration(seconds: 3), onTimeout: () {});
      await ref.read(accountRepositoryProvider).deleteAccount();
      // Signed out now; the router takes them to the sign-in screen.
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, friendlyError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return ListTile(
      leading: Icon(Icons.delete_forever_outlined, color: error),
      title: Text('Delete account', style: TextStyle(color: error)),
      trailing: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
      onTap: _busy ? null : _delete,
    );
  }
}

/// Spells out what happens, and makes them type DELETE.
class _ConfirmDelete extends StatefulWidget {
  const _ConfirmDelete();

  @override
  State<_ConfirmDelete> createState() => _ConfirmDeleteState();
}

class _ConfirmDeleteState extends State<_ConfirmDelete> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final ready = _controller.text.trim().toUpperCase() == 'DELETE';
    return AlertDialog(
      title: const Text('Delete your account?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '• Lists only you use are deleted, with their meals.\n'
              '• Lists you share stay for everyone else; the next person on each one takes it over.\n'
              '• Your sign-in, settings and AI history are erased. This can\'t be undone.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Type DELETE to confirm'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: error),
          onPressed: ready ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete forever'),
        ),
      ],
    );
  }
}
