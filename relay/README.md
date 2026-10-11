# leo-relay

Stateless Cloudflare Worker that forwards end-to-end-encrypted Leo push notifications to APNs.
It stores nothing and never sees plaintext: the daemon encrypts, the app's Notification Service
Extension decrypts. Wire contract: `docs/superpowers/specs/2026-10-10-leo-ios.md`, "Appendix — push
wire contract (step 5)".

## API

| Route | Body | Result |
|---|---|---|
| `POST /register` | `{"apns_token": "<hex>", "env": "sandbox"\|"production"}` | `200 {"grant"}`; 10/min per client IP |
| `POST /push` | `{"grant", "ciphertext", "collapse_id"}` | `202 {}`; 30/min per grant |

`grant = b64url(JSON{t,e}) + "." + b64url(HMAC-SHA256(GRANT_SECRET, first part))`, verified in
constant time. `ciphertext` is base64, at most 2048 characters. Errors are `{"error": "<code>"}`
and never echo input:

| Status | `error` | Meaning |
|---|---|---|
| 400 | `bad_request` | invalid JSON, unknown or missing field, bad token/env/ciphertext/collapse_id |
| 401 | `unauthorized` | grant forged, malformed, or signed under another secret |
| 404 | `not_found` | anything but `POST /register` and `POST /push` |
| 410 | `gone` | APNs `BadDeviceToken` / `Unregistered` / 410: drop the registration |
| 413 | `payload_too_large` | body or ciphertext over the cap |
| 429 | `rate_limited` | |
| 502 | `upstream_error` | APNs refused or was unreachable |
| 500 | `internal` | misconfiguration (missing secret) or an unexpected error |

The APNs provider JWT is cached in module scope and re-signed after 40 minutes (Apple wants
refreshes no more often than every 20 and tokens no older than 60). Apple answering
`ExpiredProviderToken`/`InvalidProviderToken` drops the cache.

## Secrets

| Name | Value |
|---|---|
| `APNS_P8` | contents of `AuthKey_XXXX.p8` (PEM; literal `\n` also accepted) |
| `APNS_KEY_ID` | 10-char key id |
| `APNS_TEAM_ID` | 10-char Apple team id |
| `GRANT_SECRET` | random HMAC key, e.g. `openssl rand -base64 48`. Rotating it revokes every grant. |

Credentials live in 1Password (Olympus vault): "APNs Auth Key - Blackpaw" (p8, key id, team id) and
"Cloudflare API Token - leo push relay" (Workers Scripts Write; the account id is in the item).
`APNS_KEY_P8` from the proof-of-concept was renamed `APNS_P8`.

## Deploy

Needs wrangler 4.36+ (rate-limiting binding in `wrangler.toml` as `[[ratelimits]]`).

```sh
cd relay && npm ci && npm test && npx tsc --noEmit
export CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=...   # or `npx wrangler login`
npx wrangler secret put APNS_P8 < AuthKey_XXXX.p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
openssl rand -base64 48 | npx wrangler secret put GRANT_SECRET
npx wrangler deploy
```

The worker is `leo-relay` on `workers.dev`; the old `leo-relay-poc` Worker is separate and can be
deleted from the dashboard once this one is live. Sandbox grants (`env: "sandbox"`, Xcode/TestFlight
debug builds) and production grants hit different APNs hosts, selected by the grant.

## Local development

```sh
npm install
npm test            # vitest + @cloudflare/vitest-plugin (Miniflare); no network, no secrets
npx tsc --noEmit
cat > .dev.vars <<'ENV'          # gitignored
APNS_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
GRANT_SECRET=local-only-secret
ENV
npx wrangler dev --remote        # real APNs; needs Cloudflare credentials
```

Smoke test against a real device token (a dummy 64-hex token yields `410`, which proves HTTP/2
and the JWT were accepted; a bad JWT would be `502`):

```sh
grant=$(curl -s localhost:8787/register -d '{"apns_token":"'$(printf 'a%.0s' {1..64})'","env":"sandbox"}' | jq -r .grant)
curl -si localhost:8787/push -d '{"grant":"'$grant'","ciphertext":"AAAA","collapse_id":"smoke"}'
```

Never commit `.dev.vars`, `*.p8`, `*.pem` or `*.key` (all gitignored). Never log tokens, grants or
ciphertext; a test enforces it.

## Proof of concept (history)

Step 0 proved Workers can send APNs over HTTP/2 with token auth (2026-10-10, `wrangler dev --remote`):
a dummy sandbox token got `400 BadDeviceToken` from Apple, i.e. the JWT was accepted.
