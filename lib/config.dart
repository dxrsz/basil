/// Build-time configuration, supplied with
/// `flutter run --dart-define-from-file=env.json` (see env.example.json).
class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// Must match the URL scheme registered in Info.plist / AndroidManifest.xml
  /// and the redirect allow-list in Supabase Auth.
  static const authRedirect = 'app.basil://login-callback';

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
}
