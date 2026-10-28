import { ComputerUseToolError } from "../contract/errors";

// The one list of apps Computer Use must never read or control. The plugin
// checks it before calling the helper, and sends it with every app command so
// the helper checks the same list against the bundle id an app name resolves
// to.
export const BUILTIN_BLOCKED_BUNDLE_IDS = [
  "com.apple.keychainaccess",
  "com.apple.loginwindow",
  // Owns the system authorization and keychain prompts ("wants to make
  // changes", "wants to use your confidential information"). An agent must
  // never click Allow or type a password there.
  "com.apple.SecurityAgent",
  "com.apple.Passwords",
  "com.1password.1password",
  "com.agilebits.onepassword7",
  "com.1password.safari",
  "com.bitwarden.desktop",
  "com.dashlane.dashlanephonefinal",
  "com.lastpass.LastPass",
  "com.nordsec.nordpass",
  "me.proton.pass.electron",
  "me.proton.pass.catalyst",
] as const;

// Display names of the built-in apps. They let the plugin refuse a name
// before any helper call; the helper still checks the resolved bundle id.
const BUILTIN_BLOCKED_NAMES = [
  "keychain access",
  "loginwindow",
  "passwords",
  "1password",
  "1password 7",
  "securityagent",
  "bitwarden",
  "dashlane",
  "lastpass",
  "nordpass",
  "proton pass",
];

const normalize = (value: string): string => value.trim().toLowerCase();

// The bundle ids the helper must refuse: the built-in list plus the user's
// extra ids.
export function blockedBundleIds(extraBlockedBundleIds?: Iterable<string>): string[] {
  const ids = new Set<string>(BUILTIN_BLOCKED_BUNDLE_IDS);
  for (const extra of extraBlockedBundleIds ?? []) {
    const trimmed = extra.trim();
    if (trimmed) {
      ids.add(trimmed);
    }
  }
  return [...ids];
}

export function isAppBlocked(
  appIdentifier: string,
  extraBlockedBundleIds?: Iterable<string>,
): boolean {
  const normalized = normalize(appIdentifier);
  if (!normalized) {
    return false;
  }
  if (BUILTIN_BLOCKED_NAMES.includes(normalized)) {
    return true;
  }
  return blockedBundleIds(extraBlockedBundleIds).some((id) => normalize(id) === normalized);
}

export function appBlockedError(appIdentifier: string): ComputerUseToolError {
  return new ComputerUseToolError(
    "app_blocked",
    `Computer Use is not allowed to use the app '${appIdentifier}' for safety reasons.`,
  );
}

export function assertAppNotBlocked(
  appIdentifier: string,
  extraBlockedBundleIds?: Iterable<string>,
): void {
  if (isAppBlocked(appIdentifier, extraBlockedBundleIds)) {
    throw appBlockedError(appIdentifier);
  }
}
