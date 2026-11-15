const SLUG_MAX = 40;

const slug = (title: string): string =>
  title
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, SLUG_MAX)
    .replace(/-+$/, "");

/** `issue-<n>-<slug(title, 40)>`; `issue-<n>` when the slug is empty. */
export const branchName = (n: number, title: string): string => {
  const s = slug(title);
  return s ? `issue-${n}-${s}` : `issue-${n}`;
};
