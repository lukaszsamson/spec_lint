#!/usr/bin/env bash
# Fresh Linux qualification inputs; never changes adapter digest pins.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 1.20.4|c24c235|648b2a9 EMPTY_DEST" >&2; exit 2; }
kind="$1" dest="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$kind" in
  1.20.4)
    [ ! -e "$dest" ] || { echo "destination already exists: $dest" >&2; exit 2; }
    mkdir -p "$dest"
    # This is the exact release archive audited in audit-1.20.4.md;
    # using the otp-28 archive would introduce a different compiler build.
    curl --fail --location --retry 3 https://builds.hex.pm/builds/elixir/v1.20.4-otp-29.zip -o "$dest/release.zip"
    unzip -q "$dest/release.zip" -d "$dest"
    rm "$dest/release.zip"
    "$dest/bin/elixir" "$here/identity.exs"
    ;;
  c24c235)
    ELIXIR_REPO=https://github.com/lukaszsamson/elixir.git \
      "$here/build_elixir.sh" c24c23538d521d25edd6a9a7a66fc5206caab70e "$dest"
    ;;
  648b2a9)
    "$here/build_elixir.sh" 648b2a94934664cfd2c788348d02d799c68faa69 "$dest"
    ;;
  *) echo "unknown compiler: $kind" >&2; exit 2 ;;
esac
