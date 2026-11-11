import { expect, it } from "vitest";
import { createEtagCache } from "../src/github/etagCache";

it("evicts the least recently used entry beyond capacity", () => {
  const cache = createEtagCache<number>(2);
  cache.set("a", { etag: "1", value: 1 });
  cache.set("b", { etag: "2", value: 2 });
  cache.get("a"); // a is now most recent
  cache.set("c", { etag: "3", value: 3 });
  expect(cache.get("b")).toBeUndefined();
  expect(cache.get("a")?.value).toBe(1);
  expect(cache.get("c")?.value).toBe(3);
});

it("defaults to 200 entries", () => {
  const cache = createEtagCache<number>();
  for (let i = 0; i < 201; i++) cache.set("k" + i, { etag: "e", value: i });
  expect(cache.size()).toBe(200);
  expect(cache.get("k0")).toBeUndefined();
});
