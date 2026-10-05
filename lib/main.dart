import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'data/offline/offline_providers.dart';
import 'features/splash/splash_screen.dart';
import 'router.dart';
import 'theme.dart';

void main() {
  // On web, use real paths (/lists/abc) instead of /#/lists/abc so links such
  // as invites can be shared. No-op on iOS/Android.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Bootstrap());
}

/// Shows the dancing-cat splash while Supabase initialises (and restores any
/// saved session), for at least one loop of the animation, then fades into
/// the app.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<void> _ready = Future.wait([
    if (Config.isConfigured) Supabase.initialize(url: Config.supabaseUrl, publishableKey: Config.supabaseKey),
    Future<void>.delayed(splashMinDuration),
    initOfflineStorage(),
  ]);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        final Widget child;
        if (snapshot.connectionState != ConnectionState.done) {
          child = const SplashScreen(key: ValueKey('splash'));
        } else if (!Config.isConfigured || snapshot.hasError) {
          child = _ProblemApp(
            key: const ValueKey('problem'),
            message: Config.isConfigured ? 'Lamar\'s Groceries couldn\'t start.\n\n${snapshot.error}' : 'Lamar\'s Groceries isn\'t configured.\n\nRun with:\nflutter run --dart-define-from-file=env.json\n\n(see env.example.json)',
          );
        } else {
          child = const ProviderScope(key: ValueKey('app'), child: LamarsApp());
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: child);
      },
    );
  }
}

class LamarsApp extends ConsumerWidget {
  const LamarsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Lamar\'s Groceries',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => _PhoneWidth(child: child!),
    );
  }
}

/// This is a phone app; on wide screens (web, tablets) keep it phone-shaped
/// and centred instead of stretching lists across the window.
class _PhoneWidth extends StatelessWidget {
  const _PhoneWidth({required this.child});

  static const maxWidth = 560.0;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.size.width <= maxWidth) return child;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: ClipRect(
          child: SizedBox(
            width: maxWidth,
            child: MediaQuery(
              data: mq.copyWith(size: Size(maxWidth, mq.size.height)),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemApp extends StatelessWidget {
  const _ProblemApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(message, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
