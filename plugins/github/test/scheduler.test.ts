import { describe, expect, it } from "vitest";
import { fail, ok, rateLimited, transport, type Result } from "../src/github/errors";
import { createScheduler, MAX_IN_FLIGHT, POLL_BUDGET_PER_MIN } from "../src/scheduler";
import { createStubLeo } from "./stubLeo";

/** A task that stays in flight until `release()` is called. */
const gate = <T>(value: T) => {
  let release!: () => void;
  const started = { value: false };
  const task = (): Promise<T> => {
    started.value = true;
    return new Promise<T>((resolve) => {
      release = () => resolve(value);
    });
  };
  return { task, release: () => release(), started };
};
const flush = async (): Promise<void> => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};
const setup = () => {
  const stub = createStubLeo();
  return { stub, scheduler: createScheduler(stub.clock) };
};
const keys = (n: number, from = 1) => Array.from({ length: n }, (_, i) => "o/r@b" + (from + i));
const okTask = async (): Promise<Result<number>> => ok(1);

describe("in-flight limit", () => {
  it("queues a request beyond the 4 in flight until one finishes", async () => {
    const { scheduler } = setup();
    const gates = Array.from({ length: MAX_IN_FLIGHT + 1 }, (_, i) => gate(i));
    const runs = gates.map((g) => scheduler.user(g.task));
    await flush();
    expect(gates.map((g) => g.started.value)).toEqual([true, true, true, true, false]);
    gates[0].release();
    await flush();
    expect(gates[4].started.value).toBe(true);
    gates.slice(1).forEach((g) => g.release());
    expect(await Promise.all(runs)).toEqual([0, 1, 2, 3, 4]);
  });

  it("lets queued user work overtake queued poll work", async () => {
    const { scheduler } = setup();
    const blockers = Array.from({ length: MAX_IN_FLIGHT }, (_, i) => gate(i));
    blockers.forEach((b) => void scheduler.user(b.task));
    const order: string[] = [];
    const poll = scheduler.pollCycle(["o/r@poll"], async () => {
      order.push("poll");
      return ok(1);
    });
    const user = scheduler.user(async () => {
      order.push("user");
    });
    await flush();
    blockers[0].release();
    await Promise.all([poll, user]);
    expect(order).toEqual(["user", "poll"]);
  });

  it("releases the slot when a task rejects", async () => {
    const { scheduler } = setup();
    await expect(scheduler.user(() => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
    await expect(scheduler.user(async () => 7)).resolves.toBe(7);
  });
});

describe("poll budget", () => {
  it("runs 40 keys and leaves the 41st for the next cycle, ahead of everything else", async () => {
    const { scheduler } = setup();
    const ran: string[] = [];
    const task = async (key: string) => {
      ran.push(key);
      return ok(1);
    };
    const first = await scheduler.pollCycle(keys(POLL_BUDGET_PER_MIN + 1), task);
    expect(ran).toHaveLength(POLL_BUDGET_PER_MIN);
    expect(first.deferred).toEqual(["o/r@b41"]);

    ran.length = 0;
    await scheduler.pollCycle(keys(POLL_BUDGET_PER_MIN + 1), task); // same minute: window is spent
    expect(ran).toEqual([]);
  });

  it("serves the carried-over keys first once the minute window has moved on", async () => {
    const { stub, scheduler } = setup();
    const ran: string[] = [];
    const task = async (key: string) => {
      ran.push(key);
      return ok(1);
    };
    const all = keys(45);
    await scheduler.pollCycle(all, task);
    expect(ran).toHaveLength(40);
    stub.clock.advance(60_001);
    ran.length = 0;
    const second = await scheduler.pollCycle(all, task);
    expect(ran.slice(0, 5)).toEqual(keys(5, 41));
    expect(ran).toHaveLength(40);
    expect(second.deferred).toEqual(keys(5, 36));
  });

  it("deduplicates repeated owner/repo@branch keys", async () => {
    const { scheduler } = setup();
    const ran: string[] = [];
    await scheduler.pollCycle(["a/b@x", "a/b@x", "a/b@y"], async (k) => {
      ran.push(k);
      return ok(1);
    });
    expect(ran).toEqual(["a/b@x", "a/b@y"]);
  });

  it("does not count user-lane requests against the poll budget", async () => {
    const { scheduler } = setup();
    await Promise.all(Array.from({ length: 50 }, () => scheduler.user(async () => 1)));
    const result = await scheduler.pollCycle(keys(POLL_BUDGET_PER_MIN), okTask);
    expect(result.deferred).toEqual([]);
  });

  it("returns each key's result and skips Transport failures silently", async () => {
    const { scheduler } = setup();
    const result = await scheduler.pollCycle(["a/b@x", "a/b@y"], async (k) =>
      k === "a/b@x" ? fail(transport("offline")) : ok(2),
    );
    expect([...result.results.keys()]).toEqual(["a/b@y"]);
    expect(result.skipped).toEqual(["a/b@x"]);
  });
});

describe("pause", () => {
  it("drops poll work while paused, but user requests still run", async () => {
    const { stub, scheduler } = setup();
    scheduler.pauseUntil(stub.clock.now() + 60_000);
    const ran: string[] = [];
    const result = await scheduler.pollCycle(["a/b@x"], async (k) => {
      ran.push(k);
      return ok(1);
    });
    expect(ran).toEqual([]);
    expect(result.dropped).toEqual(["a/b@x"]);
    await expect(scheduler.user(async () => "ok")).resolves.toBe("ok");
  });

  it("resumes once the pause expires", async () => {
    const { stub, scheduler } = setup();
    scheduler.pauseUntil(stub.clock.now() + 60_000);
    expect(scheduler.pausedUntil()).toBe(stub.clock.now() + 60_000);
    stub.clock.advance(60_000);
    expect(scheduler.pausedUntil()).toBeNull();
    const result = await scheduler.pollCycle(["a/b@x"], okTask);
    expect(result.results.size).toBe(1);
  });

  it("pauses itself on a RateLimited poll result and drops the rest of the cycle", async () => {
    const { stub, scheduler } = setup();
    const resetAt = stub.clock.now() + 120_000;
    const ran: string[] = [];
    const result = await scheduler.pollCycle(["a/b@1", "a/b@2", "a/b@3", "a/b@4", "a/b@5", "a/b@6"], async (k) => {
      ran.push(k);
      return k === "a/b@1" ? fail(rateLimited(resetAt)) : ok(1);
    });
    // the first four start together; the queued two are dropped
    expect(ran).toEqual(["a/b@1", "a/b@2", "a/b@3", "a/b@4"]);
    expect(result.dropped).toEqual(["a/b@5", "a/b@6"]);
    expect(scheduler.pausedUntil()).toBe(resetAt);
  });

  it("never shortens an existing pause", async () => {
    const { stub, scheduler } = setup();
    const later = stub.clock.now() + 300_000;
    scheduler.pauseUntil(later);
    scheduler.pauseUntil(stub.clock.now() + 1_000);
    expect(scheduler.pausedUntil()).toBe(later);
  });
});
