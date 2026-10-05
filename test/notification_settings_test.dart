import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/data/sharing_repository.dart';
import 'package:lamars_groceries/features/notifications/notification_settings_screen.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeSharing extends SharingRepository {
  _FakeSharing(super.db);

  final saved = <NotificationSettings>[];
  final mutes = <(String, bool)>[];
  bool fail = false;

  @override
  Future<void> saveSettings(NotificationSettings s) async {
    if (fail) throw const PostgrestException(message: 'Lamar knocked the server off the table');
    saved.add(s);
  }

  @override
  Future<void> setListMuted(String listId, bool muted) async => mutes.add((listId, muted));
}

ShoppingList list(String id, String name) =>
    ShoppingList(id: id, name: name, emoji: '🥕', ownerId: 'me', createdAt: DateTime(2026));

void main() {
  late SupabaseClient db;
  late _FakeSharing sharing;
  setUp(() {
    db = SupabaseClient('http://localhost:1', 'test-key');
    sharing = _FakeSharing(db);
  });
  tearDown(() => db.dispose());

  Widget app({NotificationSettings settings = const NotificationSettings(), double textScale = 1}) => ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(db),
      currentUserIdProvider.overrideWithValue('me'),
      sharingRepositoryProvider.overrideWithValue(sharing),
      notificationSettingsProvider.overrideWith((ref) async => settings),
      mutedListIdsProvider.overrideWith((ref) async => {'L2'}),
      listsProvider.overrideWith(
        (ref) => Stream.value([list('L1', 'Weekly groceries'), list('L2', 'Costco run with a very long name indeed')]),
      ),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const NotificationSettingsScreen(),
    ),
  );

  SwitchListTile tile(WidgetTester tester, String title) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

  testWidgets('shows settings, per-list mutes, and that push is off on this device', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Push isn\'t available on this device yet'), findsOneWidget);
    expect(tile(tester, 'Push notifications').value, isTrue);
    expect(tile(tester, 'Someone heads to the store').value, isTrue);
    expect(tile(tester, 'Weekly groceries').value, isTrue);
    expect(find.text('Muted'), findsOneWidget); // L2
  });

  testWidgets('toggling saves, and the master switch disables the rest', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Someone adds things'));
    await tester.pumpAndSettle();
    expect(sharing.saved.last.itemsAdded, isFalse);
    expect(tile(tester, 'Someone adds things').value, isFalse);

    await tester.tap(find.text('Push notifications'));
    await tester.pumpAndSettle();
    expect(sharing.saved.last.enabled, isFalse);
    expect(tile(tester, 'Someone heads to the store').onChanged, isNull);
  });

  testWidgets('muting a list', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly groceries'));
    await tester.pumpAndSettle();
    expect(sharing.mutes, [('L1', true)]);
    expect(find.text('Muted'), findsNWidgets(2));
  });

  testWidgets('a failed save rolls back and explains', (tester) async {
    sharing.fail = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Someone joins a list'));
    await tester.pumpAndSettle();
    expect(tile(tester, 'Someone joins a list').value, isTrue);
    expect(find.text('Lamar knocked the server off the table'), findsOneWidget);
  });

  for (final (size, textScale) in [(const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
    testWidgets('fits at $size, text ×$textScale', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(textScale: textScale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
