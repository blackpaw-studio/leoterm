import { generateKeyPairSync } from "node:crypto";
import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Throwaway ES256 key so entry-point tests can sign a real JWT. Never a real .p8.
const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          GRANT_SECRET: "test-grant-secret",
          APNS_P8: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
          APNS_KEY_ID: "TESTKEYID1",
          APNS_TEAM_ID: "TESTTEAMID",
        },
      },
    }),
  ],
});
