#!/usr/bin/env bash
# Builds Elixir from the upstream repository at one pinned revision, for
# toolchain qualification (see upstream-1.21-648b2a9.md in this directory).
#
#     bench/corpus/toolchain/build_elixir.sh REV DEST
#
# REV is a full 40-character commit SHA. DEST must not exist or be an empty
# directory. The script fetches only REV (a shallow fetch by SHA), checks it
# out detached, verifies HEAD, builds with `make compile` using the `erl` on
# PATH, and prints the build identity (identity.exs) as JSON on stdout.
# SOURCE_DATE_EPOCH is set to the commit time, so `System.build_info()[:date]`
# and therefore the System module do not depend on when the build ran.
#
# Environment:
#   ELIXIR_REPO          source repository (default the upstream GitHub URL)
#   SPEC_LINT_OTP_RELEASE required OTP major release (default 28)
#
# Runs under bash 3.2 and later. Needs git, make and Erlang/OTP.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 REV DEST" >&2
  exit 2
fi
rev="$1"
dest="$2"
repo="${ELIXIR_REPO:-https://github.com/elixir-lang/elixir.git}"
otp_required="${SPEC_LINT_OTP_RELEASE:-28}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$rev" in
  *[!0-9a-f]*) echo "REV must be a full lowercase 40-character SHA: $rev" >&2; exit 2 ;;
esac
[ "${#rev}" -eq 40 ] || { echo "REV must be a full 40-character SHA: $rev" >&2; exit 2; }
if [ -e "$dest" ] && [ -n "$(ls -A "$dest")" ]; then
  echo "DEST exists and is not empty: $dest" >&2
  exit 2
fi
for tool in git make erl; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

otp_release="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
if [ "$otp_release" != "$otp_required" ]; then
  echo "OTP $otp_required is required, erl on PATH is OTP $otp_release" >&2
  exit 2
fi

mkdir -p "$dest"
git -C "$dest" init --quiet
git -C "$dest" remote add origin "$repo"
git -C "$dest" fetch --quiet --depth 1 origin "$rev"
git -C "$dest" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
head="$(git -C "$dest" rev-parse HEAD)"
if [ "$head" != "$rev" ]; then
  echo "checked out $head, expected $rev" >&2
  exit 2
fi

SOURCE_DATE_EPOCH="$(git -C "$dest" log -1 --format=%ct HEAD)"
export SOURCE_DATE_EPOCH
echo "building $rev in $dest (OTP $otp_release, SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)" >&2
make -C "$dest" compile >&2

if [ -n "$(git -C "$dest" status --porcelain)" ]; then
  echo "the build modified tracked or unignored files in $dest" >&2
  git -C "$dest" status --porcelain >&2
  exit 2
fi

"$dest/bin/elixir" "$here/identity.exs"
