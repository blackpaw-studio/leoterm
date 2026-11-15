import type { StubResponse } from "./stubLeo";

/** A recorded response: status, a trimmed header subset, and the body (JSON value or raw text). */
export type Fixture = Required<Pick<StubResponse, "status" | "headers" | "body">>;

/** Fixtures are already StubResponse-shaped; this only pins the type of an imported JSON file. */
export const asResponse = (fixture: Fixture): StubResponse => ({ ...fixture });
