#!/usr/bin/env bash
# Resilient, verified fetch of an ArchPOWER repository database.
#
# Tries independent retrieval engines (different TLS stacks and egresses) until
# one returns a database that passes structural validation and, when the detached
# signature and upstream keyring are present, a Good GPG signature from a signer
# on the pinned trusted list. Falls back to a last-known-good cache. A cached good
# copy is never overwritten by an unverified response.
#
# Env:
#   OUT, DB_URL, SIG_URL, KEYRING, TRUSTED, CACHE_DIR, SUMMARY
#   CI_DIR (curl-impersonate dir), PYTHON (python with curl_cffi), WORKERD, RELAY_TOKEN
#   ENGINE_ORDER (default: curl-impersonate curl-cffi tls-client workerd relay)
#   ALLOW_INSECURE=1  accept structurally valid data when no signature is available
#                     (a BAD signature is always rejected)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-base.db}"
DB_URL="${DB_URL:-https://repo.archlinuxpower.org/base/powerpc/base.db}"
SIG_URL="${SIG_URL:-$DB_URL.sig}"
KEYRING="${KEYRING:-}"
TRUSTED="${TRUSTED:-}"
CACHE_DIR="${CACHE_DIR:-}"
SUMMARY="${SUMMARY:-fetch-summary.tsv}"
ENGINE_ORDER="${ENGINE_ORDER-curl-impersonate curl-cffi tls-client workerd relay}"
ALLOW_INSECURE="${ALLOW_INSECURE:-0}"
RETRIES="${RETRIES:-3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${GPGHOME:-}" ] && rm -rf "$GPGHOME"' EXIT
: > "$SUMMARY"

say() { printf '%s\n' "$*" >&2; }
row() { printf '%s\n' "$*" >> "$SUMMARY"; }
announce() { [ "${GITHUB_ACTIONS:-}" = "true" ] && printf '::%s::%s\n' "$1" "$2"; return 0; }

# ---- signature material -----------------------------------------------------
GPGHOME=""
if [ -n "$KEYRING" ] && [ -s "$KEYRING" ] && command -v gpg >/dev/null 2>&1; then
  GPGHOME="$(mktemp -d)"; chmod 700 "$GPGHOME"
  if GNUPGHOME="$GPGHOME" gpg --batch --quiet --import "$KEYRING" >/dev/null 2>&1; then
    say "imported keyring $(basename "$KEYRING")"
  else
    GPGHOME=""
  fi
fi

# ---- validation -------------------------------------------------------------
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

# ---- gpgv: sets GPG_FP, returns 0 good/trusted, 1 bad, 2 unavailable ---------
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

# ---- engines ----------------------------------------------------------------
engine_available() {
  case "$1" in
    curl-impersonate) [ -n "${CI_DIR:-}" ] && [ -x "$CI_DIR/curl_chrome136" ] ;;
    curl-cffi)        [ -n "${PYTHON:-}" ] && [ -f "$HERE/curl_cffi_fetch.py" ] ;;
    tls-client)       command -v node >/dev/null 2>&1 && [ -f "$HERE/tls_client_fetch.mjs" ] ;;
    workerd)          [ -x "${WORKERD:-$HERE/node_modules/.bin/workerd}" ] ;;
    relay)            [ -n "${RELAY_TOKEN:-}" ] && command -v node >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

download_with() { # engine url out
  local e="$WORK/err.$1"
  case "$1" in
    curl-impersonate) "$CI_DIR/curl_chrome136" -fsSL --max-time 180 -o "$3" "$2" >/dev/null 2>"$e" ;;
    curl-cffi)        "$PYTHON" "$HERE/curl_cffi_fetch.py" "$2" "$3" >/dev/null 2>"$e" ;;
    tls-client)       node "$HERE/tls_client_fetch.mjs" "$2" "$3" >/dev/null 2>"$e" ;;
    workerd)          bash "$HERE/workerd_fetch.sh" "$2" "$3" >/dev/null 2>"$e" ;;
    relay)            node "$HERE/relay_fetch.mjs" "$2" "$3" >/dev/null 2>"$e" ;;
    *) return 127 ;;
  esac
}

