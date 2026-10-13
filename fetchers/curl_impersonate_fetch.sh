#!/bin/sh
# SPDX-License-Identifier: 0BSD
#
# Retrieve a URL with curl-impersonate (BoringSSL).
#
#   CURL_IMPERSONATE_DIR=/opt/curl-impersonate ./curl_impersonate_fetch.sh <url> <out>
#
# Env:
#   CURL_IMPERSONATE_DIR  directory holding the profile wrappers (required)
#   CURL_IMPERSONATE_BIN  profile wrapper (default: curl_chrome136)
set -eu

[ $# -ge 2 ] || { echo "usage: curl_impersonate_fetch.sh <url> <out>" >&2; exit 2; }
dir="${CURL_IMPERSONATE_DIR:?set CURL_IMPERSONATE_DIR to the curl-impersonate directory}"
bin="${CURL_IMPERSONATE_BIN:-curl_chrome136}"

exec "$dir/$bin" -fsSL --connect-timeout 10 --max-time 300 -o "$2" "$1"
