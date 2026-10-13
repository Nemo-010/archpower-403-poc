# fetchers

Each program retrieves one URL with a different TLS/HTTP client stack. The
interface is the same for all of them:

```
<client> <url> <out>
```

The response body is written to `<out>`. A non-zero exit means the bytes were
not retrieved; nothing else is assumed about the reason.

| file | stack | dependency | environment |
| --- | --- | --- | --- |
| `chromium_fetch.mjs` | Chromium network service | `playwright` and the full Chrome-for-Testing build | `CHROME_UA`, `CHROME_WAIT` |
| `curl_impersonate_fetch.sh` | BoringSSL | curl-impersonate | `CURL_IMPERSONATE_DIR`, `CURL_IMPERSONATE_BIN` |
| `curl_cffi_fetch.py` | BoringSSL | Python `curl_cffi` | `IMPERSONATE` |
| `tls_client_fetch.mjs` | Go `uTLS` | `node-tls-client` | `TLS_CLIENT_ID` |

## chromium_fetch.mjs

```sh
npm i playwright
npx playwright install chromium
node chromium_fetch.mjs https://example.invalid/file.bin out.bin
```

The request is an in-page `fetch()`, so it uses Chromium's own network stack and
its cookie jar. Playwright's request context is a separate Node-side HTTP
client and does not produce the same request, which matters when the origin
distinguishes between them.

`CHROME_UA` overrides the user agent. By default the user agent is derived from
the running build's own version, so the user agent, the client hints and the
TLS stack stay consistent as the build ages. `CHROME_WAIT` is the number of
seconds to wait for the page to reach `readyState === "complete"` (default 20).

There is no separate "headless" switch: `channel: "chromium"` selects the full
Chrome-for-Testing build, which is the build whose user agent and client hints
match. The headless shell reports `HeadlessChrome/<version>` and receives 403
from ArchPOWER.

## curl_impersonate_fetch.sh

```sh
CURL_IMPERSONATE_DIR=/opt/curl-impersonate \
  ./curl_impersonate_fetch.sh https://example.invalid/file.bin out.bin
```

`CURL_IMPERSONATE_BIN` selects the profile wrapper; it defaults to
`curl_chrome136`.

## curl_cffi_fetch.py

```sh
python3 -m pip install curl_cffi
python3 curl_cffi_fetch.py https://example.invalid/file.bin out.bin
```

`IMPERSONATE` selects the profile; it defaults to `chrome`.

## tls_client_fetch.mjs

```sh
npm i node-tls-client
node tls_client_fetch.mjs https://example.invalid/file.bin out.bin
```

`node-tls-client` needs its native library initialised before a session is
created; the program calls `initTLS()` and `destroyTLS()` around the request.
`TLS_CLIENT_ID` selects the profile; it defaults to `chrome_131`.
