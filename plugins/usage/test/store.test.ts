import { describe, expect, it } from "vitest";
import { MAX_STATE_CHARS, emptyPersisted, loadPersisted, savePersisted, type Persisted } from "../src/store";
import { createStubLeo } from "./stubLeo";

const sample: Persisted = {
  order: ["a", "b"],
  labels: { a: "Work" },
  snapshots: { a: { windows: [{ key: "session", label: "Session", percent: 10 }], updatedAtMs: 5 } },
};

describe("persisted state", () => {
  it("round-trips through leo.secrets under the `state` key", async () => {
    const { leo, secretStore } = createStubLeo();
    await savePersisted(leo, sample);
    expect(secretStore.has("state")).toBe(true);
    expect(await loadPersisted(leo)).toEqual(sample);
  });

  it("loads empty when nothing is stored", async () => {
    expect(await loadPersisted(createStubLeo().leo)).toEqual(emptyPersisted());
  });

  it("loads empty when the stored value is corrupt", async () => {
    const stub = createStubLeo();
    stub.secretStore.set("state", "{nope");
    expect(await loadPersisted(stub.leo)).toEqual(emptyPersisted());
  });

  it("drops malformed entries but keeps good ones", async () => {
    const stub = createStubLeo();
    stub.secretStore.set("state", JSON.stringify({ order: ["a", 3], labels: { a: "x", b: 4 }, snapshots: { a: 7 } }));
    expect(await loadPersisted(stub.leo)).toEqual({ order: ["a"], labels: { a: "x" }, snapshots: {} });
  });

  it("trims the oldest snapshots to stay under the host's value cap, keeping order and labels", async () => {
    const stub = createStubLeo();
    const ids = Array.from({ length: 120 }, (_, i) => "acct-" + i);
    const snapshots = Object.fromEntries(
      ids.map((id, i) => [
        id,
        {
          windows: ["session", "weekly", "weekly-opus", "weekly-sonnet"].map((key) => ({ key, label: key, percent: 50, resetsAtMs: 1767276840000 })),
          updatedAtMs: i,
        },
      ]),
    ) as Persisted["snapshots"];
    await savePersisted(stub.leo, { order: ids, labels: { "acct-0": "Zero" }, snapshots });
    const raw = stub.secretStore.get("state") ?? "";
    expect(raw.length).toBeLessThanOrEqual(MAX_STATE_CHARS);
    const back = await loadPersisted(stub.leo);
    expect(back.order).toEqual(ids);
    expect(back.labels).toEqual({ "acct-0": "Zero" });
    expect(back.snapshots["acct-119"]).toBeDefined(); // newest kept
    expect(back.snapshots["acct-0"]).toBeUndefined(); // oldest dropped
  });

  it("never persists anything token-shaped: only order, labels and snapshots", async () => {
    const stub = createStubLeo();
    await savePersisted(stub.leo, { ...sample, token: "secret" } as Persisted);
    expect(Object.keys(JSON.parse(stub.secretStore.get("state") ?? "{}")).sort()).toEqual(["labels", "order", "snapshots"]);
  });
});
