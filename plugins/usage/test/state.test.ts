import { describe, expect, it } from "vitest";
import { BACKOFF_MS, initialState, isDue, reduce } from "../src/state";
import type { UsageWindow } from "../src/window";

const NOW = 1_000_000;
const w: UsageWindow[] = [{ key: "session", label: "Session", percent: 40 }];

describe("account state reducer", () => {
  it("starts loading with no data", () => {
    expect(initialState()).toMatchObject({ status: "loading", windows: [] });
  });

  it("ok replaces windows and stamps the update time", () => {
    const s = reduce(initialState(), { kind: "ok", windows: w }, NOW);
    expect(s).toMatchObject({ status: "ok", windows: w, updatedAtMs: NOW });
  });

  it("an ok response without windows reads as no usage data", () => {
    const s = reduce(initialState(), { kind: "ok", windows: [] }, NOW);
    expect(s).toMatchObject({ status: "error", message: "No usage data", windows: [] });
  });

  it("a failure after a good fetch goes stale and keeps the last values", () => {
    const good = reduce(initialState(), { kind: "ok", windows: w }, NOW);
    const s = reduce(good, { kind: "failed", message: "HTTP 500" }, NOW + 5);
    expect(s).toMatchObject({ status: "stale", windows: w, updatedAtMs: NOW, message: "HTTP 500" });
  });

  it("a failure with nothing to show is an error", () => {
    expect(reduce(initialState(), { kind: "failed", message: "HTTP 500" }, NOW)).toMatchObject({
      status: "error",
      message: "HTTP 500",
    });
  });

  it("401 is expired and drops values", () => {
    const good = reduce(initialState(), { kind: "ok", windows: w }, NOW);
    expect(reduce(good, { kind: "unauthorized" }, NOW)).toMatchObject({ status: "expired", windows: [] });
  });

  it("credentialNeedsAuthorization is needsAuthorization", () => {
    expect(reduce(initialState(), { kind: "needsAuthorization" }, NOW).status).toBe("needsAuthorization");
  });

  it("a success clears an earlier backoff and message", () => {
    const limited = reduce(initialState(), { kind: "rateLimited" }, NOW);
    const s = reduce(limited, { kind: "ok", windows: w }, NOW + 1);
    expect(s.backoffUntilMs).toBeUndefined();
    expect(s.message).toBeUndefined();
  });

  it("429 backs the account off for 15 minutes and keeps stale values", () => {
    const good = reduce(initialState(), { kind: "ok", windows: w }, NOW);
    const s = reduce(good, { kind: "rateLimited" }, NOW + 10);
    expect(BACKOFF_MS).toBe(15 * 60_000);
    expect(s).toMatchObject({ status: "stale", backoffUntilMs: NOW + 10 + BACKOFF_MS });
    expect(isDue(s, NOW + 10 + BACKOFF_MS - 1)).toBe(false);
    expect(isDue(s, NOW + 10 + BACKOFF_MS)).toBe(true);
  });

  it("an account with no backoff is always due", () => {
    expect(isDue(initialState(), NOW)).toBe(true);
  });
});
