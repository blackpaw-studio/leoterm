import { describe, expect, it } from "vitest";
import { fail, ok, rateLimited, transport, type Result } from "../src/github/errors";
import {
  BUDGET_REASON,
  createScheduler,
  HOST_BUDGET_PER_MIN,
  HOST_BUDGET_REASON,
  MAX_IN_FLIGHT,
  POLL_BUDGET_PER_MIN,
} from "../src/scheduler";
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
  it("queues a fetch beyond the 4 in flight until one finishes", async () => {
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

  it("shares the 4 slots between the lanes", async () => {
    const { scheduler } = setup();
    const gates = Array.from({ length: 6 }, (_, i) => gate(i));
    [0, 1].forEach((i) => void scheduler.user(gates[i].task));
    [2, 3, 4, 5].forEach((i) => void scheduler.poll(gates[i].task));
    await flush();
    expect(gates.map((g) => g.started.value)).toEqual([true, true, true, true, false, false]);
  });

  it("lets queued user fetches overtake queued poll fetches", async () => {
    const { scheduler } = setup();
    const blockers = Array.from({ length: MAX_IN_FLIGHT }, (_, i) => gate(i));
    blockers.forEach((b) => void scheduler.user(b.task));
    const order: string[] = [];
    const poll = scheduler.poll(async () => void order.push("poll"));
    const user = scheduler.user(async () => void order.push("user"));
    await flush();
    blockers[0].release();
    await Promise.all([poll, user]);
    expect(order).toEqual(["user", "poll"]);
  });

  it("releases the slot when a fetch rejects or throws synchronously", async () => {
    const { scheduler } = setup();
    await expect(scheduler.user(() => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
    await expect(
      scheduler.user(() => {
        throw new Error("sync");
      }),
    ).rejects.toThrow("sync");
    await Promise.all(Array.from({ length: MAX_IN_FLIGHT + 1 }, (_, i) => scheduler.user(async () => i)));
  });
});

describe("request budgets", () => {
  const spend = (scheduler: ReturnType<typeof setup>["scheduler"], lane: "user" | "poll", n: number) =>
    Promise.all(Array.from({ length: n }, () => scheduler[lane](async () => 1)));

  it("refuses the 41st poll request in a minute, but the user lane keeps going to 60", async () => {
    const { scheduler } = setup();
    await spend(scheduler, "poll", POLL_BUDGET_PER_MIN);
    await expect(scheduler.poll(async () => 1)).rejects.toThrow(BUDGET_REASON);
    await spend(scheduler, "user", HOST_BUDGET_PER_MIN - POLL_BUDGET_PER_MIN);
    await expect(scheduler.user(async () => 1)).rejects.toThrow(HOST_BUDGET_REASON);
  });

  it("counts user requests against the host's 60, so polls give way to them", async () => {
    const { scheduler } = setup();
    await spend(scheduler, "user", 30);
    await spend(scheduler, "poll", 30);
    await expect(scheduler.poll(async () => 1)).rejects.toThrow(/./);
  });

  it("frees budget as the rolling minute moves on", async () => {
    const { stub, scheduler } = setup();
    await spend(scheduler, "poll", POLL_BUDGET_PER_MIN);
    stub.clock.advance(60_001);
    await expect(scheduler.poll(async () => 1)).resolves.toBe(1);
  });

  it("does not count a refused request", async () => {
    const { stub, scheduler } = setup();
    await spend(scheduler, "poll", POLL_BUDGET_PER_MIN);
    await Promise.allSettled(Array.from({ length: 30 }, () => scheduler.poll(async () => 1)));
    stub.clock.advance(60_001);
    await expect(spend(scheduler, "poll", POLL_BUDGET_PER_MIN)).resolves.toHaveLength(POLL_BUDGET_PER_MIN);
  });
});

describe("pollCycle budget", () => {
  /** A task that makes `n` poll-lane requests, like a status refresh. */
  const requests = (scheduler: ReturnType<typeof setup>["scheduler"], ran: string[], n: number) => async (key: string) => {
    ran.push(key);
    await Promise.all(Array.from({ length: n }, () => scheduler.poll(async () => 1)));
    return ok(1);
  };

  it("starts only the keys whose requests fit, and defers the rest ahead of everything else", async () => {
    const { scheduler } = setup();
    const ran: string[] = [];
    const task = requests(scheduler, ran, 3);
    const first = await scheduler.pollCycle(keys(14), task, { cost: 3 });
    expect(ran).toHaveLength(13); // 13 x 3 = 39 of 40
    expect(first.deferred).toEqual(["o/r@b14"]);

    ran.length = 0;
    const second = await scheduler.pollCycle(keys(14), task, { cost: 3 }); // same minute: 1 request left
    expect(ran).toEqual([]);
    expect(second.deferred).toHaveLength(14);
  });

  it("serves the carried-over keys first once the minute window has moved on", async () => {
    const { stub, scheduler } = setup();
    const ran: string[] = [];
    const task = requests(scheduler, ran, 1);
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

  it("keeps one cycle's carry-over when a different set of keys is polled next", async () => {
    const { stub, scheduler } = setup();
    const ran: string[] = [];
    const task = requests(scheduler, ran, 1);
    await scheduler.pollCycle(keys(41), task); // b41 deferred
    await scheduler.pollCycle(["issues"], task); // e.g. the issues key in the same poll
    stub.clock.advance(60_001);
    ran.length = 0;
    await scheduler.pollCycle(keys(41), task);
    expect(ran[0]).toBe("o/r@b41");
  });

  it("defers a key whose request is refused mid-task instead of reporting it as a failure", async () => {
    const { scheduler } = setup();
    await Promise.all(Array.from({ length: 39 }, () => scheduler.poll(async () => 1)));
    const result = await scheduler.pollCycle(["a/b@x"], async () => {
      await scheduler.poll(async () => 1);
      const second = await scheduler.poll(async () => 1).then(() => ok(1), (e: Error) => fail(transport(e.message)));
      return second;
    });
    expect(result.deferred).toEqual(["a/b@x"]);
    expect(result.skipped).toEqual([]);
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
