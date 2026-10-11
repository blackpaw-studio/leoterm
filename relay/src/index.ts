import { type Env, createRelay } from "./relay";

// Module scope: the APNs provider token is cached across requests in this isolate.
const relay = createRelay({ fetch: (input, init) => fetch(input, init), now: () => Date.now() });

export default {
  fetch: (req: Request, env: Env): Promise<Response> => relay(req, env),
};
