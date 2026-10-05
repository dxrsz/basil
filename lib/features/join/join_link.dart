/// Invite links: `https://lamarsgroceries.app/join/<CODE>`.
///
/// The same path works on the web (Vercel serves the app for it), opens the
/// app via Android App Links / iOS Universal Links when installed, and
/// `lamarsgroceries://join/<CODE>` is accepted as a fallback.
library;

const inviteHost = 'lamarsgroceries.app';
const appScheme = 'lamarsgroceries';

/// Invite codes are 6 characters from an alphabet without 0/O/1/I; accept a
/// little slack (any case, 4–12 letters/digits) and let the server decide.
final _codePattern = RegExp(r'^[A-Za-z0-9]{4,12}$');

String inviteLink(String code) => 'https://$inviteHost/join/$code';

/// Normalises a typed or linked code, or null if it can't be one.
String? normalizeInviteCode(String raw) {
  final code = raw.trim().toUpperCase();
  return _codePattern.hasMatch(code) ? code : null;
}

/// The invite code in [uri] if it's a join link we handle, else null.
///
/// Accepts https/http links on our host (and www.), the custom scheme
/// (`lamarsgroceries://join/CODE`, where "join" parses as the host) and a
/// bare in-app path (`/join/CODE`).
String? joinCodeFromUri(Uri uri) {
  final List<String> segments;
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if (scheme == 'https' || scheme == 'http') {
    if (host != inviteHost && host != 'www.$inviteHost') return null;
    segments = uri.pathSegments;
  } else if (scheme == appScheme) {
    segments = [if (host.isNotEmpty) host, ...uri.pathSegments];
  } else if (scheme.isEmpty) {
    segments = uri.pathSegments;
  } else {
    return null;
  }
  final parts = segments.where((s) => s.isNotEmpty).toList();
  if (parts.length != 2 || parts[0].toLowerCase() != 'join') return null;
  return normalizeInviteCode(parts[1]);
}

/// The in-app route for a join link, or null if [uri] isn't one.
String? joinRouteFor(Uri uri) {
  final code = joinCodeFromUri(uri);
  return code == null ? null : '/join/$code';
}
