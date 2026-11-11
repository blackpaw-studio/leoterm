/** Classified failure of a GitHub call. Callers branch on `kind`; nothing throws. */
export type GitHubError =
  | { readonly kind: "Unauthorized" }
  /** `resetAt` is epoch milliseconds, the earliest time to retry. */
  | { readonly kind: "RateLimited"; readonly resetAt: number }
  | { readonly kind: "Http"; readonly status: number; readonly body: string }
  /** The `leo.fetch` promise rejected: host not allowed, Leo's own 60/min limit, oversize body, no network. */
  | { readonly kind: "Transport"; readonly reason: string };

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: GitHubError };

export const ok = <T>(value: T): Result<T> => ({ ok: true, value });
export const fail = (error: GitHubError): Result<never> => ({ ok: false, error });

export const unauthorized = (): GitHubError => ({ kind: "Unauthorized" });
export const rateLimited = (resetAt: number): GitHubError => ({ kind: "RateLimited", resetAt });
export const http = (status: number, body: string): GitHubError => ({ kind: "Http", status, body });
export const transport = (reason: string): GitHubError => ({ kind: "Transport", reason });
