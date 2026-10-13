#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
#
# Retrieve one file through an ordered list of clients, verify it, and fall
# back to a last-known-good copy.
#
# Each client is tried up to RETRIES times. A result is accepted when it passes
# structural validation and either carries a detached signature from a key on
# the pinned trusted list, or (only with ALLOW_INSECURE=1) has no signature
# available. A signature that is present and wrong is always rejected.
#
# Env:
#   OUT          output path                       (default: base.db)
#   DB_URL       file to retrieve
#   SIG_URL      detached signature               (default: DB_URL.sig)
#   KEYRING      public keyring to import         (default: mirror/keys/archpower.gpg)
#   TRUSTED      trusted signer list              (default: mirror/keys/archpower-trusted)
#   CACHE_DIR    last-known-good directory        (default: unset)
#   SUMMARY      machine-readable log             (default: fetch-summary.tsv)
#   CLIENTS      ordered client list              (default: chromium curl-impersonate curl-cffi tls-client)
#   RETRIES      attempts per client              (default: 3)
#   ALLOW_INSECURE=1  accept unsigned data
#   CURL_IMPERSONATE_DIR, PYTHON, and each client's own variables pass through.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-base.db}"
DB_URL="${DB_URL:-https://repo.archlinuxpower.org/base/powerpc/base.db}"
SIG_URL="${SIG_URL:-$DB_URL.sig}"
KEYRING="${KEYRING:-$HERE/mirror/keys/archpower.gpg}"
TRUSTED="${TRUSTED:-$HERE/mirror/keys/archpower-trusted}"
CACHE_DIR="${CACHE_DIR:-}"
SUMMARY="${SUMMARY:-fetch-summary.tsv}"
CLIENTS="${CLIENTS-chromium curl-impersonate curl-cffi tls-client}"
RETRIES="${RETRIES:-3}"
ALLOW_INSECURE="${ALLOW_INSECURE:-0}"
PYTHON="${PYTHON:-python3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${GPGHOME:-}" ] && rm -rf "$GPGHOME"' EXIT
: > "$SUMMARY"

say() { printf '%s\n' "$*" >&2; }
row() { printf '%s\n' "$*" >> "$SUMMARY"; }
announce() { [ "${GITHUB_ACTIONS:-}" = "true" ] && printf '::%s::%s\n' "$1" "$2"; return 0; }

# ---- signature material ------------------------------------------------------
GPGHOME=""
if [ -n "$KEYRING" ] && [ -s "$KEYRING" ] && command -v gpg >/dev/null 2>&1; then
  GPGHOME="$(mktemp -d)"; chmod 700 "$GPGHOME"
  if GNUPGHOME="$GPGHOME" gpg --batch --quiet --import "$KEYRING" >/dev/null 2>&1; then
    say "imported keyring $(basename "$KEYRING")"
  else
    GPGHOME=""
  fi
fi

# ---- structural validation ---------------------------------------------------
validate_db() { # file -> "ok" | reason
  local f="$1" sz magic
  [ -s "$f" ] || { echo "empty"; return 1; }
  sz="$(wc -c < "$f")"
  [ "$sz" -gt 100000 ] || { echo "too-small:$sz"; return 1; }
  magic="$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')"
  case "$magic" in
    28b52ffd) tar --zstd -tf "$f" >"$WORK/entries" 2>/dev/null || { echo "bad-zstd-tar"; return 1; } ;;
    1f8b*)    tar -tzf    "$f" >"$WORK/entries" 2>/dev/null || { echo "bad-gzip-tar"; return 1; } ;;
    *)        echo "bad-magic:$magic"; return 1 ;;
  esac
  grep -q '^pacman-' "$WORK/entries" || { echo "no-pacman-entry"; return 1; }
  echo "ok"
}

