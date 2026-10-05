import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/util/categories.dart';

/// The same cases are run against the SQL copy of the rules
/// (public.categorize_item_rules) by tool/categories/check_rules.sh.
void main() {
  final cases = (jsonDecode(File('test/fixtures/category_cases.json').readAsStringSync()) as Map).cast<String, String>();
  for (final MapEntry(key: name, value: aisle) in cases.entries) {
    test('$name → $aisle', () => expect(categorize(name), aisle));
  }
}
