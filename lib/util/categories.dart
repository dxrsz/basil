/// Aisle grouping for list items. Mirrors `public.categorize_item` in the
/// database migration; keep the two in sync.
const categoryOrder = [
  'Produce',
  'Meat',
  'Seafood',
  'Dairy & Eggs',
  'Bakery',
  'Pantry',
  'Frozen',
  'Drinks',
  'Household',
  'Other',
];

const categoryEmoji = {
  'Produce': '🥬',
  'Meat': '🥩',
  'Seafood': '🐟',
  'Dairy & Eggs': '🧀',
  'Bakery': '🥖',
  'Pantry': '🥫',
  'Frozen': '🧊',
  'Drinks': '🧃',
  'Household': '🧻',
  'Other': '🛍️',
};

final _rules = <(String, RegExp)>[
  ('Meat', RegExp(r'(chicken|beef|pork|steak|bacon|sausage|turkey|lamb|ham|salami|prosciutto|ground meat|mince)')),
  ('Seafood', RegExp(r'(salmon|tuna|shrimp|prawn|cod|tilapia|fish|crab|lobster|scallop|mussel|clam)')),
  ('Dairy & Eggs', RegExp(r'(milk|cheese|yogurt|yoghurt|butter|cream|egg|feta|parmesan|mozzarella|cheddar|ricotta)')),
  ('Bakery', RegExp(r'(bread|bun|bagel|tortilla|pita|naan|baguette|croissant|roll)')),
  ('Frozen', RegExp(r'(frozen|ice cream)')),
  ('Produce', RegExp(r'(apple|banana|lemon|lime|orange|berry|berries|avocado|tomato|onion|garlic|potato|lettuce|spinach|kale|carrot|pepper|cucumber|broccoli|cilantro|parsley|basil|mint|ginger|scallion|celery|mushroom|zucchini|corn|cabbage|edamame|mango|grape|herb|jalape)')),
  ('Pantry', RegExp(r'(rice|pasta|noodle|quinoa|oat|flour|sugar|bean|lentil|chickpea|can |canned|broth|stock|sauce|oil|vinegar|salt|spice|cumin|paprika|cinnamon|oregano|soy|honey|syrup|cereal|nut|seed|salsa|mayo|mustard|ketchup|sriracha|tahini|cracker|chip)')),
  ('Drinks', RegExp(r'(water|juice|soda|coffee|tea|wine|beer|kombucha|sparkling)')),
  ('Household', RegExp(r'(paper|towel|soap|detergent|foil|wrap|bag|sponge|trash|tissue)')),
];

String categorize(String name) {
  final n = ' ${name.toLowerCase()} ';
  for (final (category, re) in _rules) {
    if (re.hasMatch(n)) return category;
  }
  return 'Other';
}

final _qtyPattern = RegExp(
  r'^\s*((?:\d+(?:[./]\d+)?|½|¼|¾|a|an|one|two|three|four|five|six)\s*'
  r'(?:x\b|cups?\b|tbsp\b|tsp\b|lbs?\b|oz\b|g\b|kg\b|ml\b|l\b|cans?\b|jars?\b|bunch(?:es)?\b|bags?\b|boxes?\b|packs?\b|dozen\b|cloves?\b|heads?\b|bottles?\b|pints?\b|quarts?\b|gallons?\b)?)\s+(.+)$',
  caseSensitive: false,
);

/// Splits "2 lb chicken thighs" into (quantity: "2 lb", name: "chicken thighs").
({String name, String? quantity}) parseItemInput(String input) {
  final text = input.trim();
  final m = _qtyPattern.firstMatch(text);
  if (m == null) return (name: _capitalize(text), quantity: null);
  final qty = m.group(1)!.trim();
  // "a" / "an" alone aren't worth keeping as a quantity.
  final keepQty = !RegExp(r'^(a|an)$', caseSensitive: false).hasMatch(qty);
  return (name: _capitalize(m.group(2)!.trim()), quantity: keepQty ? qty : null);
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