# ---- signature check: sets GPG_FP, returns 0 good/trusted, 1 bad, 2 unavailable
GPG_FP=""
gpg_verify() { # db sig
  GPG_FP=""
  [ -n "$GPGHOME" ] || return 2
  [ -s "$2" ] || return 2
  local status fp
  status="$(GNUPGHOME="$GPGHOME" gpg --batch --status-fd 1 --verify "$2" "$1" 2>/dev/null)" || return 1
  echo "$status" | grep -q '^\[GNUPG:\] GOODSIG' || return 1
  fp="$(echo "$status" | awk '/VALIDSIG/{print $3; exit}')"
  [ -n "$fp" ] || return 1
  if [ -s "$TRUSTED" ]; then
    grep -qi "^${fp}:" "$TRUSTED" || { say "gpg: signer $fp is not on the trusted list"; return 1; }
  fi
  GPG_FP="$fp"
  return 0
}

# ---- clients -----------------------------------------------------------------
client_available() {
  case "$1" in
    chromium)          command -v node >/dev/null 2>&1 && [ -f "$HERE/fetchers/chromium_fetch.mjs" ] \
                         && node -e 'import("playwright").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null ;;
    curl-impersonate)  [ -n "${CURL_IMPERSONATE_DIR:-}" ] \
                         && [ -x "$CURL_IMPERSONATE_DIR/${CURL_IMPERSONATE_BIN:-curl_chrome136}" ] ;;
    curl-cffi)         command -v "$PYTHON" >/dev/null 2>&1 && [ -f "$HERE/fetchers/curl_cffi_fetch.py" ] ;;
    tls-client)        command -v node >/dev/null 2>&1 && [ -f "$HERE/fetchers/tls_client_fetch.mjs" ] ;;
    *) return 1 ;;
  esac
}

download_with() { # client url out
  local e="$WORK/err.$1"
  case "$1" in
    chromium)         node "$HERE/fetchers/chromium_fetch.mjs" "$2" "$3" >/dev/null 2>"$e" ;;
    curl-impersonate) sh "$HERE/fetchers/curl_impersonate_fetch.sh" "$2" "$3" >/dev/null 2>"$e" ;;
    curl-cffi)        "$PYTHON" "$HERE/fetchers/curl_cffi_fetch.py" "$2" "$3" >/dev/null 2>"$e" ;;
    tls-client)       node "$HERE/fetchers/tls_client_fetch.mjs" "$2" "$3" >/dev/null 2>"$e" ;;
    *) return 127 ;;
  esac
}

client_err() { [ -s "$WORK/err.$1" ] && tail -1 "$WORK/err.$1" | tr '\t\n' '  ' | cut -c1-140; }

accept_ok() { # sigreason
  case "$1" in
    gpg:*)         return 0 ;;
    bad-signature) return 1 ;;
    *)             [ "$ALLOW_INSECURE" = "1" ] ;;
  esac
}

accept_file() { # client db sigfile sigreason
  local client="$1" db="$2" sigf="$3" sigreason="$4" bytes sha
  bytes="$(wc -c < "$db")"
  sha="$(sha256sum "$db" | awk '{print $1}')"
  cp "$db" "$OUT"
  [ -s "$sigf" ] && cp "$sigf" "$OUT.sig"
  row "$client	db	accepted	ok	$sigreason	$bytes	$sha"
  printf 'RESULT\tsource=%s\tverification=%s\tbytes=%s\tsha256=%s\n' \
    "$client" "$sigreason" "$bytes" "$sha" >> "$SUMMARY"
  say "accepted via $client: $sigreason, $bytes bytes, sha256=$sha"
  return 0
}

