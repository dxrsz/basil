import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/offline/kv_store.dart';
import 'package:lamars_groceries/data/offline/offline_providers.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

class _User extends Notifier<String?> {
  @override
  String? build() => 'user-a';
  void set(String? id) => state = id;
}

final _user = NotifierProvider<_User, String?>(_User.new);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression: signing in as someone else rebuilt the outbox, which listened
  // again to the one cached connectivity stream: "Stream has already been
  // listened to" (seen on a Pixel after signing in with Apple).
  test('the outbox survives the signed-in user changing', () async {
    var streams = 0;
    final c = ProviderContainer(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => ref.watch(_user)),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        supabaseProvider.overrideWithValue(SupabaseClient('http://localhost:1', 'test-key')),
        connectionProbeProvider.overrideWithValue(() async => true),
        // Like the real one: a fresh single-subscription stream per call.
        networkAvailableProvider.overrideWithValue(() {
          streams++;
          return Stream.value(true);
        }),
      ],
    );
    addTearDown(c.dispose);

    final sub = c.listen(outboxProvider, (_, _) {});
    final first = c.read(outboxProvider);
    expect(first, isNotNull);

    c.read(_user.notifier).set('user-b'); // e.g. signed in with Apple
    final second = c.read(outboxProvider);
    expect(second, isNotNull);
    expect(identical(first, second), isFalse);

    c.read(_user.notifier).set(null); // signed out
    expect(c.read(outboxProvider), isNull);

    expect(streams, 2); // each outbox got its own stream
    sub.close();
  });
}
