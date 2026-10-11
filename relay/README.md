# leo relay (step 0: APNs-from-Workers proof)

Throwaway Worker proving a Cloudflare Worker can send APNs over HTTP/2 with token auth
(spec: `docs/superpowers/specs/2026-10-10-leo-ios.md`, "Push relay").

`POST /push {"apns_token": "<hex>", "sandbox": true}` signs an ES256 JWT (hand-rolled WebCrypto,
`src/jwt.ts`) and POSTs an alert to `api[.sandbox].push.apple.com/3/device/<token>` with
`apns-topic: studio.blackpaw.leo.ios`, `apns-push-type: alert`. The response returns APNs status,
`apns-id`, body, or the raw fetch error.

## Result: PROVEN (2026-10-10, `wrangler dev --remote`, Cloudflare edge)

Dummy 64-hex token, sandbox:

```
HTTP 200 (Worker) {"host":"api.sandbox.push.apple.com","apns_status":400,
 "apns_id":"5992011E-1521-28EA-AB96-6D039C320749","apns_body":"{\"reason\":\"BadDeviceToken\"}"}
```

Apple accepted the HTTP/2 request and the ES256 provider token (a bad JWT would be 403);
it rejected only the fake device token. Workers can reach APNs; no workaround needed.

Credentials come from 1Password Olympus: "APNs Auth Key - Blackpaw" (p8, key_id, team_id) and
"Cloudflare API Token - leo push relay" (Workers Scripts Write; account id in the item).

## Rerun

```sh
cd relay && npm install && npm test
cat > .dev.vars <<'ENV'          # gitignored
APNS_KEY_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
ENV
npx wrangler dev --remote        # needs CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID, or `wrangler login`
curl -s localhost:8787/push -d '{"apns_token":"'$(printf 'a%.0s' {1..64})'","sandbox":true}'
```

Expected result: `400 {"reason":"BadDeviceToken"}` = success (HTTP/2 + JWT accepted);
`403 InvalidProviderToken` = JWT bug; a fetch error / protocol rejection = Workers cannot reach APNs.

## Before production

Cache the APNs JWT (reuse for 20–50 min); Apple throttles frequent token refresh.
