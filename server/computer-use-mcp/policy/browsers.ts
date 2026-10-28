import { ComputerUseError, ComputerUseToolError } from "../contract/errors";
import { appBlockedError } from "./deny-list";

interface WebBrowser {
  bundleId: string;
  // The display name the plugin refuses before any helper call. Left out
  // when another app can have the same name ("Arc", "Dia", "Orion", "Zen"):
  // the helper refuses such a browser by the bundle id the name resolves to.
  name?: string;
}

// The one list of web browsers. Unless the user allows browsers in the
// settings, Computer Use refuses them with `use_browser_tools`: a background
// browser brings itself to the front for some key presses, which interrupts
// the user, while Paseo's browser tools work in Paseo's own browser in the
// background. The plugin checks the bundle ids and display names before any
// helper call, and adds the bundle ids to the block list of every app command,
// so the helper also refuses a partial name ("chrome") that resolves to one.
export const WEB_BROWSERS: readonly WebBrowser[] = [
  { bundleId: "com.google.Chrome", name: "Google Chrome" },
  { bundleId: "com.google.Chrome.beta", name: "Google Chrome Beta" },
  { bundleId: "com.google.Chrome.dev", name: "Google Chrome Dev" },
  { bundleId: "com.google.Chrome.canary", name: "Google Chrome Canary" },
  { bundleId: "org.chromium.Chromium", name: "Chromium" },
  { bundleId: "com.apple.Safari", name: "Safari" },
  { bundleId: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview" },
  { bundleId: "com.microsoft.edgemac", name: "Microsoft Edge" },
  { bundleId: "com.microsoft.edgemac.Beta", name: "Microsoft Edge Beta" },
  { bundleId: "com.microsoft.edgemac.Dev", name: "Microsoft Edge Dev" },
  { bundleId: "com.microsoft.edgemac.Canary", name: "Microsoft Edge Canary" },
  { bundleId: "company.thebrowser.Browser" },
  { bundleId: "com.brave.Browser", name: "Brave Browser" },
  { bundleId: "org.mozilla.firefox", name: "Firefox" },
  { bundleId: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition" },
  { bundleId: "org.mozilla.nightly", name: "Firefox Nightly" },
  { bundleId: "com.operasoftware.Opera", name: "Opera" },
  { bundleId: "com.vivaldi.Vivaldi", name: "Vivaldi" },
  { bundleId: "com.kagi.kagimacOS" },
  { bundleId: "app.zen-browser.zen" },
  { bundleId: "company.thebrowser.dia" },
  { bundleId: "com.duckduckgo.macos.browser", name: "DuckDuckGo" },
  // DuckDuckGo from the Mac App Store (MAIN_BUNDLE_IDENTIFIER_PREFIX in
  // macOS/Configuration/AppStore.xcconfig of duckduckgo/apple-browsers).
  { bundleId: "com.duckduckgo.mobile.ios" },
  { bundleId: "com.brave.Browser.beta", name: "Brave Browser Beta" },
  { bundleId: "com.brave.Browser.nightly", name: "Brave Browser Nightly" },
  // Firefox-based builds derive the bundle id from `--with-distribution-id`
  // and the display name (`moz_mac_bundle_id` in toolkit/moz.configure):
  // org.torproject + "Tor Browser", net.librewolf + "LibreWolf", and
  // net.waterfox + "Waterfox".
  { bundleId: "org.torproject.torbrowser", name: "Tor Browser" },
  { bundleId: "net.librewolf.librewolf", name: "LibreWolf" },
  { bundleId: "net.waterfox.waterfox", name: "Waterfox" },
  // Opera GX and Vivaldi Snapshot are closed source and their vendors publish
  // no bundle id. These come from the Homebrew casks (`opera-gx`,
  // `vivaldi@snapshot`) and, for Opera GX, Opera's forum; an id that is wrong
  // matches nothing.
  { bundleId: "com.operasoftware.OperaGX", name: "Opera GX" },
  { bundleId: "com.vivaldi.Vivaldi.snapshot", name: "Vivaldi Snapshot" },
];

// A web app made from a browser gets its own bundle id per app, so these are
// matched by prefix.
export const WEB_APP_BUNDLE_ID_PREFIXES: readonly string[] = ["com.google.Chrome.app.", "com.apple.Safari.WebApp."];

export const BROWSER_BUNDLE_IDS: readonly string[] = WEB_BROWSERS.map((browser) => browser.bundleId);

export const USE_BROWSER_TOOLS_MESSAGE =
  "This is a web browser. Use Paseo's browser tools for web pages (browser_new_tab, browser_navigate, browser_snapshot, browser_click, browser_type, browser_close_tab). They run in Paseo's own browser in the background and do not interrupt the user. If a site needs a login, ask the user to sign in in Paseo's browser, then continue. If these tools are not available, ask the user to turn on browser tools in Paseo settings, or to allow web browsers in Computer Use settings.";

const normalize = (value: string): string => value.trim().toLowerCase();

const browserIds = new Set(BROWSER_BUNDLE_IDS.map(normalize));
const webAppPrefixes = WEB_APP_BUNDLE_ID_PREFIXES.map(normalize);
const bundleIdsByName = new Map(
  WEB_BROWSERS.flatMap((browser) => (browser.name ? [[normalize(browser.name), browser.bundleId] as const] : [])),
);

const useBrowserToolsError = (): ComputerUseToolError =>
  new ComputerUseToolError("use_browser_tools", USE_BROWSER_TOOLS_MESSAGE);

// True for a listed browser's bundle id or a browser web app's, in any case.
export function isBrowserBundleId(bundleId: string): boolean {
  const id = normalize(bundleId);
  return browserIds.has(id) || webAppPrefixes.some((prefix) => id.startsWith(prefix));
}

// The bundle id of the browser an identifier names: a browser or web app
// bundle id, or a listed display name, in any case. A partial name is left to
// the helper.
export function browserBundleIdFor(appIdentifier: string): string | undefined {
  if (isBrowserBundleId(appIdentifier)) {
    return appIdentifier.trim();
  }
  return bundleIdsByName.get(normalize(appIdentifier));
}

// Refuses a browser before any helper call. A browser on the deny list (the
// user's extra blocked apps) is `app_blocked` whatever the browser setting
// says; any other browser is `use_browser_tools` unless browsers are allowed.
export function assertBrowserAllowed(
  appIdentifier: string,
  options: { allowBrowserApps: boolean; deniedBundleIds: readonly string[] },
): void {
  const bundleId = browserBundleIdFor(appIdentifier);
  if (bundleId === undefined) {
    return;
  }
  if (options.deniedBundleIds.some((id) => normalize(id) === normalize(bundleId))) {
    throw appBlockedError(appIdentifier);
  }
  if (!options.allowBrowserApps) {
    throw useBrowserToolsError();
  }
}

// The helper's refusal of a blocked app carries the bundle id it refused
// (`bundleId`, set by `AppBlockList.check` in AppBlockList.swift). When that
// id is a browser and not on the deny list, the refusal came from the browser
// rule and becomes `use_browser_tools`. Any other error, or a refusal without
// the field, is returned as it is, so the app stays refused either way.
export function asBrowserRefusal(error: unknown, deniedBundleIds: readonly string[]): unknown {
  if (!(error instanceof ComputerUseError) || error.code !== "app_blocked" || error.bundleId === undefined) {
    return error;
  }
  const refused = normalize(error.bundleId);
  if (!isBrowserBundleId(refused) || deniedBundleIds.some((id) => normalize(id) === refused)) {
    return error;
  }
  return useBrowserToolsError();
}
