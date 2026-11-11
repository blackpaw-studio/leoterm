import type { GitHubClient } from "./client";
import type { GitHubError, Result } from "./errors";

/** Called for every failed call, before the caller sees the result. `auth` is the token the call used. */
export type FailureObserver = (error: GitHubError, auth: string | null) => Promise<void> | void;

/**
 * Wraps a client so one place reacts to 401s and rate limits, whichever lane or flow made the call.
 * The observer finishes (e.g. the sign-out redraw) before the failed result is returned.
 */
export function observeClient(inner: GitHubClient, observe: FailureObserver): GitHubClient {
  const watch = async <T>(auth: string | null, call: Promise<Result<T>>): Promise<Result<T>> => {
    const res = await call;
    if (!res.ok) await observe(res.error, auth);
    return res;
  };
  return {
    request: (method, path, options) => watch(options.auth, inner.request(method, path, options)),
    getCached: (path, options) => watch(options.auth, inner.getCached(path, options)),
    graphql: (query, variables, options) => watch(options.auth, inner.graphql(query, variables, options)),
    clearCache: () => inner.clearCache(),
  };
}
