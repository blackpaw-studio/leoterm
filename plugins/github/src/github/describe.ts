import type { GitHubError } from "./errors";

/** One user-facing sentence for a failed GitHub call. */
export const describeError = (e: GitHubError): string => {
  switch (e.kind) {
    case "Unauthorized":
      return "Sign in to GitHub to continue.";
    case "RateLimited":
      return "GitHub rate limit reached. Try again later.";
    case "Http":
      return `GitHub returned ${e.status}.`;
    case "Transport":
      return `Couldn't reach GitHub (${e.reason}).`;
  }
};
