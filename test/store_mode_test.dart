import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lamars_groceries/data/offline/kv_store.dart';
import 'package:lamars_groceries/data/offline/offline_providers.dart';
import 'package:lamars_groceries/data/offline/outbox.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/data/repository.dart';
import 'package:lamars_groceries/features/list/shopping_tab.dart';
import 'package:lamars_groceries/features/store/store_mode.dart';
import 'package:lamars_groceries/features/store/store_mode_screen.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';
import 'package:lamars_groceries/widgets/connectivity_banner.dart';
import 'package:lamars_groceries/widgets/lamar.dart';
import 'package:supabase/supabase.dart' show AuthClientOptions, SupabaseClient;

const listId = 'list-1';

class FakeAwake extends ScreenAwake {
  final calls = <bool>[];
  @override
  Future<void> set(bool on) async => calls.add(on);
}

/// A fake `items` table behind a real [Outbox], with "realtime" that echoes
/// whatever the server holds whenever the outbox changes.
class World {
  World(List<Map<String, dynamic>> initial) {
    for (final r in initial) {
      rows[r['id'] as String] = r;
    }
    outbox = Outbox(
      store: MemoryKeyValueStore(),
      userId: 'me',
      run: run,
      probe: () async => !offline,
      retryEvery: const Duration(seconds: 1),
      syncedFor: const Duration(seconds: 2),
    );
  }

  final rows = <String, Map<String, dynamic>>{};
  late final Outbox outbox;

  /// Never contacted: item writes go through the outbox.
  final db = SupabaseClient(
    'http://127.0.0.1:9',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final awake = FakeAwake();
  var offline = false;

  Future<void> run(OutboxOp op) async {
    if (offline) throw http.ClientException('offline');
    switch (op.kind) {
      case OpKind.insert:
        rows.putIfAbsent(op.id!, () => {...op.data});
      case OpKind.update:
        final r = rows[op.id];
        if (r != null) rows[op.id!] = {...r, ...op.data};
      case OpKind.delete:
        rows.remove(op.id);
      case OpKind.clear:
        for (final id in op.ids) {
          if (rows[id]?['checked'] == true) rows.remove(id);
        }
    }
  }

  Stream<List<Item>> items() async* {
    List<Item> view() => outbox.apply(listId, rows.values.toList()).map(Item.fromJson).toList();
    yield view();
    await for (final _ in outbox.changes) {
      yield view();
    }
  }

  List<Object> get overrides => [
    outboxProvider.overrideWithValue(outbox),
    repositoryProvider.overrideWithValue(Repository(db, outbox: outbox)),
    itemsProvider.overrideWith((ref, id) => items()),
    listProvider.overrideWith(
      (ref, id) => ShoppingList(id: listId, name: 'Groceries', emoji: '🛒', ownerId: 'me', createdAt: DateTime(2026)),
    ),
    screenAwakeProvider.overrideWithValue(awake),
  ];
}

var _n = 0;
Map<String, dynamic> row(String name, String category, {bool checked = false, String? quantity}) => {
  'id': 'item-${_n++}',
  'list_id': listId,
  'name': name,
  'quantity': quantity,
  'category': category,
  'checked': checked,
  'checked_by': null,
  'recipe_id': null,
  'created_at': DateTime.utc(2026, 10, 5, 10, _n).toIso8601String(),
};

/// Pumps a home screen with a button that opens store mode, and opens it.
Future<ProviderContainer> openStoreMode(
  WidgetTester tester,
  World world, {
  Size size = const Size(412, 915),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: world.overrides.cast());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => const StoreModeScreen(listId: listId))),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> finish(WidgetTester tester, World world, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox());
  world.outbox.dispose();
  container.dispose();
  await tester.pump(const Duration(seconds: 15)); // let snackbar/settle timers run out
}

