import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/planner_repository.dart';
import 'planner_models.dart';

enum CardStatus { proposed, working, kept }

/// One night of the week being planned.
class PlanCard {
  const PlanCard({required this.idea, this.status = CardStatus.proposed, this.recipeId, this.passed = const []});

  final MealIdea idea;
  final CardStatus status;

  /// Set once kept: the saved meal on the list.
  final String? recipeId;

  /// Ideas already swapped away from this night, so they don't come back.
  final List<String> passed;

  PlanCard copyWith({MealIdea? idea, CardStatus? status, String? recipeId, List<String>? passed}) => PlanCard(
    idea: idea ?? this.idea,
    status: status ?? this.status,
    recipeId: recipeId ?? this.recipeId,
    passed: passed ?? this.passed,
  );
}

class PlannerState {
  const PlannerState({this.loading = false, this.summary, this.cards = const []});

  final bool loading;
  final String? summary;
  final List<PlanCard> cards;

  bool get hasPlan => cards.isNotEmpty;
  List<PlanCard> get kept => cards.where((c) => c.status == CardStatus.kept).toList();

  PlannerState copyWith({bool? loading, String? summary, List<PlanCard>? cards}) =>
      PlannerState(loading: loading ?? this.loading, summary: summary ?? this.summary, cards: cards ?? this.cards);
}

/// This week's plan for one list. Lives for the app session, so stepping into
/// a kept meal and back doesn't lose the rest of the plan.
final plannerProvider = NotifierProvider.family<PlannerController, PlannerState, String>(PlannerController.new);

class PlannerController extends Notifier<PlannerState> {
  PlannerController(this.listId);

  final String listId;

  PlannerRepository get _repo => ref.read(plannerRepositoryProvider);

  @override
  PlannerState build() => const PlannerState();

  List<MealIdea> get _week => [for (final c in state.cards) c.idea];

  void _replace(int index, PlanCard card) {
    if (index >= state.cards.length) return; // the plan was replaced meanwhile
    final cards = [...state.cards];
    cards[index] = card;
    state = state.copyWith(cards: cards);
  }

  /// Asks Lamar for a fresh week. Throws (leaving the old plan) on failure.
  Future<void> planWeek() async {
    state = state.copyWith(loading: true);
    try {
      final plan = await _repo.planWeek(listId);
      state = PlannerState(
        summary: plan.summary,
        cards: [for (final m in plan.meals) PlanCard(idea: m)],
      );
    } finally {
      if (state.loading) state = state.copyWith(loading: false);
    }
  }

  Future<void> swap(int index) => _rework(index, (card) async {
    final plan = await _repo.swap(listId, _week, index, avoid: card.passed);
    await _repo.logEvent(listId, MealEventKind.swapped, card.idea.name);
    return plan;
  });

  Future<void> nudge(int index, String nudge) => _rework(index, (card) async {
    final plan = await _repo.nudge(listId, _week, index, nudge);
    await _repo.logEvent(listId, MealEventKind.nudged, card.idea.name, detail: nudge);
    return plan;
  });

  Future<void> _rework(int index, Future<MealPlan> Function(PlanCard card) fetch) async {
    final card = state.cards[index];
    if (card.status != CardStatus.proposed) return;
    _replace(index, card.copyWith(status: CardStatus.working));
    try {
      final plan = await fetch(card);
      final idea = plan.meals.first;
      final notes = plan.weekNotes;
      final cards = [...state.cards];
      if (index >= cards.length) return; // the plan was replaced meanwhile
      // The server keeps the night; fall back to the old one just in case.
      cards[index] = PlanCard(
        idea: idea.withNote(idea.reuseNote, day: idea.day ?? card.idea.day),
        passed: [...card.passed, card.idea.name],
      );
      // What the other nights share may have changed with this one.
      if (notes != null && notes.length == cards.length) {
        for (var i = 0; i < cards.length; i++) {
          if (i != index) cards[i] = cards[i].copyWith(idea: cards[i].idea.withNote(notes[i]));
        }
      }
      state = state.copyWith(cards: cards);
    } catch (_) {
      _replace(index, card);
      rethrow;
    }
  }

  /// Saves the idea as a meal on the list (and only now asks for its photo).
  Future<String> keep(int index) async {
    final card = state.cards[index];
    if (card.status == CardStatus.kept) return card.recipeId!;
    _replace(index, card.copyWith(status: CardStatus.working));
    try {
      final id = await _repo.keepMeal(listId, card.idea, detail: card.idea.day);
      _replace(index, card.copyWith(status: CardStatus.kept, recipeId: id));
      return id;
    } catch (_) {
      _replace(index, card);
      rethrow;
    }
  }

  void clear() => state = const PlannerState();
}
