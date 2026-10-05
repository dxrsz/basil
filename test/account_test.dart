import 'package:flutter_test/flutter_test.dart';
import 'package:lamars_groceries/data/account_repository.dart';
import 'package:lamars_groceries/data/repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

UserIdentity _identity(String provider, String? lastSignIn) => UserIdentity(
  id: provider,
  userId: 'u',
  identityId: provider,
  identityData: const {},
  provider: provider,
  lastSignInAt: lastSignIn,
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);

void main() {
  test('the most recently used identity owns the provider token', () {
    expect(
      latestIdentityProvider([
        _identity('google', '2026-10-01T10:00:00Z'),
        _identity('apple', '2026-10-05T09:00:00Z'),
      ]),
      'apple',
    );
    expect(
      latestIdentityProvider([_identity('apple', '2026-10-01T10:00:00Z'), _identity('google', '2026-10-05T09:00:00Z')]),
      'google',
    );
    expect(latestIdentityProvider([_identity('apple', null)]), isNull);
    expect(latestIdentityProvider(const []), isNull);
  });

  test('profile reads AI consent as yes / no / never asked', () {
    expect(MyProfile.fromRow({'display_name': 'Evan', 'ai_consent': 'granted'}).aiConsent, isTrue);
    expect(MyProfile.fromRow({'display_name': 'Evan', 'ai_consent': 'declined'}).aiConsent, isFalse);
    expect(MyProfile.fromRow({'display_name': null, 'ai_consent': null}).aiConsent, isNull);
    expect(MyProfile.fromRow({'display_name': null}).displayName, '');
  });

  test('the server refusing AI without consent reads as a pointer to Account', () {
    const e = FunctionException(status: 403, details: {'error': aiConsentRequired});
    expect(isAiConsentRequired(e), isTrue);
    expect(friendlyError(e), contains('Account'));
    expect(isAiConsentRequired(const FunctionException(status: 429, details: {'error': 'slow down'})), isFalse);
  });
}
