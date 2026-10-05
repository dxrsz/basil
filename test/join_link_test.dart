import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/features/join/join_link.dart';
import 'package:lamars_groceries/features/join/join_routing.dart';

void main() {
  group('joinCodeFromUri', () {
    final cases = <String, String?>{
      'https://lamarsgroceries.app/join/ABC234': 'ABC234',
      'https://lamarsgroceries.app/join/abc234': 'ABC234',
      'https://lamarsgroceries.app/join/ABC234/': 'ABC234',
      'https://www.lamarsgroceries.app/join/ABC234': 'ABC234',
      'http://lamarsgroceries.app/join/ABC234': 'ABC234',
      'https://lamarsgroceries.app/join/ABC234?utm_source=sms': 'ABC234',
      'lamarsgroceries://join/ABC234': 'ABC234',
      'lamarsgroceries:///join/ABC234': 'ABC234',
      '/join/ABC234': 'ABC234',
      // not ours / not a join link
      'lamarsgroceries://login-callback?code=xyz': null,
      'lamarsgroceries://login-callback': null,
      'https://evil.example/join/ABC234': null,
      'https://lamarsgroceries.app.evil.example/join/ABC234': null,
      'https://lamarsgroceries.app/': null,
      'https://lamarsgroceries.app/join/': null,
      'https://lamarsgroceries.app/join/ABC234/extra': null,
      'https://lamarsgroceries.app/lists/ABC234': null,
      'https://lamarsgroceries.app/join/AB': null,
      'https://lamarsgroceries.app/join/<script>': null,
      'mailto:join@lamarsgroceries.app': null,
    };
    cases.forEach((link, code) {
      test('$link → $code', () => expect(joinCodeFromUri(Uri.parse(link)), code));
    });
  });

  test('inviteLink round-trips', () {
    expect(inviteLink('ABC234'), 'https://lamarsgroceries.app/join/ABC234');
    expect(joinCodeFromUri(Uri.parse(inviteLink('ABC234'))), 'ABC234');
  });

  group('authRedirect', () {
    String? redirect(bool signedIn, String location) => authRedirect(signedIn: signedIn, location: Uri.parse(location));

    test('signed out: join links go to sign-in and remember where to come back to', () {
      expect(redirect(false, '/join/ABC234'), '/signin?from=%2Fjoin%2FABC234');
      expect(redirect(false, '/join/abc234'), '/signin?from=%2Fjoin%2FABC234');
    });

    test('signed out: everything else goes to plain sign-in', () {
      expect(redirect(false, '/'), '/signin');
      expect(redirect(false, '/lists/123'), '/signin');
      expect(redirect(false, '/signin'), isNull);
      expect(redirect(false, '/signin?from=%2Fjoin%2FABC234'), isNull);
    });

    test('signing in continues to the join link', () {
      expect(redirect(true, '/signin?from=%2Fjoin%2FABC234'), '/join/ABC234');
      expect(redirect(true, '/signin'), '/');
    });

    test('from can only point at a join link', () {
      expect(redirect(true, '/signin?from=https%3A%2F%2Fevil.example'), '/');
      expect(redirect(true, '/signin?from=%2Flists%2F123'), '/');
    });

    test('signed in: no redirect', () {
      expect(redirect(true, '/join/ABC234'), isNull);
      expect(redirect(true, '/'), isNull);
    });
  });
}
