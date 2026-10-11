# leo relay (step 0: APNs-from-Workers proof)

Throwaway Worker proving a Cloudflare Worker can send APNs over HTTP/2 with token auth
(spec: `docs/superpowers/specs/2026-10-10-leo-ios.md`, "Push relay").

`POST /push {"apns_token": "<hex>", "sandbox": true}` signs an ES256 JWT (hand-rolled WebCrypto,
`src/jwt.ts`) and POSTs an alert to `api[.sandbox].push.apple.com/3/device/<token>` with
`apns-topic: studio.blackpaw.leo.ios`, `apns-push-type: alert`. The response returns APNs status,
`apns-id`, body, or the raw fetch error.

## Status: NOT YET PROVEN against Apple

Unit tests pass (`npm test`). The remote run is **blocked on credentials**: no APNs auth key
(`.p8` + Key ID) exists in any 1Password vault reachable by the service account
(Olympus, Blackpaw Studio, Artist Connect). The only Apple items are App Store Connect API keys,
which APNs does not accept. Needed: an Apple Developer *Keys* entry with "Apple Push
Notifications service (APNs)" enabled, its Key ID, and the Team ID.

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

Interpretation: `400 {"reason":"BadDeviceToken"}` = success (HTTP/2 + JWT accepted);
`403 InvalidProviderToken` = JWT bug; a fetch error / protocol rejection = Workers cannot reach APNs.

No result captured yet.
