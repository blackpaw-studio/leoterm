export const DEFAULT_ETAG_CAPACITY = 200;

export interface EtagEntry<V> {
  readonly etag: string;
  readonly value: V;
}

export interface EtagCache<V> {
  /** Marks the entry most recently used. */
  get(key: string): EtagEntry<V> | undefined;
  set(key: string, entry: EtagEntry<V>): void;
  clear(): void;
  size(): number;
}

/** LRU keyed by URL. Map iteration order is insertion order, so re-inserting is "touch". */
export function createEtagCache<V>(capacity: number = DEFAULT_ETAG_CAPACITY): EtagCache<V> {
  const entries = new Map<string, EtagEntry<V>>();
  return {
    get(key) {
      const entry = entries.get(key);
      if (entry === undefined) return undefined;
      entries.delete(key);
      entries.set(key, entry);
      return entry;
    },
    set(key, entry) {
      entries.delete(key);
      entries.set(key, entry);
      if (entries.size > capacity) entries.delete(entries.keys().next().value as string);
    },
    clear: () => entries.clear(),
    size: () => entries.size,
  };
}
