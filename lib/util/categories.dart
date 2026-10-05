/// Aisle grouping for list items. The keyword rules below mirror
/// `public.categorize_item_rules` (tool/categories/rules.sql).
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

// Mirrors public.categorize_item_rules in SQL (tool/categories/rules.sql):
// whole words, plural-tolerant, specific phrases first so "peanut butter"
// isn't dairy and "eggplant" isn't eggs. This is only the instant guess: the
// database then assigns the aisle from the list's own choice or the shared
// category cache. Both copies are checked against
// test/fixtures/category_cases.json.
final _rules = <(String, RegExp)>[
  ('Bakery', RegExp(r'\b(hot dog|hamburger|burger|slider) buns?\b')),
  ('Produce', RegExp(r'\bbutter lettuce\b')),
  ('Pantry', RegExp(r'\b(bread ?crumbs|croutons|noodles?|ramen|soups?)\b')),
  ('Pantry', RegExp(r'\b(powder|paste|sauce|extract|seasoning|spice blend|marinade|dressing|bouillon cubes?)\b')),
  ('Pantry', RegExp(r'\b(lemon|lime) juice\b')),
  ('Pantry', RegExp(r'\bvinegar\b')),
  ('Drinks', RegExp(r'\bjuices?\b')),
  ('Pantry', RegExp(r'\b(peanut|almond|cashew|sunflower|nut|apple|cookie) butter\b')),
  ('Pantry', RegExp(r'\b(broth|stock|bouillon|stocks)\b')),
  (
    'Pantry',
    RegExp(
      r'\b(corn ?starch|cornmeal|corn ?flour|black pepper|white pepper|peppercorns?|pepper flakes|tortilla chips?|potato chips?|coconut milk|canned)\b',
    ),
  ),
  ('Frozen', RegExp(r'\b(ice cream|gelato|sorbet|popsicles?|frozen)\b')),
  ('Dairy & Eggs', RegExp(r'\b(almond|oat|soy|rice|cashew) ?milks?\b')),
  (
    'Produce',
    RegExp(
      r'\b(eggplants?|butternut|bell peppers?|jalape(n|ñ)os?|chil(i|e|li)s?|chil(i|e) peppers?|green onions?|scallions?|spring onions?|tofu|tempeh|sweet potato(es)?)\b',
    ),
  ),
  (
    'Meat',
    RegExp(
      r'\b(chicken|beef|steaks?|pork|bacon|sausages?|turkey|lamb|ham|salami|prosciutto|pepperoni|chorizo|brisket|ribs?|mince|ground meat|hot dogs?|meatballs?|veal|duck)\b',
    ),
  ),
  (
    'Seafood',
    RegExp(
      r'\b(salmon|tuna|shrimps?|prawns?|cod|tilapia|fish|crabs?|lobsters?|scallops?|mussels?|clams?|halibut|anchov(y|ies)|sardines?|trout|oysters?)\b',
    ),
  ),
  (
    'Dairy & Eggs',
    RegExp(
      r'\b(milk|cheeses?|cheddar|mozzarella|parmesan|feta|ricotta|brie|yogh?urts?|butter|cream|creamer|eggs?|ghee|kefir|half and half|buttermilk)\b',
    ),
  ),
  (
    'Bakery',
    RegExp(
      r'\b(bread|buns?|bagels?|tortillas?|pitas?|naan|baguettes?|croissants?|rolls?|muffins?|sourdough|brioche|flatbreads?|wraps?|ciabatta)\b',
    ),
  ),
  (
    'Produce',
    RegExp(
      r'\b(apples?|bananas?|lemons?|limes?|oranges?|berry|berries|strawberr(y|ies)|blueberr(y|ies)|raspberr(y|ies)|grapes?|avocados?|tomato(es)?|onions?|garlic|potato(es)?|lettuce|spinach|kale|arugula|carrots?|cucumbers?|broccoli|cauliflower|cilantro|parsley|basil|mint|dill|thyme|rosemary|ginger|celery|mushrooms?|zucchinis?|squash|corn|cabbage|edamame|mangos?|mangoes|peach(es)?|pears?|plums?|pineapples?|melons?|watermelons?|cherr(y|ies)|kiwis?|herbs|leeks?|shallots?|radish(es)?|beets?|asparagus|peas|green beans|bok choy|fennel|artichokes?|grapefruits?|clementines?|tangerines?)\b',
    ),
  ),
  (
    'Pantry',
    RegExp(
      r'\b(rice|pasta|spaghetti|penne|noodles?|ramen|udon|quinoa|couscous|oats|oatmeal|flour|sugar|beans?|lentils?|chickpeas?|sauces?|oils?|vinegar|salt|spices?|cumin|paprika|cinnamon|oregano|soy sauce|honey|syrup|cereal|granola|nuts?|almonds|walnuts|pecans|cashews|peanuts|seeds?|salsa|mayo|mayonnaise|mustard|ketchup|sriracha|tahini|crackers?|chips|pretzels|popcorn|jam|jelly|olives?|pickles?|capers|baking soda|baking powder|yeast|vanilla|chocolate|cocoa|candy|cookies|breadcrumbs|panko|stuffing|bouillon|curry|miso|gochujang|harissa|pesto|hummus)\b',
    ),
  ),
  (
    'Drinks',
    RegExp(
      r'\b(water|juices?|soda|pop|coffee|tea|wine|beer|kombucha|seltzer|lemonade|cider|vodka|gin|rum|whiskey|tequila|sparkling)\b',
    ),
  ),
  (
    'Household',
    RegExp(
      r'\b(paper towels?|toilet paper|tissues?|napkins?|soap|detergent|foil|plastic wrap|cling film|bags?|sponges?|trash|garbage|bleach|cleaner|wipes|shampoo|conditioner|toothpaste|deodorant|batteries|light bulbs?|diapers?|litter|pet food|cat food|dog food|parchment)\b',
    ),
  ),
];

String categorize(String name) {
  final n = name.toLowerCase();
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