# ---- ordered attempt ---------------------------------------------------------
ACCEPTED=""
for client in $CLIENTS; do
  if ! client_available "$client"; then
    row "$client	-	unavailable	-	-	0	-"
    continue
  fi
  attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    db="$WORK/db.$client"
    if ! download_with "$client" "$DB_URL" "$db"; then
      row "$client	db	download-failed	-	-	0	attempt=$attempt err=$(client_err "$client")"
      say "$client: download failed (attempt $attempt): $(client_err "$client")"
      attempt=$((attempt + 1)); sleep $((attempt * 5)); continue
    fi
    reason="$(validate_db "$db")"
    if [ "$reason" != "ok" ]; then
      row "$client	db	invalid	$reason	-	$(wc -c < "$db" 2>/dev/null || echo 0)	attempt=$attempt"
      say "$client: invalid data ($reason), attempt $attempt"
      attempt=$((attempt + 1)); sleep $((attempt * 5)); continue
    fi

    sigreason="no-signature"
    if download_with "$client" "$SIG_URL" "$WORK/sig.$client" && [ -s "$WORK/sig.$client" ]; then
      gpg_verify "$db" "$WORK/sig.$client"; grc=$?
      case "$grc" in
        0) sigreason="gpg:$GPG_FP" ;;
        2) sigreason="no-keyring" ;;
        *) sigreason="bad-signature" ;;
      esac
    fi

    if accept_ok "$sigreason"; then
      accept_file "$client" "$db" "$WORK/sig.$client" "$sigreason" || true
      ACCEPTED="$client"
      break 2
    fi
    row "$client	db	rejected	ok	$sigreason	$(wc -c < "$db")	attempt=$attempt"
    say "$client: rejected ($sigreason), attempt $attempt"
    attempt=$((attempt + 1)); sleep $((attempt * 5))
  done
done

# ---- last-known-good cache ---------------------------------------------------
if [ -z "$ACCEPTED" ] && [ -n "$CACHE_DIR" ] && [ -s "$CACHE_DIR/$(basename "$OUT")" ]; then
  cand="$CACHE_DIR/$(basename "$OUT")"
  reason="$(validate_db "$cand")"
  sigreason="cache-unverified"
  if [ -s "$CACHE_DIR/$(basename "$OUT").sig" ]; then
    gpg_verify "$cand" "$CACHE_DIR/$(basename "$OUT").sig"; grc=$?
    case "$grc" in 0) sigreason="gpg:$GPG_FP";; *) sigreason="cache-bad-signature";; esac
  fi
  if [ "$reason" = "ok" ] && [ "$sigreason" != "cache-bad-signature" ]; then
    cp "$cand" "$OUT"
    [ -s "$CACHE_DIR/$(basename "$OUT").sig" ] && cp "$CACHE_DIR/$(basename "$OUT").sig" "$OUT.sig"
    ACCEPTED="cache"
    row "cache	-	accepted	$reason	$sigreason	$(wc -c < "$OUT")	-"
    printf 'RESULT\tsource=cache\tverification=%s\tbytes=%s\tsha256=%s\n' \
      "$sigreason" "$(wc -c < "$OUT")" "$(sha256sum "$OUT" | awk '{print $1}')" >> "$SUMMARY"
    announce warning "all live clients failed; using last-known-good cache ($sigreason)"
    say "using last-known-good cache ($sigreason)"
  fi
fi

# ---- refresh cache on success ------------------------------------------------
if [ -n "$ACCEPTED" ] && [ "$ACCEPTED" != "cache" ] && [ -n "$CACHE_DIR" ]; then
  mkdir -p "$CACHE_DIR"
  cp "$OUT" "$CACHE_DIR/$(basename "$OUT")"
  [ -s "$OUT.sig" ] && cp "$OUT.sig" "$CACHE_DIR/$(basename "$OUT").sig"
fi

# ---- verdict -----------------------------------------------------------------
if [ -z "$ACCEPTED" ]; then
  announce error "no client produced a verified file; nothing was written"
  say "FAILED: no client produced a verified file"
  exit 1
fi
if [ "$ACCEPTED" = "cache" ]; then
  announce warning "used cache, not a live retrieval"
fi
exit 0
