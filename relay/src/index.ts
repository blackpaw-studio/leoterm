import { signApnsJwt } from "./jwt";

interface Env {
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
}

const APNS_TOPIC = "studio.blackpaw.leo.ios";
const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { "content-type": "application/json" } });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method !== "POST" || url.pathname !== "/push") return json({ error: "POST /push only" }, 404);

    const input = (await req.json().catch(() => null)) as { apns_token?: string; sandbox?: boolean } | null;
    if (!input?.apns_token || !/^[0-9a-fA-F]+$/.test(input.apns_token)) {
      return json({ error: "apns_token (hex string) required" }, 400);
    }

    const host = input.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    try {
      const jwt = await signApnsJwt({
        p8: env.APNS_KEY_P8,
        keyId: env.APNS_KEY_ID,
        teamId: env.APNS_TEAM_ID,
        now: Math.floor(Date.now() / 1000),
      });
      const res = await fetch(`https://${host}/3/device/${input.apns_token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": APNS_TOPIC,
          "apns-push-type": "alert",
          "content-type": "application/json",
        },
        body: JSON.stringify({ aps: { alert: { title: "Leo", body: "Relay test push" }, sound: "default" } }),
      });
      return json({
        host,
        apns_status: res.status,
        apns_id: res.headers.get("apns-id"),
        apns_body: await res.text(),
      });
    } catch (err) {
      const e = err as Error;
      return json({ host, fetch_error: { name: e.name, message: e.message, stack: e.stack } }, 502);
    }
  },
};
