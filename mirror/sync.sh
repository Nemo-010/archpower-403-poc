#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
#
# Publish one ArchPOWER repository/architecture as an OCI artifact.
#
#   sync.sh <repo> <arch>
#
# The artifact is ghcr.io/<NS>/archpower-<repo>:<arch>. It holds the two
# databases, every package in the download closure, each package's detached
# signature, and index.tsv mapping url-path to filename, sha256 and size.
#
# Env:
#   NS          registry namespace               (required)
#   ORIGIN      upstream base URL                (default: https://repo.archlinuxpower.org)
#   PACKAGES    packages to close over           (default: base archpower-keyring)
#   STAGE       working directory                (default: ./stage)
#   MAX_FILES   stop after N packages, for a slice of a larger repository
#   SKIP_FETCH  reuse packages already in STAGE  (databases are always refetched)
#   PUSH=0      build the artifact without pushing it
#   CHROME_UA, CHROME_WAIT  pass through to the client
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
REPO="${1:?usage: sync.sh <repo> <arch>}"
ARCH="${2:?usage: sync.sh <repo> <arch>}"
NS="${NS:?set NS to the registry namespace}"
ORIGIN="${ORIGIN:-https://repo.archlinuxpower.org}"
PACKAGES="${PACKAGES:-base archpower-keyring}"
STAGE="${STAGE:-$PWD/stage}"
MAX_FILES="${MAX_FILES:-0}"
KEYRING="${KEYRING:-$HERE/keys/archpower.gpg}"
TRUSTED="${TRUSTED:-$HERE/keys/archpower-trusted}"
NAME="archpower-$REPO"
REF="ghcr.io/$NS/$NAME:$ARCH"

say() { printf '%s\n' "$*" >&2; }
die() { say "sync: $*"; exit 1; }

dir="$STAGE/$REPO/$ARCH"
mkdir -p "$dir"

# --- retrieve ----------------------------------------------------------------
fetch() { # <remote-path> <dest>
  local path="$1" dest="$2"
  if [ "${SKIP_FETCH:-0}" != "0" ] && [ -s "$dest" ]; then return 0; fi
  node "$REPO_ROOT/fetchers/chromium_fetch.mjs" "$ORIGIN/$path" "$dest" "$ORIGIN/$REPO/$ARCH/"
}

# --- signature check ---------------------------------------------------------
GPGHOME="$STAGE/gnupg"
mkdir -p "$GPGHOME"
chmod 700 "$GPGHOME"
gpg --batch --quiet --homedir "$GPGHOME" --import "$KEYRING" >/dev/null 2>&1 \
  || die "cannot import $KEYRING"

verify_sig() { # <file>
  local f="$1" status fp
  status="$(gpg --batch --homedir "$GPGHOME" --status-fd 1 --verify "$f.sig" "$f" 2>/dev/null)" \
    || { say "bad signature: $(basename "$f")"; return 1; }
  echo "$status" | grep -q '^\[GNUPG:\] GOODSIG' || { say "no GOODSIG: $(basename "$f")"; return 1; }
  fp="$(echo "$status" | awk '/VALIDSIG/{print $3; exit}')"
  grep -qi "^$fp:" "$TRUSTED" || { say "signer $fp is not on the trusted list: $(basename "$f")"; return 1; }
}

# --- databases ---------------------------------------------------------------
for path in "$REPO/$ARCH/$REPO.db" "$REPO/any/$REPO-any.db"; do
  db="$(basename "$path")"
  rm -f "$STAGE/$db" "$STAGE/$db.sig"
  if fetch "$path" "$STAGE/$db" 2>/dev/null; then
    fetch "$path.sig" "$STAGE/$db.sig" 2>/dev/null || true
    say "retrieved $path ($(wc -c < "$STAGE/$db") bytes)"
  else
    say "no $path"
    rm -f "$STAGE/$db"
  fi
done

