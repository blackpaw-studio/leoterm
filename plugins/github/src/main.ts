import "../../sdk/leo.d.ts";
import { systemClock } from "./clock";
import { createPlugin } from "./plugin";

// The only place the global bridge is touched.
createPlugin(leo, systemClock);
