import type { Env as RelayEnv } from "../src/relay";

declare global {
  namespace Cloudflare {
    interface Env extends RelayEnv {}
    interface GlobalProps {
      mainModule: typeof import("../src/index");
    }
  }
}
