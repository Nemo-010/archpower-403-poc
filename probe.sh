#!/usr/bin/env bash
# Probe repo.archlinuxpower.org from whatever egress this shell has, using
# several HTTP/TLS client shapes against the exact path a docker build reads.
#
#   CI_DIR=/path/to/curl-impersonate bash probe.sh
#
# Each line: label status cf-mitigated cf-ray http-version body-head
set -u

HOST="${HOST:-repo.archlinuxpower.org}"
TARGET_PATH="${TARGET_PATH:-/base/powerpc/base.db}"
URL="https://${HOST}${TARGET_PATH}"
UA_RESOLVE='docker-archlinux-mirrorlist/1 (+https://github.com/pkgforge-dev/docker-archlinux)'
CI_DIR="${CI_DIR:-}"

p() { # label cmd...
  local label="$1"; shift
  local body hdr status mitigated ray ver
  body="$(mktemp)"; hdr="$(mktemp)"
  status="$( "$@" -o "$body" -D "$hdr" -w '%{http_code}|%{http_version}' "$URL" 2>/tmp/probe.err || echo 'ERR|-' )"
  mitigated="$(awk 'tolower($1)=="cf-mitigated:"{print $2}' "$hdr" | tr -d '\r')"
  ray="$(awk 'tolower($1)=="cf-ray:"{print $2}' "$hdr" | tr -d '\r')"
  ver="${status#*|}"; status="${status%%|*}"
  printf '%-24s status=%-4s http=%-3s cf-mitigated=%-10s cf-ray=%-22s body=%s\n' \
    "$label" "$status" "$ver" "${mitigated:-none}" "${ray:-none}" \
    "$(head -c 110 "$body" | tr '\n\r' '  ' | tr -s ' ')"
  rm -f "$body" "$hdr"
}

echo "== $URL =="
p "curl-default"       curl -sS --max-time 60
p "curl-resolve-ua"    curl -sS --max-time 60 -A "$UA_RESOLVE"
p "curl-chrome-ua"     curl -sS --max-time 60 -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
p "curl-http1.1"       curl -sS --http1.1 --max-time 60
p "curl-ipv4"          curl -sS -4 --max-time 60
p "curl-ipv6"          curl -sS -6 --max-time 60

if [ -n "$CI_DIR" ] && [ -d "$CI_DIR" ]; then
  for b in curl_chrome136 curl_chrome131 curl_firefox135 curl_safari172_ios; do
    [ -x "$CI_DIR/$b" ] && p "$b" "$CI_DIR/$b" -sS --max-time 60
  done
fi

# Control: the same client against the repository root (never blocked) proves
# the network path itself is fine when the db path is not.
CTRL_HOST="$HOST" CTRL_PATH="/" ; URL="https://${CTRL_HOST}${CTRL_PATH}"
p "curl-root-control"  curl -sS --max-time 60
