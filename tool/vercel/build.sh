#!/usr/bin/env bash
# Vercel build step: builds the Flutter web app into build/web.
# Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in the Vercel project's
# environment variables (both are public; never add the service-role key).
set -euo pipefail
FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.6}"
FLUTTER="${FLUTTER_HOME:-$PWD/.vercel/cache/flutter-$FLUTTER_VERSION}/bin/flutter"

: "${SUPABASE_URL:?Set SUPABASE_URL in Vercel → Settings → Environment Variables}"
: "${SUPABASE_PUBLISHABLE_KEY:?Set SUPABASE_PUBLISHABLE_KEY in Vercel → Settings → Environment Variables}"
printf '{"SUPABASE_URL": "%s", "SUPABASE_PUBLISHABLE_KEY": "%s"}\n' "$SUPABASE_URL" "$SUPABASE_PUBLISHABLE_KEY" > env.json

"$FLUTTER" build web --release --dart-define-from-file=env.json
