import "../../sdk/leo.d.ts";
import type { Leo } from "../../sdk/leo";
import { systemClock, type Clock } from "./clock";

/** Composition root. Everything below takes `leo` and `clock` as parameters. */
export function createPlugin(leo: Leo, clock: Clock): void {
  leo.log("info", "github plugin loaded at " + clock.now());
}

// The only place the global bridge is touched.
createPlugin(leo, systemClock);
