#!/usr/bin/env bash
# Engine: workerd serving the rv worker verbatim (Cloudflare's fetch stack).
#   workerd_fetch.sh <url> <out>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
URL="$1"
OUT="$2"
WK="${WORKERD:-$HERE/node_modules/.bin/workerd}"
[ -x "$WK" ] || { echo "workerd_fetch: workerd not at $WK" >&2; exit 127; }

WORK="$(mktemp -d)"
SOCK="$WORK/w.sock"
trap 'kill "${PID:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/config.capnp" <<EOF
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    ( name = "rv", worker = (
      modules = [ ( name = "worker.js", esModule = embed "worker.js" ) ],
      compatibilityDate = "2025-09-01",
    ) ),
  ],
  sockets = [
    ( name = "http", address = "unix:$SOCK", http = (), service = "rv" ),
  ],
);
EOF
cp "$HERE/worker.js" "$WORK/worker.js"

"$WK" serve "$WORK/config.capnp" >"$WORK/wk.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.25; done
[ -S "$SOCK" ] || { echo "workerd_fetch: socket never appeared" >&2; cat "$WORK/wk.log" >&2; exit 1; }

rc=0
curl -fsS --unix-socket "$SOCK" --max-time 180 -o "$OUT" "http://localhost/$URL" || rc=$?
exit "$rc"
