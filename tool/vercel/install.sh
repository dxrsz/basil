#!/usr/bin/env bash
# Vercel install step: Vercel's build image has no Flutter, so fetch a pinned
# SDK (matching .metadata / local dev) into the build cache directory.
set -euo pipefail
FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.6}"
DEST="${FLUTTER_HOME:-$PWD/.vercel/cache/flutter-$FLUTTER_VERSION}"

if [[ ! -x "$DEST/bin/flutter" ]]; then
  echo "Installing Flutter $FLUTTER_VERSION…"
  mkdir -p "$(dirname "$DEST")"
  url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  curl -fsSL "$url" | tar -xJ -C "$(dirname "$DEST")"
  mv "$(dirname "$DEST")/flutter" "$DEST"
fi
git config --global --add safe.directory "$DEST" || true
"$DEST/bin/flutter" --version
"$DEST/bin/flutter" config --no-analytics --enable-web >/dev/null
"$DEST/bin/flutter" pub get
