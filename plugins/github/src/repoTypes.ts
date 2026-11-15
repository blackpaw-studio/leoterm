import type { RepoRef } from "./repoRef";

/** Injected repo parser (`parseRepo` in repoRef.ts satisfies this). */
export type ParseRepo = (raw: string) => RepoRef | null;
