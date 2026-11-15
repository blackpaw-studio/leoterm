import { describe, expect, it } from "vitest";
import { formatModel, formatMoney, formatPercent, formatReset, formatTokens, shortenPath } from "../src/format";

describe("formatTokens", () => {
  it.each([
    [0, "0"],
    [999, "999"],
    [1000, "1k"],
    [3100, "3.1k"],
    [29_400, "29k"],
    [154_000, "154k"],
    [999_499, "999k"],
    [999_999, "1M"],
    [1_000_000, "1M"],
    [1_200_000, "1.2M"],
  ])("%i -> %s", (n, out) => expect(formatTokens(n)).toBe(out));
});

describe("formatPercent", () => {
  it("rounds to the requested decimals", () => {
    expect(formatPercent(21.04, 0)).toBe("21%");
    expect(formatPercent(21.04, 1)).toBe("21.0%");
    expect(formatPercent(2.96, 1)).toBe("3.0%");
  });
  it("shows zero as 0", () => expect(formatPercent(0, 0)).toBe("0%"));
});

describe("formatMoney", () => {
  it("uses two decimals", () => {
    expect(formatMoney(35.356)).toBe("$35.36");
    expect(formatMoney(0)).toBe("$0.00");
    expect(formatMoney(1234.5)).toBe("$1234.50");
  });
});

describe("formatReset", () => {
  const now = Date.UTC(2026, 10, 12, 0, 0, 0);
  const at = (ms: number) => new Date(now + ms).toISOString();
  const MIN = 60_000;
  const HOUR = 60 * MIN;
  const DAY = 24 * HOUR;
  it("hours and minutes under a day", () => expect(formatReset(at(3 * HOUR + 50 * MIN + 20_000), now)).toBe("3h 50m"));
  it("days and hours from a day up", () => expect(formatReset(at(4 * DAY + 2 * HOUR + 59 * MIN), now)).toBe("4d 2h"));
  it("minutes only under an hour", () => expect(formatReset(at(12 * MIN), now)).toBe("12m"));
  it("under a minute", () => expect(formatReset(at(30_000), now)).toBe("<1m"));
  it("exact hour keeps zero minutes", () => expect(formatReset(at(2 * HOUR), now)).toBe("2h 0m"));
  it("past or now", () => {
    expect(formatReset(at(0), now)).toBe("now");
    expect(formatReset(at(-5 * MIN), now)).toBe("now");
  });
  it("unparseable is undefined", () => expect(formatReset("soon", now)).toBeUndefined());
});

describe("shortenPath", () => {
  it("shortens middle components, keeps the leaf", () => expect(shortenPath("~/.leo/agents/leoterm")).toBe("~/.l/a/leoterm"));
  it("handles absolute paths", () => expect(shortenPath("/opt/builds/app")).toBe("/o/b/app"));
  it("leaves short paths alone", () => {
    expect(shortenPath("~")).toBe("~");
    expect(shortenPath("~/code")).toBe("~/code");
    expect(shortenPath("/")).toBe("/");
  });
  it("ignores trailing and doubled slashes", () => expect(shortenPath("~/a//bcd/ef/")).toBe("~/a/b/ef"));
});

describe("formatModel", () => {
  it.each([
    ["claude-opus-5-5", "Opus 5.5"],
    ["claude-sonnet-5-5", "Sonnet 5.5"],
    ["claude-haiku-5-5", "Haiku 5.5"],
    ["claude-fable-5-2", "Fable 5.2"],
    ["claude-haiku-4-5-20251001", "Haiku 4.5"],
    ["claude-opus-5-5[1m]", "Opus 5.5 1M"],
    ["claude-opus-5-5-20261101[1m]", "Opus 5.5 1M"],
    ["gpt-5.1-codex", "gpt-5.1-codex"],
    ["Opus 5.5", "Opus 5.5"],
    ["claude-opus", "claude-opus"],
    ["", ""],
  ])("%s -> %s", (id, out) => expect(formatModel(id)).toBe(out));
});