void main() {
  testWidgets('groups by aisle in store order, unchecked first, with progress', (tester) async {
    final world = World([
      row('Bread', 'Bakery'),
      row('Milk', 'Dairy & Eggs', quantity: '1 gal'),
      row('Bananas', 'Produce'),
      row('Coffee', 'Drinks', checked: true),
    ]);
    final container = await openStoreMode(tester, world);

    expect(find.text('1 of 4 in the cart'), findsOneWidget);
    final produce = tester.getTopLeft(find.textContaining('Produce')).dy;
    final dairy = tester.getTopLeft(find.textContaining('Dairy & Eggs')).dy;
    final bakery = tester.getTopLeft(find.textContaining('Bakery')).dy;
    expect(produce < dairy && dairy < bakery, isTrue);
    expect(find.text('1 gal'), findsOneWidget);
    // Checked items wait in a collapsed "In the cart" section.
    expect(find.text('🛒  In the cart (1)'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);

    expect(world.awake.calls, [true]);
    expect(container.read(isInStoreModeProvider(listId)), isTrue);
    await finish(tester, world, container);
  });

  testWidgets('tapping anywhere on a row checks it; it slides into the cart; undo puts it back', (tester) async {
    final world = World([row('Bananas', 'Produce'), row('Milk', 'Dairy & Eggs')]);
    final container = await openStoreMode(tester, world);
    final bananas = world.rows.values.firstWhere((r) => r['name'] == 'Bananas')['id'] as String;

    // Tap the far right of the row, not the text: the whole row is the target.
    final rowBox = tester.getRect(find.ancestor(of: find.text('Bananas'), matching: find.byType(InkWell)));
    await tester.tapAt(Offset(rowBox.right - 10, rowBox.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // Mid-animation: still on screen, sliding away; progress already counts it.
    expect(find.text('Bananas'), findsOneWidget);
    expect(find.text('1 of 2 in the cart'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('Bananas'), findsNothing); // gone from the to-get list (cart is collapsed)
    expect(find.text('🛒  In the cart (1)'), findsOneWidget);
    expect(world.rows[bananas]!['checked'], isTrue);
    expect(find.text('Bananas is in the cart'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(world.rows[bananas]!['checked'], isFalse);
    expect(find.text('Bananas'), findsOneWidget);
    expect(find.text('0 of 2 in the cart'), findsOneWidget);

    // Tapping an item in the (opened) cart also puts it back.
    await tester.tap(find.text('Milk'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🛒  In the cart (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Milk'));
    await tester.pumpAndSettle();
    expect(world.rows.values.every((r) => r['checked'] == false), isTrue);
    await finish(tester, world, container);
  });

  testWidgets('checking the last item makes Lamar dance; clear & finish leaves store mode', (tester) async {
    final world = World([row('Bananas', 'Produce'), row('Milk', 'Dairy & Eggs', checked: true)]);
    final container = await openStoreMode(tester, world);
    expect(find.byType(Lamar), findsNothing);

    await tester.tap(find.text('Bananas'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Lamar), findsNothing); // waits for the row to finish sliding away
    await tester.pumpAndSettle();
    expect(find.byType(Lamar), findsOneWidget);
    expect(find.text('Everything\'s in the cart!'), findsOneWidget);
    expect(find.text('2 of 2 in the cart'), findsOneWidget);

    await tester.tap(find.text('Clear the cart & finish'));
    await tester.pumpAndSettle();
    expect(world.rows, isEmpty);
    expect(find.text('open'), findsOneWidget); // back where we came from
    expect(world.awake.calls, [true, false]);
    await tester.pump();
    expect(container.read(isInStoreModeProvider(listId)), isFalse);
    await finish(tester, world, container);
  });

  testWidgets('"Something missing?" goes back to the list with the cart open', (tester) async {
    final world = World([row('Bananas', 'Produce', checked: true)]);
    final container = await openStoreMode(tester, world);
    expect(find.byType(Lamar), findsOneWidget);
    await tester.tap(find.text('Something missing? Keep shopping'));
    await tester.pumpAndSettle();
    expect(find.byType(Lamar), findsNothing);
    expect(find.text('Bananas'), findsOneWidget);
    await finish(tester, world, container);
  });

  testWidgets('offline: banner, pending marker, then "Synced ✓" on reconnect', (tester) async {
    final world = World([row('Bananas', 'Produce'), row('Milk', 'Dairy & Eggs')]);
    final container = await openStoreMode(tester, world);
    expect(find.byType(ConnectivityBanner), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);

    world.offline = true;
    world.outbox.setNetworkAvailable(false);
    await tester.pumpAndSettle();
    expect(find.text('Offline — Lamar will sync when you\'re back'), findsOneWidget);

    await tester.tap(find.text('Bananas'));
    await tester.pumpAndSettle();
    expect(find.text('Offline — Lamar will sync when you\'re back · 1 change waiting'), findsOneWidget);
    expect(find.text('1 of 2 in the cart'), findsOneWidget); // applied locally
    await tester.tap(find.text('🛒  In the cart (1)'));
    await tester.pumpAndSettle();
    expect(find.byType(PendingSyncIcon), findsOneWidget);
    expect(world.rows.values.every((r) => r['checked'] == false), isTrue); // not sent yet

    world.offline = false;
    world.outbox.setNetworkAvailable(true);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Synced ✓'), findsOneWidget);
    expect(find.byType(PendingSyncIcon), findsNothing);
    expect(world.rows.values.where((r) => r['checked'] == true), hasLength(1));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Synced ✓'), findsNothing);
    await finish(tester, world, container);
  });

  testWidgets('fits at 360×640 with text ×1.3: list, offline banner and celebration', (tester) async {
    final world = World([
      row('Extra-large free-range organic brown eggs from the farm stand', 'Dairy & Eggs', quantity: '2 dozen'),
      row('Bananas', 'Produce', quantity: '1 bunch'),
      for (var i = 0; i < 8; i++) row('Thing $i', 'Pantry'),
      row('Paper towels', 'Household', checked: true),
    ]);
    world.offline = true;
    world.outbox.setNetworkAvailable(false);
    final container = await openStoreMode(tester, world, size: const Size(360, 640), textScale: 1.3);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Offline'), findsOneWidget);

    // Check everything to reach the celebration.
    for (final r in world.rows.values.where((r) => r['checked'] == false).toList()) {
      await world.outbox.updateItem(listId, r['id'] as String, {'checked': true});
    }
    await tester.pumpAndSettle();
    expect(find.byType(Lamar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester, world, container);
  });

  testWidgets('shopping tab: "Switch to shopping view" button, offline markers, and clear works offline', (
    tester,
  ) async {
    final world = World([row('Bananas', 'Produce'), row('Milk', 'Dairy & Eggs', checked: true)]);
    final container = ProviderContainer(
      overrides: [
        ...world.overrides.cast(),
        membersProvider.overrideWith((ref, id) => Stream.value(const <Member>[])),
        recipesProvider.overrideWith((ref, id) => const AsyncData(<Recipe>[])),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: ShoppingTab(listId: listId)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Switch to shopping view'), findsOneWidget);
    expect(find.byType(PendingSyncIcon), findsNothing);

    world.offline = true;
    world.outbox.setNetworkAvailable(false);
    await tester.tap(find.byType(Checkbox).first); // check Bananas
    await tester.pumpAndSettle();
    expect(find.byType(PendingSyncIcon), findsOneWidget);
    expect(find.text('Switch to shopping view'), findsNothing); // nothing left to get

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Bananas'), findsNothing);
    expect(find.text('Milk'), findsNothing);
    expect(world.rows, hasLength(2)); // only queued so far

    world.offline = false;
    world.outbox.setNetworkAvailable(true);
    await tester.pumpAndSettle();
    expect(world.rows, isEmpty);
    await finish(tester, world, container);
  });

  testWidgets('shopping tab: tap checks off, swipe either way deletes, long-press edits', (tester) async {
    final world = World([
      row('Bananas', 'Produce'),
      row('Bread', 'Bakery'),
      row('Milk', 'Dairy & Eggs'),
      row('Eggs', 'Dairy & Eggs'),
    ]);
    final container = ProviderContainer(
      overrides: [
        ...world.overrides.cast(),
        membersProvider.overrideWith((ref, id) => Stream.value(const <Member>[])),
        recipesProvider.overrideWith((ref, id) => const AsyncData(<Recipe>[])),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: ShoppingTab(listId: listId)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    bool? checked(String name) => world.rows.values.where((r) => r['name'] == name).firstOrNull?['checked'] as bool?;

    await tester.tap(find.text('Bananas')); // the row, not just the checkbox
    await tester.pumpAndSettle();
    expect(checked('Bananas'), isTrue);

    await tester.timedDrag(find.text('Bread'), const Offset(600, 0), const Duration(milliseconds: 300)); // swipe right
    await tester.pumpAndSettle();
    expect(find.text('Bread'), findsNothing);
    expect(checked('Bread'), isNull);

    await tester.timedDrag(find.text('Milk'), const Offset(-600, 0), const Duration(milliseconds: 300)); // swipe left
    await tester.pumpAndSettle();
    expect(find.text('Milk'), findsNothing);
    expect(checked('Milk'), isNull);

    await tester.longPress(find.text('Eggs'));
    await tester.pumpAndSettle();
    expect(find.text('Edit item'), findsOneWidget);
    // The aisle picker shows where it is now.
    final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '🧀 Dairy & Eggs'));
    expect(chip.selected, isTrue);
    expect(find.byType(ChoiceChip), findsNWidgets(10));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(checked('Eggs'), isFalse);
    await finish(tester, world, container);
  });

  test('adding offline merges like add_item does, else queues a client-id item', () async {
    final world = World([row('Chicken thighs', 'Meat', quantity: '2 lb'), row('Milk', 'Dairy & Eggs', checked: true)]);
    final cache = RowCache(MemoryKeyValueStore(), userId: 'me')
      ..write('items|list_id|$listId', world.rows.values.toList());
    final repo = Repository(world.db, outbox: world.outbox, cache: cache);
    world.offline = true;
    world.outbox.setNetworkAvailable(false);

    final merged = await repo.addItem(listId, '1 lb chicken thigh');
    expect(merged.merged, isTrue);
    expect(merged.quantity, '3 lb');

    // Milk is only in the cart, so a new Milk is added (as the server would).
    final added = await repo.addItem(listId, 'Milk');
    expect(added.merged, isFalse);
    expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(added.id), isTrue);
    expect(world.outbox.apply(listId, world.rows.values.toList()).where((r) => r['name'] == 'Milk'), hasLength(2));

    // The client-made id works before sync: removing it cancels the add.
    await repo.deleteItem(added.id, listId: listId);
    expect(world.outbox.queued.map((o) => o.kind), [OpKind.update]);

    world.offline = false;
    world.outbox.setNetworkAvailable(true);
    await world.outbox.flush();
    expect(world.rows.values.firstWhere((r) => r['name'] == 'Chicken thighs')['quantity'], '3 lb');
    expect(world.rows, hasLength(2));

    // Meal/AI features say kindly that they need a connection.
    world.offline = true;
    world.outbox.setNetworkAvailable(false);
    await expectLater(
      repo.suggestIngredients(meal: 'Tacos', ingredients: const [], dismissed: const []),
      throwsA(isA<OfflineException>()),
    );
    expect(friendlyError(const OfflineException()), contains('needs a connection'));
    world.outbox.dispose();
    await world.db.dispose();
  });
}
