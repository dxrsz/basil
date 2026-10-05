import '../../models/models.dart';
import '../../util/item_merge.dart';

/// Exact duplicates among the unchecked items (same name ignoring case,
/// spacing and plurals), e.g. left over from before items merged on add.
/// These need no AI: the oldest one is kept and the quantities combined.
List<TidyProposal> exactDuplicateProposals(List<Item> items) {
  final groups = <String, List<Item>>{};
  final todo = items.where((i) => !i.checked).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  for (final i in todo) {
    final key = normalizeItemName(i.name);
    if (key.isNotEmpty) (groups[key] ??= []).add(i);
  }
  return [
    for (final g in groups.values)
      if (g.length > 1)
        TidyProposal(
          kind: 'merge',
          itemIds: [for (final i in g) i.id],
          name: g.first.name,
          quantity: g.skip(1).fold(g.first.quantity, (q, i) => combineQuantities(q, i.quantity)),
          reason: 'On the list ${g.length == 2 ? 'twice' : '${g.length} times'}',
        ),
  ];
}

/// Puts [local] proposals first, then the AI's, dropping any AI proposal
/// that touches an item already covered or no longer on the list.
List<TidyProposal> combineProposals(List<TidyProposal> local, List<TidyProposal> ai, List<Item> items) {
  final open = {
    for (final i in items)
      if (!i.checked) i.id,
  };
  final used = {for (final p in local) ...p.itemIds};
  final out = [...local];
  for (final p in ai) {
    if (p.itemIds.any((id) => used.contains(id) || !open.contains(id))) continue;
    used.addAll(p.itemIds);
    out.add(p);
  }
  return out;
}
