#!/usr/bin/env bash
#
# Sync one ArchPOWER repository/architecture into an OCI artifact, fetching
# through a real Chromium because this is the only client that gets a 200 from
# a GitHub runner. See README.md for the measurements.
#
#   sync.sh <repo> <arch>
#
# The artifact is ghcr.io/<NS>/archpower-<repo>:<arch> and holds every file plus
# its .sig, with index.tsv mapping filename -> sha256 -> size so a client can
# pull one blob without listing the artifact.
#
# Env:
#   NS          GHCR namespace              (default: oci namespace of the repo)
#   ORIGIN      upstream base URL           (default: repo.archlinuxpower.org)
#   PACKAGES    packages to close over      (default: base archpower-keyring)
#   STAGE       working directory           (default: ./stage)
#   MAX_FILES   stop after N files, for staged runs over the whole repo
#   SKIP_FETCH  set to reuse files already in STAGE
#   PUSH        set to 0 to build the artifact without pushing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
REPO="${1:?usage: sync.sh <repo> <arch>}"
ARCH="${2:?usage: sync.sh <repo> <arch>}"
NS="${NS:?set NS to the GHCR namespace}"
ORIGIN="${ORIGIN:-https://repo.archlinuxpower.org}"
PACKAGES="${PACKAGES:-base archpower-keyring}"
STAGE="${STAGE:-$PWD/stage}"
MAX_FILES="${MAX_FILES:-0}"
KEYRING="${KEYRING:-$HERE/keys/archpower.gpg}"
TRUSTED="${TRUSTED:-$HERE/keys/archpower-trusted}"
NAME="archpower-$REPO"
TAG="$ARCH"
REF="ghcr.io/$NS/$NAME:$TAG"

UA="${CHROME_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36}"
export CHROME_FULL=1 CHROME_STEALTH=1 CHROME_UA="$UA" CHROME_WAIT="${CHROME_WAIT:-30}"

say() { printf '%s\n' "$*" >&2; }
die() { say "sync: $*"; exit 1; }

# The URL pacman would build, mapped to the files this script fetches.
dir="$STAGE/$REPO/$ARCH"
mkdir -p "$dir"

# --- fetch, through Chromium --------------------------------------------------
fetch() { # <remote-path> <dest>
  local path="$1" dest="$2"
  if [ "${SKIP_FETCH:-0}" != "0" ] && [ -s "$dest" ]; then return 0; fi
  node "$REPO_ROOT/chromium_fetch.mjs" "$ORIGIN/$path" "$dest" "$ORIGIN/$REPO/$ARCH/"
}

# --- gpg ----------------------------------------------------------------------
GPGHOME="$STAGE/gnupg"
mkdir -p "$GPGHOME"
chmod 700 "$GPGHOME"
gpg --batch --quiet --homedir "$GPGHOME" --import "$KEYRING" >/dev/null 2>&1 \
  || die "cannot import $KEYRING"

verify_sig() { # <file>
  local f="$1" status fp
  status="$(gpg --batch --homedir "$GPGHOME" --status-fd 1 --verify "$f.sig" "$f" 2>/dev/null)" \
    || { say "BAD signature: $(basename "$f")"; return 1; }
  echo "$status" | grep -q '^\[GNUPG:\] GOODSIG' || { say "no GOODSIG: $(basename "$f")"; return 1; }
  fp="$(echo "$status" | awk '/VALIDSIG/{print $3; exit}')"
  grep -qi "^$fp:" "$TRUSTED" || { say "signer $fp not trusted: $(basename "$f")"; return 1; }
}

# --- databases ----------------------------------------------------------------
for path in "$REPO/$ARCH/$REPO.db" "$REPO/any/$REPO-any.db"; do
  db="$(basename "$path")"
  # The databases are always refetched; SKIP_FETCH exists for the packages,
  # which are the expensive part of a staged run.
  rm -f "$STAGE/$db" "$STAGE/$db.sig"
  if fetch "$path" "$STAGE/$db" 2>/dev/null; then
    fetch "$path.sig" "$STAGE/$db.sig" 2>/dev/null || true
    say "fetched $path ($(wc -c < "$STAGE/$db") bytes)"
  else
    say "no $path"
    rm -f "$STAGE/$db"
  fi
done

# --- the closure --------------------------------------------------------------
dbs=()
for db in "$STAGE/$REPO.db" "$STAGE/$REPO-any.db"; do [ -s "$db" ] && dbs+=("$db"); done
[ "${#dbs[@]}" -gt 0 ] || die "no database fetched for $REPO/$ARCH"

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

# OCI arguments treat `path:type` specially, and an Arch epoch puts a colon in
# the filename (iptables-1:nftables-...). Stage under an escaped name; index.tsv
# keeps the real one, and the wrapper pulls by digest, so the layer title is only
# for a human reading the artifact.
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
  verify_sig "$dir/$sfile" || die "refusing to mirror a package whose signature is not trusted"
  got="$(sha256sum "$dir/$sfile" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || die "$fn: sha256 $got != database $sha"
  fetched=$((fetched + 1))
  say "  ok $fn"
done < "$STAGE/index.part"

# --- index --------------------------------------------------------------------
{
  echo "# url-path	filename	sha256	size"
  while IFS=$'\t' read -r prefix fn sha size; do
    [ -f "$dir/$(safe_name "$fn")" ] \
      && printf '%s\t%s\t%s\t%s\n' "$prefix" "$fn" "$sha" "$size"
  done < "$STAGE/index.part"
} > "$dir/index.tsv"
say "index: $(($(wc -l < "$dir/index.tsv") - 1)) files"

# --- push ---------------------------------------------------------------------
if [ "${PUSH:-1}" = "0" ]; then
  say "PUSH=0, artifact left in $dir"
  exit 0
fi
command -v oras >/dev/null 2>&1 || die "oras is not on PATH"
# Exactly the files the index names, so a stage pushes its own slice and a
# restored stage cannot drag in a file that is no longer part of the closure.
mapfile -t files < <(
  tail -n +2 "$dir/index.tsv" | while IFS=$'\t' read -r p fn sha size; do
    s="$(safe_name "$fn")"
    [ -f "$dir/$s" ] && printf '%s\n%s.sig\n' "$s" "$s"
  done
)
( cd "$dir" && oras push "$REF" \
    --artifact-type application/vnd.pkgforge.archpower.mirror.v1 \
    "${files[@]}" index.tsv )
say "pushed $REF"
