import type { FetchResponse, JSONValue, Leo } from "../../../sdk/leo";
import type { Clock } from "../clock";
import { createEtagCache, type EtagCache } from "./etagCache";
import { fail, http, ok, rateLimited, transport, unauthorized, type GitHubError, type Result } from "./errors";
import { base64ToBytes, utf8ToString } from "./text";

export const API_ORIGIN = "https://api.github.com";
const API_HOST = "api.github.com";
const API_VERSION = "2022-11-28";
const DEFAULT_RETRY_AFTER_SEC = 60;

/** A decoded 2xx response. `json` is unvalidated: callers narrow it (it is `undefined` when the body isn't JSON). */
export interface ApiResponse<T = unknown> {
  readonly status: number;
  /** Header names lower-cased. */
  readonly headers: Readonly<Record<string, string>>;
  readonly text: string;
  readonly json: T | undefined;
  /** false when served from the ETag cache after a 304. */
  readonly fresh: boolean;
}

export interface RequestOptions {
  /** Bearer token, or null for unauthenticated calls. A token is only ever sent to https://api.github.com. */
  readonly auth: string | null;
  /** JSON-encoded when present. */
  readonly body?: JSONValue;
}

export interface GitHubClient {
  /** `pathOrUrl` is an API path ("/user") or an absolute https URL. */
  request<T = unknown>(method: string, pathOrUrl: string, options: RequestOptions): Promise<Result<ApiResponse<T>>>;
  /** GET with If-None-Match from an LRU keyed by URL; a 304 returns the cached response with `fresh: false`. */
  getCached<T = unknown>(pathOrUrl: string, options: { readonly auth: string | null }): Promise<Result<ApiResponse<T>>>;
  /** Resolves to the response's `data`. A response with `errors[]` becomes `Http` (or `RateLimited`). */
  graphql<T = unknown>(query: string, variables: JSONValue, options: { readonly auth: string | null }): Promise<Result<T>>;
  /** Forget every cached ETag (call on sign-out). */
  clearCache(): void;
}

const absolute = (pathOrUrl: string): string => (pathOrUrl.startsWith("/") ? API_ORIGIN + pathOrUrl : pathOrUrl);

const hostOf = (url: string): string | null => /^https:\/\/([^/?#]+)/i.exec(url)?.[1]?.toLowerCase() ?? null;

const lowerKeys = (headers: Record<string, string>): Record<string, string> =>
  Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));

const decodeBody = (res: FetchResponse): string =>
  res.bodyEncoding === "base64" ? utf8ToString(base64ToBytes(res.body)) : res.body;

const parseJson = (text: string): unknown => {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
};

const isExhausted = (headers: Record<string, string>): boolean => headers["x-ratelimit-remaining"] === "0";

/** Epoch ms at which a limited caller may retry, from x-ratelimit-reset, else retry-after, else a default. */
const resetAt = (headers: Record<string, string>, nowMs: number): number => {
  const reset = Number(headers["x-ratelimit-reset"]);
  if (isExhausted(headers) && Number.isFinite(reset) && reset > 0) return reset * 1000;
  const retry = Number(headers["retry-after"]);
  const seconds = Number.isFinite(retry) && retry >= 0 ? retry : DEFAULT_RETRY_AFTER_SEC;
  return nowMs + seconds * 1000;
};

/** GitHub's secondary (abuse) limits answer 403/429 without an exhausted quota; only the message says so. */
const mentionsRateLimit = (text: string): boolean => /rate limit/i.test(text);

const classify = (status: number, headers: Record<string, string>, text: string, nowMs: number): GitHubError => {
  if (status === 401) return unauthorized();
  const limited =
    (status === 403 || status === 429) &&
    (isExhausted(headers) || headers["retry-after"] !== undefined || mentionsRateLimit(text));
  return limited ? rateLimited(resetAt(headers, nowMs)) : http(status, text);
};

export function createGitHubClient(
  leo: Pick<Leo, "fetch">,
  clock: Clock,
  cache: EtagCache<ApiResponse> = createEtagCache<ApiResponse>(),
): GitHubClient {
  /** One round trip. 2xx and 304 are `ok`; everything else is classified. */
  async function exchange(
    method: string,
    url: string,
    options: RequestOptions,
    extraHeaders: Record<string, string> = {},
  ): Promise<Result<ApiResponse>> {
    if (options.auth !== null && hostOf(url) !== API_HOST) {
      return fail(transport("refusing to send credentials to " + (hostOf(url) ?? "a non-https URL")));
    }
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": API_VERSION,
      ...(options.auth === null ? {} : { Authorization: "Bearer " + options.auth }),
      ...(options.body === undefined ? {} : { "Content-Type": "application/json" }),
      ...extraHeaders,
    };
    const init = { method, headers, ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }) };
    let res: FetchResponse;
    try {
      res = await leo.fetch(url, init);
    } catch (e) {
      return fail(transport(e instanceof Error ? e.message : String(e)));
    }
    const text = decodeBody(res);
    const resHeaders = lowerKeys(res.headers);
    if ((res.status >= 200 && res.status < 300) || res.status === 304) {
      return ok({ status: res.status, headers: resHeaders, text, json: parseJson(text), fresh: true });
    }
    return fail(classify(res.status, resHeaders, text, clock.now()));
  }

  const request: GitHubClient["request"] = async <T>(method: string, pathOrUrl: string, options: RequestOptions) => {
    const res = await exchange(method, absolute(pathOrUrl), options);
    // 304 can only follow a conditional request, which request() never makes.
    if (res.ok && res.value.status === 304) return fail(http(304, ""));
    return res as Result<ApiResponse<T>>;
  };

  const getCached: GitHubClient["getCached"] = async <T>(pathOrUrl: string, options: { auth: string | null }) => {
    const url = absolute(pathOrUrl);
    const cached = cache.get(url);
    const res = await exchange("GET", url, options, cached ? { "If-None-Match": cached.etag } : {});
    if (!res.ok) return res;
    if (res.value.status === 304) {
      return cached ? ok({ ...cached.value, fresh: false } as ApiResponse<T>) : fail(http(304, ""));
    }
    const etag = res.value.headers.etag;
    if (etag !== undefined) cache.set(url, { etag, value: res.value });
    return res as Result<ApiResponse<T>>;
  };

  const graphql: GitHubClient["graphql"] = async <T>(query: string, variables: JSONValue, options: { auth: string | null }) => {
    const res = await exchange("POST", API_ORIGIN + "/graphql", { auth: options.auth, body: { query, variables } });
    if (!res.ok) return res;
    const json = res.value.json as { data?: T; errors?: Array<{ type?: string }> } | undefined;
    if (json?.errors && json.errors.length > 0) {
      const limited = json.errors.some((e) => e.type === "RATE_LIMITED");
      return fail(limited ? rateLimited(resetAt(res.value.headers, clock.now())) : http(res.value.status, res.value.text));
    }
    return ok(json?.data as T);
  };

  return { request, getCached, graphql, clearCache: () => cache.clear() };
}
