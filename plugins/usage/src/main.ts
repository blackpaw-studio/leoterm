import "../../sdk/leo.d.ts";
import type { LeoV2 } from "./api";
import { systemClock } from "./clock";
import { createPlugin } from "./plugin";

// The only place the global bridge is touched. The v2 bridge adds `credentials` and
// widens `fetch`/`render`; the shared typings describe v1 only.
createPlugin(leo as unknown as LeoV2, systemClock);
