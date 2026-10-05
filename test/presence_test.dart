import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/providers.dart';
import 'package:lamars_groceries/data/sharing_repository.dart';
import 'package:lamars_groceries/features/presence/presence.dart';
import 'package:lamars_groceries/features/presence/presence_bar.dart';
import 'package:lamars_groceries/models/models.dart';
import 'package:lamars_groceries/theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Member member(String id, String name) => Member(userId: id, role: 'editor', displayName: name, avatarUrl: null);

class _FakePresence extends ListPresenceController {
  _FakePresence(super.listId, this.initial);

  final ListPresence initial;

  @override
  ListPresence build() => initial;
}

class _FakeSharing extends SharingRepository {
  _FakeSharing(super.db);

  final announced = <String>[];

  @override
  Future<void> announceShopping(String listId) async => announced.add(listId);
}

void main() {
  group('parsePresence', () {
    test('one entry per person, excluding me, shoppers first', () {
      final users = parsePresence([
        {'user_id': 'me', 'shopping': true},
        {'user_id': 'b', 'shopping': false},
        {'user_id': 'a', 'shopping': false},
        {'user_id': 'c', 'shopping': true},
        {'user_id': 'b', 'shopping': false}, // b's second device
      ], me: 'me');
      expect(users, [
        const PresentUser(userId: 'c', shopping: true),
        const PresentUser(userId: 'a', shopping: false),
        const PresentUser(userId: 'b', shopping: false),
      ]);
    });

    test('shopping on any device counts', () {
      final users = parsePresence([
        {'user_id': 'a', 'shopping': false},
        {'user_id': 'a', 'shopping': true},
      ]);
      expect(users, [const PresentUser(userId: 'a', shopping: true)]);
    });

    test('ignores malformed payloads', () {
      final users = parsePresence([
        {'shopping': true},
        {'user_id': 42},
        {'user_id': ''},
        {'user_id': 'a', 'shopping': 'yes'},
      ]);
      expect(users, [const PresentUser(userId: 'a', shopping: false)]);
    });

    test('topic is per list', () => expect(presenceTopic('L1'), 'presence:list:L1'));
  });

  test('lines read naturally', () {
    final sam = member('s', 'Sam Smith'), alex = member('a', 'Alex'), kit = member('k', 'Kit');
    expect(shoppingLine([sam]), 'Sam is at the store 🛒');
    expect(shoppingLine([sam, alex]), 'Sam and Alex are at the store 🛒');
    expect(shoppingLine([sam, alex, kit]), 'Sam and 2 others are at the store 🛒');
    expect(hereLine([sam]), 'Sam is here too');
    expect(hereLine([sam, alex]), 'Sam and Alex are here too');
    expect(hereLine([sam, alex, kit]), '3 others are here too');
  });

  group('ShoppingNow', () {
    test('marks lists and announces only when starting', () {
      final db = SupabaseClient('http://localhost:1', 'test-key');
      addTearDown(db.dispose);
      final sharing = _FakeSharing(db);
      final container = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue('me'),
          sharingRepositoryProvider.overrideWithValue(sharing),
        ],
      );
      addTearDown(container.dispose);
      final shopping = container.read(shoppingNowProvider.notifier);

      shopping.setShopping('L1', true);
      shopping.setShopping('L1', true); // no-op
      expect(container.read(shoppingNowProvider), {'L1'});
      shopping.setShopping('L1', false);
      expect(container.read(shoppingNowProvider), isEmpty);
      expect(sharing.announced, ['L1']);
    });
  });

  group('PresenceBar', () {
    final members = [member('me', 'Me'), member('s', 'Sam'), member('a', 'Alex')];

    Widget app(ListPresence presence, {double textScale = 1}) => ProviderScope(
      overrides: [
        listPresenceProvider('L1').overrideWith(() => _FakePresence('L1', presence)),
        membersProvider('L1').overrideWith((ref) => Stream.value(members)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(
          body: Column(
            children: [
              PresenceBar(listId: 'L1'),
              Expanded(child: Placeholder()),
            ],
          ),
        ),
      ),
    );

    testWidgets('alone: takes no space', (tester) async {
      await tester.pumpWidget(app(const ListPresence()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('presence-bar')), findsNothing);
      expect(tester.getSize(find.byType(PresenceBar)).height, 0);
    });

    testWidgets('someone else here', (tester) async {
      await tester.pumpWidget(app(const ListPresence([PresentUser(userId: 'a', shopping: false)])));
      await tester.pumpAndSettle();
      expect(find.text('Alex is here too'), findsOneWidget);
    });

    testWidgets('someone at the store is highlighted', (tester) async {
      await tester.pumpWidget(
        app(const ListPresence([PresentUser(userId: 's', shopping: true), PresentUser(userId: 'a', shopping: false)])),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sam is at the store 🛒'), findsOneWidget);
    });

    testWidgets('unknown (non-member) presences are not shown', (tester) async {
      await tester.pumpWidget(app(const ListPresence([PresentUser(userId: 'stranger', shopping: true)])));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('presence-bar')), findsNothing);
    });

    for (final (size, textScale) in [(const Size(360, 640), 1.3), (const Size(412, 915), 1.0)]) {
      testWidgets('fits at $size, text ×$textScale', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          app(
            const ListPresence([
              PresentUser(userId: 's', shopping: true),
              PresentUser(userId: 'a', shopping: true),
              PresentUser(userId: 'me', shopping: false),
            ]),
            textScale: textScale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('at the store'), findsOneWidget);
      });
    }
  });
}
