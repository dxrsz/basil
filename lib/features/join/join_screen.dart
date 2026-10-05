import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../widgets/empty_state.dart';
import '../notifications/push.dart';
import 'join_link.dart';
import 'join_routing.dart';

/// `/join/:code`: joins the list behind an invite link, then opens it.
class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

enum _Problem { invalid, failed }

class _JoinScreenState extends ConsumerState<JoinScreen> {
  _Problem? _problem;
  String? _detail;

  @override
  void initState() {
    super.initState();
    PendingJoin.clear();
    _join();
  }

  Future<void> _join() async {
    if (_problem != null) setState(() => _problem = null);
    final code = normalizeInviteCode(widget.code);
    if (code == null) {
      _problem = _Problem.invalid;
      return;
    }
    try {
      final listId = await ref.read(repositoryProvider).joinList(code);
      if (!mounted) return;
      context.go('/lists/$listId');
      // Now that they share a list, offer notifications (asked only once).
      ref.read(pushServiceProvider).requestPermissionIfNeeded();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      // P0002: join_list's "invalid or has expired".
      setState(() {
        _problem = e.code == 'P0002' ? _Problem.invalid : _Problem.failed;
        _detail = friendlyError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = _Problem.failed;
        _detail = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = TextButton(onPressed: () => context.go('/'), child: const Text('Go to my lists'));
    return Scaffold(
      appBar: AppBar(leading: CloseButton(onPressed: () => context.go('/'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 32),
          child: switch (_problem) {
            null => const Padding(
              padding: EdgeInsets.only(top: 64),
              child: Column(
                children: [CircularProgressIndicator(), SizedBox(height: 20), Text('Lamar is letting you in…')],
              ),
            ),
            _Problem.invalid => EmptyState(
              emoji: '🙀',
              title: 'That invite didn\'t work',
              message:
                  'The link is invalid or has expired (invites last 7 days). '
                  'Ask whoever sent it for a fresh one.',
              action: FilledButton(onPressed: () => context.go('/'), child: const Text('Go to my lists')),
            ),
            _Problem.failed => EmptyState(
              emoji: '😿',
              title: 'Couldn\'t join just now',
              message: _detail ?? 'Something went wrong.',
              action: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(onPressed: _join, child: const Text('Try again')),
                  home,
                ],
              ),
            ),
          },
        ),
      ),
    );
  }
}
