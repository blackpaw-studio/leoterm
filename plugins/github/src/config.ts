/**
 * Client ID of Blackpaw's GitHub OAuth App (device flow). Public, not a secret.
 * Empty until the app is registered: sign-in then shows "GitHub sign-in isn't configured in this build".
 */
export const OAUTH_CLIENT_ID = "Ov23li4ZOf3yNXiTAcoC";

/** Scopes requested at sign-in. */
export const OAUTH_SCOPE = "repo read:org";

/** Contribution ids. They must match macos/Bundled/Plugins/studio.blackpaw.github/leo-plugin.json (test/manifest.test.ts). */
export const PLUGIN_ID = "studio.blackpaw.github";
export const VIEW_ID = "github";
export const ACCESSORY_ID = "pr";
export const SECTION_ID = "assigned-issues";
export const COMMANDS = {
  newAgentFromIssue: "new-agent-from-issue",
  openPr: "open-pr",
  createPr: "create-pr",
  signIn: "sign-in",
  signOut: "sign-out",
} as const;
