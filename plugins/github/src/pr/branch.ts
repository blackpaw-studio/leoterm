/** Branch name → PR title: separators become spaces, first letter capitalised. */
export const humaniseBranch = (branch: string): string => {
  const words = branch.replace(/[/_-]+/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
};
