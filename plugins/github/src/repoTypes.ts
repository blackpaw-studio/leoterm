/** Injected repo parser (lane A's `parseRepo` satisfies this). */
export type ParseRepo = (raw: string) => { readonly owner: string; readonly repo: string } | null;
