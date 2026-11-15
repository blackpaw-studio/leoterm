import type { JSONValue, Leo, SlotID, SlotRoot } from "../../../sdk/leo";
import type { Clock } from "../clock";
import { OAUTH_CLIENT_ID } from "../config";
import type { GitHubClient } from "../github/client";
import type { GitHubError } from "../github/errors";
import { createDeviceFlow, VERIFICATION_URL, type DeviceFlowState } from "./deviceFlow";

const TOKEN_KEY = "token";
export const SIGN_IN_CALLBACK = "sign-in";

/** What the session draws. Replaceable so the real UI layer can supply its own components. */
export interface SignInViews {
  signedOut(slot: SlotID): SlotRoot;
  flow(slot: SlotID, state: DeviceFlowState): SlotRoot;
  signedIn(): SlotRoot;
}

const signInAction = (slot: SlotID, title: string) =>
  ({ type: "callback", id: SIGN_IN_CALLBACK, title, payload: { slot } as unknown as JSONValue }) as const;

/** Each slot says what signing in unlocks there. */
const signedOutMessage = (slot: SlotID): string => {
  switch (slot.kind) {
    case "section":
      return "Connect your GitHub account to see the issues assigned to you.";
    case "palette":
      return "Connect your GitHub account to continue.";
    default:
      return "Connect your GitHub account to see pull requests and checks.";
  }
};

export const defaultSignInViews: SignInViews = {
  signedOut: (slot) => ({
    type: "EmptyState",
    title: "Sign in to GitHub",
    message: signedOutMessage(slot),
    sfSymbol: "person.crop.circle.badge.checkmark",
    actions: [signInAction(slot, "Sign In")],
  }),
  flow: (slot, state) => {
    switch (state.kind) {
      case "NotConfigured":
        return { type: "EmptyState", title: "GitHub sign-in isn't configured in this build" };
      case "Starting":
        return { type: "Loading", message: "Contacting GitHub…" };
      case "AwaitingUser":
        return [
          { type: "Detail", markdown: "Enter this code on GitHub:\n\n## " + state.userCode },
          {
            type: "List",
            sections: [
              {
                items: [
                  { id: "open", title: "Open github.com/login/device", actions: [{ type: "openURL", url: VERIFICATION_URL }] },
                  { id: "copy", title: "Copy code", actions: [{ type: "copy", text: state.userCode }] },
                ],
              },
            ],
          },
        ];
      case "Expired":
        return { type: "EmptyState", title: "Code expired", actions: [signInAction(slot, "Retry")] };
      case "Denied":
        return { type: "EmptyState", title: "Denied", actions: [signInAction(slot, "Retry")] };
      case "Failed":
        return { type: "EmptyState", title: "Sign-in failed", message: state.message, actions: [signInAction(slot, "Retry")] };
    }
  },
  signedIn: () => ({ type: "Loading", message: "Signed in. Loading…" }),
};

export interface SessionDeps {
  readonly leo: Pick<Leo, "render" | "secrets" | "fetch" | "after" | "log">;
  readonly clock: Clock;
  readonly client: Pick<GitHubClient, "clearCache">;
  /** Defaults to the build's OAUTH_CLIENT_ID. Tests inject one. */
  readonly clientId?: string;
  readonly views?: SignInViews;
  /** Wraps device-flow network calls (the scheduler's user lane). */
  readonly run?: <T>(task: () => Promise<T>) => Promise<T>;
}

export type SessionEvent = "signedIn" | "signedOut";

export interface Session {
  /** Read the stored token. Call on `activate`. */
  load(): Promise<void>;
  /** The in-memory token. Only ever passed to the GitHub client as a bearer. Never log or render it. */
  token(): string | null;
  /** Remember a slot so a sign-out can redraw it. */
  track(slot: SlotID): void;
  /** Draw the "Sign in to GitHub" state on `slot`. */
  renderSignedOut(slot: SlotID): void;
  /** Begin the device flow, drawing its progress on `slot`. */
  startSignIn(slot: SlotID): Promise<void>;
  /** Delete the token and caches, stop the flow, and redraw every known slot signed out. */
  signOut(): Promise<void>;
  /**
   * Feed any request failure here. Returns true for an Unauthorized, and signs out unless it is stale (see below).
   * Pass the token the failed request used, so a late 401 from a previous session can't sign out a new one.
   */
  handleError(error: GitHubError, usedToken?: string | null): Promise<boolean>;
  /** Fires after sign-in and sign-out (the plugin starts or stops polling). Returns an unsubscribe. */
  subscribe(listener: (event: SessionEvent) => void): () => void;
}

const slotKey = (slot: SlotID): string => JSON.stringify(slot);

export function createSession(deps: SessionDeps): Session {
  const { leo, clock, client } = deps;
  const views = deps.views ?? defaultSignInViews;
  const clientId = deps.clientId ?? OAUTH_CLIENT_ID;
  let token: string | null = null;
  let flowSlot: SlotID | null = null;
  const slots = new Map<string, SlotID>();
  const listeners = new Set<(event: SessionEvent) => void>();

  const emit = (event: SessionEvent): void => listeners.forEach((l) => l(event));
  const track = (slot: SlotID): void => void slots.set(slotKey(slot), slot);

  const flow = createDeviceFlow({
    leo,
    clock,
    clientId,
    run: deps.run,
    onState: (state) => {
      if (flowSlot) leo.render(flowSlot, views.flow(flowSlot, state));
    },
    onToken: async (accessToken) => {
      await leo.secrets.set(TOKEN_KEY, accessToken);
      token = accessToken;
      if (flowSlot) leo.render(flowSlot, views.signedIn());
      flowSlot = null;
      emit("signedIn");
    },
  });

  async function endSession(): Promise<void> {
    flow.cancel();
    flowSlot = null;
    token = null;
    client.clearCache();
    try {
      await leo.secrets.delete(TOKEN_KEY);
    } catch {
      leo.log("warn", "Couldn't delete the stored GitHub token");
    }
    slots.forEach((slot) => leo.render(slot, views.signedOut(slot)));
    emit("signedOut");
  }

  return {
    async load() {
      try {
        const stored = await leo.secrets.get(TOKEN_KEY);
        token = stored === null || stored === "" ? null : stored;
      } catch {
        leo.log("warn", "Couldn't read the stored GitHub token");
        token = null;
      }
    },
    token: () => token,
    track,
    renderSignedOut: (slot) => {
      track(slot);
      leo.render(slot, views.signedOut(slot));
    },
    async startSignIn(slot) {
      track(slot);
      flowSlot = slot;
      await flow.start();
    },
    signOut: endSession,
    async handleError(error, usedToken) {
      if (error.kind !== "Unauthorized") return false;
      const stale = usedToken !== undefined && usedToken !== token;
      if (!stale && token !== null) await endSession();
      return true;
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
  };
}
