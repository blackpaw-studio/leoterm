"use strict";
(() => {
  // src/clock.ts
  var systemClock = { now: () => Date.now() };

  // src/main.ts
  function createPlugin(leo2, clock) {
    leo2.log("info", "github plugin loaded at " + clock.now());
  }
  createPlugin(leo, systemClock);
})();
