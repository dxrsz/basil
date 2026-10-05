import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Whether this user is in store mode ("I'm at the store") for a list.
///
/// Hook for presence: listen to this to tell the other people on the list
/// that someone is shopping, e.g.
///
/// ```dart
/// ref.listen(isInStoreModeProvider(listId), (_, shopping) => presence.setShopping(listId, shopping));
/// ```
class StoreModeNotifier extends Notifier<bool> {
  StoreModeNotifier(this.listId);

  final String listId;

  @override
  bool build() => false;

  void enter() => state = true;

  void exit() => state = false;
}

final isInStoreModeProvider = NotifierProvider.family<StoreModeNotifier, bool, String>(StoreModeNotifier.new);

/// Keeps the screen on (so it doesn't lock between aisles).
class ScreenAwake {
  const ScreenAwake();

  Future<void> set(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('wakelock: $e'); // not fatal: the screen just may dim
    }
  }
}

final screenAwakeProvider = Provider<ScreenAwake>((ref) => const ScreenAwake());