# The databases are what pacman -Sy retrieves, so they belong in the artifact.
for db in "$REPO.db" "$REPO-any.db"; do
  [ -s "$STAGE/$db" ] || continue
  cp -f "$STAGE/$db" "$dir/$db"
  [ -s "$STAGE/$db.sig" ] && cp -f "$STAGE/$db.sig" "$dir/$db.sig"
done

# --- download closure --------------------------------------------------------
dbs=()
for db in "$STAGE/$REPO.db" "$STAGE/$REPO-any.db"; do [ -s "$db" ] && dbs+=("$db"); done
[ "${#dbs[@]}" -gt 0 ] || die "no database retrieved for $REPO/$ARCH"

pkgargs=(); for p in $PACKAGES; do pkgargs+=("--package=$p"); done
srcargs=()
for db in "${dbs[@]}"; do
  case "$db" in
    *-any.db) srcargs+=(--source "$REPO/any" "$db") ;;
    *)        srcargs+=(--source "$REPO/$ARCH" "$db") ;;
  esac
done
python3 "$HERE/enumerate.py" "${srcargs[@]}" "${pkgargs[@]}" > "$STAGE/index.part" \
  || die "could not enumerate the closure"
say "closure: $(wc -l < "$STAGE/index.part") packages"

# OCI treats `path:type` specially and an Arch epoch puts a colon in the
# filename (zlib-1:1.3.2-...). Stage under an escaped name; index.tsv keeps the
# real one, and the client pulls by digest, so the layer title is cosmetic.
safe_name() { printf '%s' "$1" | sed 's/:/%3A/g'; }

fetched=0
while IFS=$'\t' read -r prefix fn sha size; do
  [ -n "$fn" ] || continue
  if [ "$MAX_FILES" -gt 0 ] && [ "$fetched" -ge "$MAX_FILES" ]; then
    say "MAX_FILES=$MAX_FILES reached, stopping"
    break
  fi
  sfile="$(safe_name "$fn")"
  fetch "$prefix/$fn" "$dir/$sfile"
  fetch "$prefix/$fn.sig" "$dir/$sfile.sig"
  verify_sig "$dir/$sfile" || die "untrusted signature on $fn"
  got="$(sha256sum "$dir/$sfile" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || die "$fn: sha256 $got != database $sha"
  fetched=$((fetched + 1))
  say "  ok $fn"
done < "$STAGE/index.part"

# --- index -------------------------------------------------------------------
{
  echo "# url-path	filename	sha256	size"
  for db in "$REPO.db" "$REPO-any.db"; do
    [ -s "$STAGE/$db" ] || continue
    case "$db" in *-any.db) p="$REPO/any" ;; *) p="$REPO/$ARCH" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$p" "$db" \
      "$(sha256sum "$STAGE/$db" | cut -d' ' -f1)" "$(wc -c < "$STAGE/$db")"
  done
  while IFS=$'\t' read -r prefix fn sha size; do
    [ -f "$dir/$(safe_name "$fn")" ] \
      && printf '%s\t%s\t%s\t%s\n' "$prefix" "$fn" "$sha" "$size"
  done < "$STAGE/index.part"
} > "$dir/index.tsv"
say "index: $(($(wc -l < "$dir/index.tsv") - 1)) files"

# --- publish -----------------------------------------------------------------
if [ "${PUSH:-1}" = "0" ]; then
  say "PUSH=0, artifact left in $dir"
  exit 0
fi
command -v oras >/dev/null 2>&1 || die "oras is not on PATH"
# Exactly the files the index names, so a slice publishes its own slice and a
# restored stage cannot add a file that is no longer in the closure.
mapfile -t files < <(
  tail -n +2 "$dir/index.tsv" | while IFS=$'\t' read -r p fn sha size; do
    s="$(safe_name "$fn")"
    [ -f "$dir/$s" ] && printf '%s\n%s.sig\n' "$s" "$s"
  done
)
( cd "$dir" && oras push "$REF" \
    --artifact-type application/vnd.pkgforge.archpower.mirror.v1 \
    "${files[@]}" index.tsv )
say "published $REF"
