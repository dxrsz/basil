/// Deterministic duplicate detection and quantity merging for list items.
///
/// Mirrors `public.normalize_item_name` and `public.combine_quantities` in
/// `supabase/migrations/20261005110000_pantry_and_tidy.sql`; keep the two in
/// sync. Shared test vectors live in `test/fixtures/item_merge_cases.json` and
/// are checked against both (see `tool/pantry_tidy_check.dart`).
library;

/// A comparison key for item names: case-, whitespace-, punctuation- and
/// plural-insensitive. "Avocados" and " avocado " both become "avocado".
String normalizeItemName(String name) {
  final lower = name.toLowerCase();
  final folded = StringBuffer();
  for (final ch in lower.split('')) {
    final i = _accented.indexOf(ch);
    folded.write(i < 0 ? ch : _plain[i]);
  }
  final words = folded.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim().split(' ').where((w) => w.isNotEmpty);
  return words.map(_singular).join(' ');
}

// Common accents folded so "jalapeño" matches "jalapeno". Same table as the SQL translate().
const _accented = 'áàâäãåéèêëíìîïóòôöõúùûüñçœ';
const _plain = 'aaaaaaeeeeiiiiooooouuuunco';

String _singular(String w) {
  if (w.length <= 3) return w;
  if (w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  if (w.endsWith('oes')) return w.substring(0, w.length - 2);
  if (RegExp(r'(ch|sh|x|ss)es$').hasMatch(w)) return w.substring(0, w.length - 2);
  if (RegExp(r'(ss|us|is)$').hasMatch(w)) return w;
  if (w.endsWith('s')) return w.substring(0, w.length - 1);
  return w;
}

// ------------------------------------------------------------ quantities

const _wordNumbers = {
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'twelve': 12,
};

const _glyphs = {'½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3};

/// Unit spellings that mean the same thing. Anything else is keyed by its
/// singular form ("cans" → "can"), so "1 can" + "2 cans" still combine.
const _unitAliases = {
  'cup': 'cup',
  'cups': 'cup',
  'tablespoon': 'tbsp',
  'tablespoons': 'tbsp',
  'tbsp': 'tbsp',
  'tbsps': 'tbsp',
  'tbs': 'tbsp',
  'teaspoon': 'tsp',
  'teaspoons': 'tsp',
  'tsp': 'tsp',
  'tsps': 'tsp',
  'pound': 'lb',
  'pounds': 'lb',
  'lb': 'lb',
  'lbs': 'lb',
  'ounce': 'oz',
  'ounces': 'oz',
  'oz': 'oz',
  'gram': 'g',
  'grams': 'g',
  'g': 'g',
  'kilogram': 'kg',
  'kilograms': 'kg',
  'kg': 'kg',
  'kgs': 'kg',
  'ml': 'ml',
  'milliliter': 'ml',
  'milliliters': 'ml',
  'l': 'l',
  'liter': 'l',
  'liters': 'l',
  'litre': 'l',
  'litres': 'l',
  // Plain counts: "2x" is just "2".
  'x': '',
  'ct': '',
  'count': '',
};

/// Units that read the same in the singular and plural.
const _invariantUnits = {
  '',
  'tbsp',
  'tsp',
  'lb',
  'oz',
  'g',
  'kg',
  'ml',
  'l',
  'dozen',
  'large',
  'medium',
  'small',
  'whole',
};

final _numericTerm = RegExp(r'^(\d+\s+\d+/\d+|\d+/\d+|\d*\.\d+|\d+\s*[½¼¾⅓⅔]?|[½¼¾⅓⅔])\s*([a-z].*)?$');

/// One "+"-separated piece of a quantity: either an amount with a unit
/// (unit key "" for a plain count) or opaque text like "to taste".
class _Term {
  _Term.amount(this.value, this.unit) : text = null;
  _Term.opaque(this.text) : value = 0, unit = null;

  double value;
  final String? unit; // null for opaque terms
  final String? text;

  String format() {
    if (unit == null) return text!;
    final n = formatAmount(value);
    if (unit!.isEmpty) return n;
    return '$n ${value > 1 ? _plural(unit!) : unit}';
  }
}

double? _parseNumber(String s) {
  s = s.trim();
  final mixed = RegExp(r'^(\d+)\s+(\d+)/(\d+)$').firstMatch(s);
  if (mixed != null) {
    final den = int.parse(mixed.group(3)!);
    if (den == 0) return null;
    return int.parse(mixed.group(1)!) + int.parse(mixed.group(2)!) / den;
  }
  final frac = RegExp(r'^(\d+)/(\d+)$').firstMatch(s);
  if (frac != null) {
    final den = int.parse(frac.group(2)!);
    if (den == 0) return null;
    return int.parse(frac.group(1)!) / den;
  }
  final glyph = RegExp(r'^(\d*)\s*([½¼¾⅓⅔])$').firstMatch(s);
  if (glyph != null) {
    final whole = glyph.group(1)!.isEmpty ? 0 : int.parse(glyph.group(1)!);
    return whole + _glyphs[glyph.group(2)!]!;
  }
  return double.tryParse(s);
}

String _unitKey(String unit) {
  final u = unit.trim().replaceAll(RegExp(r'\.$'), '');
  return _unitAliases[u] ?? normalizeItemName(u);
}

String _plural(String unit) {
  if (_invariantUnits.contains(unit) || !RegExp(r'[a-z]$').hasMatch(unit)) return unit;
  if (RegExp(r'(ch|sh|x|s)$').hasMatch(unit)) return '${unit}es';
  if (RegExp(r'[^aeiou]y$').hasMatch(unit)) return '${unit.substring(0, unit.length - 1)}ies';
  return '${unit}s';
}

_Term _parseTerm(String raw) {
  final text = raw.trim();
  var t = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final word = RegExp(r'^([a-z]+)(?: |$)').firstMatch(t);
  if (word != null && _wordNumbers.containsKey(word.group(1))) {
    t = '${_wordNumbers[word.group(1)]}${t.substring(word.group(1)!.length)}';
  }
  final m = _numericTerm.firstMatch(t);
  if (m == null) return _Term.opaque(text);
  final value = _parseNumber(m.group(1)!);
  if (value == null) return _Term.opaque(text);
  return _Term.amount(value, _unitKey(m.group(2) ?? ''));
}

List<_Term> _terms(String q) => q.split('+').map((s) => s.trim()).where((s) => s.isNotEmpty).map(_parseTerm).toList();

/// Formats an amount for a shopping list: whole numbers plainly, common
/// fractions as glyphs ("1½"), anything else to at most two decimals.
String formatAmount(double v) {
  final rounded = (v * 100).round() / 100;
  if ((v - v.round()).abs() < 0.005) return '${v.round()}';
  final whole = v.floor();
  final frac = v - whole;
  for (final MapEntry(key: glyph, value: f) in _glyphs.entries) {
    if ((frac - f).abs() < 0.01) return whole == 0 ? glyph : '$whole$glyph';
  }
  var s = rounded.toStringAsFixed(2);
  s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return s;
}

/// Combines two quantities for the same item.
///
/// Amounts in the same unit add up ("2 cups" + "1 cup" → "3 cups"); anything
/// else is kept side by side ("1 bunch" + "2" → "1 bunch + 2"). A missing
/// quantity contributes nothing.
String? combineQuantities(String? existing, String? added) {
  final a = existing?.trim() ?? '';
  final b = added?.trim() ?? '';
  if (b.isEmpty) return a.isEmpty ? null : a;
  if (a.isEmpty) return b;

  final terms = _terms(a);
  for (final t in _terms(b)) {
    if (t.unit == null) {
      if (!terms.any((e) => e.unit == null && e.text!.toLowerCase() == t.text!.toLowerCase())) terms.add(t);
      continue;
    }
    final same = terms.where((e) => e.unit == t.unit).firstOrNull;
    if (same != null) {
      same.value += t.value;
    } else {
      terms.add(t);
    }
  }
  return terms.map((t) => t.format()).join(' + ');
}
