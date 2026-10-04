import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'features/splash/splash_screen.dart';
import 'router.dart';
import 'theme.dart';

void main() {
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
    if (Config.isConfigured)
      Supabase.initialize(url: Config.supabaseUrl, publishableKey: Config.supabaseKey),
    Future<void>.delayed(splashMinDuration),
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
            message: Config.isConfigured
                ? 'Basil couldn\'t start.\n\n${snapshot.error}'
                : 'Basil isn\'t configured.\n\nRun with:\nflutter run --dart-define-from-file=env.json\n\n(see env.example.json)',
          );
        } else {
          child = const ProviderScope(key: ValueKey('app'), child: BasilApp());
        }
        return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: child);
      },
    );
  }
}

class BasilApp extends ConsumerWidget {
  const BasilApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Basil',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
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