engine_err() { [ -s "$WORK/err.$1" ] && tail -1 "$WORK/err.$1" | tr '\t\n' '  ' | cut -c1-140; }

accept_ok() { # sigreason
  case "$1" in
    gpg:*)         return 0 ;;
    bad-signature) return 1 ;;
    *)             [ "$ALLOW_INSECURE" = "1" ] ;;
  esac
}

accept_file() { # engine db sigfile sigreason
  local engine="$1" db="$2" sigf="$3" sigreason="$4" sha bytes
  bytes="$(wc -c < "$db")"
  sha="$(sha256sum "$db" | awk '{print $1}')"
  cp "$db" "$OUT"
  [ -s "$sigf" ] && cp "$sigf" "$OUT.sig"
  row "$engine	db	accepted	ok	$sigreason	$bytes	$sha"
  printf 'RESULT\tsource=%s\tverification=%s\tbytes=%s\tsha256=%s\n' "$engine" "$sigreason" "$bytes" "$sha" >> "$SUMMARY"
  say "accepted via $engine: $sigreason, $bytes bytes, sha256=$sha"
  return 0
}

# ---- main ladder ------------------------------------------------------------
ACCEPTED=""
for engine in $ENGINE_ORDER; do
  if ! engine_available "$engine"; then
    row "$engine	-	unavailable	-	-	0	-"
    continue
  fi
  attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    db="$WORK/db.$engine"
    if ! download_with "$engine" "$DB_URL" "$db"; then
      row "$engine	db	download-failed	-	-	0	attempt=$attempt err=$(engine_err "$engine")"
      say "$engine: download failed (attempt $attempt): $(engine_err "$engine")"
      attempt=$((attempt + 1)); sleep $((attempt * 5)); continue
    fi
    reason="$(validate_db "$db")"
    if [ "$reason" != "ok" ]; then
      row "$engine	db	invalid	$reason	-	$(wc -c < "$db" 2>/dev/null || echo 0)	attempt=$attempt"
      say "$engine: invalid data ($reason), attempt $attempt"
      attempt=$((attempt + 1)); sleep $((attempt * 5)); continue
    fi

    sigreason="no-signature"
    if download_with "$engine" "$SIG_URL" "$WORK/sig.$engine" && [ -s "$WORK/sig.$engine" ]; then
      gpg_verify "$db" "$WORK/sig.$engine"; grc=$?
      case "$grc" in
        0) sigreason="gpg:$GPG_FP" ;;
        2) sigreason="no-keyring" ;;
        *) sigreason="bad-signature" ;;
      esac
    fi

    if accept_ok "$sigreason"; then
      accept_file "$engine" "$db" "$WORK/sig.$engine" "$sigreason" || true
      ACCEPTED="$engine"
      break 2
    fi
    row "$engine	db	rejected	ok	$sigreason	$(wc -c < "$db")	attempt=$attempt"
    say "$engine: rejected ($sigreason), attempt $attempt"
    attempt=$((attempt + 1)); sleep $((attempt * 5))
  done
done

# ---- last-known-good cache --------------------------------------------------
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
    printf 'RESULT\tsource=cache\tverification=%s\tbytes=%s\tsha256=%s\n' "$sigreason" "$(wc -c < "$OUT")" "$(sha256sum "$OUT" | awk '{print $1}')" >> "$SUMMARY"
    announce warning "all live engines failed; using last-known-good cache ($sigreason)"
    say "using last-known-good cache ($sigreason)"
  fi
fi

# ---- refresh cache on live success ------------------------------------------
if [ -n "$ACCEPTED" ] && [ "$ACCEPTED" != "cache" ] && [ -n "$CACHE_DIR" ]; then
  mkdir -p "$CACHE_DIR"
  cp "$OUT" "$CACHE_DIR/$(basename "$OUT")"
  [ -s "$OUT.sig" ] && cp "$OUT.sig" "$CACHE_DIR/$(basename "$OUT").sig"
fi

# ---- verdict ----------------------------------------------------------------
if [ -z "$ACCEPTED" ]; then
  announce error "no engine produced a verified database; nothing was written"
  say "FAILED: no engine produced a verified database"
  exit 1
fi
if [ "$ACCEPTED" = "cache" ]; then
  announce warning "used cache, not a live fetch"
fi
exit 0
