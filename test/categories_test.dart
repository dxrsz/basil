import 'package:basil/util/categories.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseItemInput', () {
    test('splits a leading quantity and unit', () {
      final r = parseItemInput('2 lb chicken thighs');
      expect(r.name, 'Chicken thighs');
      expect(r.quantity, '2 lb');
    });

    test('handles bare counts', () {
      final r = parseItemInput('3 avocados');
      expect(r.name, 'Avocados');
      expect(r.quantity, '3');
    });

    test('drops "a" as a quantity', () {
      final r = parseItemInput('a bunch cilantro');
      expect(r.name, 'Cilantro');
      expect(r.quantity, 'a bunch');
    });

    test('leaves plain names alone', () {
      final r = parseItemInput('jasmine rice');
      expect(r.name, 'Jasmine rice');
      expect(r.quantity, isNull);
    });
  });

  group('categorize', () {
    test('groups common items by aisle', () {
      expect(categorize('Salmon fillets'), 'Seafood');
      expect(categorize('Jasmine rice'), 'Pantry');
      expect(categorize('Avocado'), 'Produce');
      expect(categorize('Greek yogurt'), 'Dairy & Eggs');
      expect(categorize('Flour tortillas'), 'Bakery');
      expect(categorize('Mystery thing'), 'Other');
    });
  });
}
