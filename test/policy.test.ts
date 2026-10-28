import { describe, expect, it } from "vitest";
import {
  ComputerUseError,
  ComputerUseToolError,
  PHYSICAL_ESCAPE_STOP_MESSAGE,
  toToolErrorCode,
  USER_INTERVENED_STOP_MESSAGE,
} from "../server/computer-use-mcp/contract/errors";
import type { HelperPort } from "../server/computer-use-mcp/contract/helper-port";
import type { HelperUnsolicitedEvent } from "../server/computer-use-mcp/contract/helper-protocol";
import { createHelperDriver } from "../server/computer-use-mcp/facade/helper-driver";
import {
  AbortMonitor,
  asBrowserRefusal,
  AuditLog,
  ControlLock,
  type PolicyEngineConfig,
  USE_BROWSER_TOOLS_MESSAGE,
  withComputerUsePolicy,
} from "../server/computer-use-mcp/policy";

function createFakeHelperPort() {
  const listeners = new Set<(event: HelperUnsolicitedEvent) => void>();
  const requests: Array<{ cmd: string; params: unknown }> = [];
  // armGate holds the arm reply, like a helper that is still starting.
  const tap: { canArm: boolean; armGate?: Promise<void> } = { canArm: true };

  const helperPort: HelperPort = {
    async request(cmd, params) {
      requests.push({ cmd, params });
      if (cmd === "abort_tap.arm") {
        await tap.armGate;
        return { armed: tap.canArm } as never;
      }
      if (cmd === "abort_tap.disarm") {
        return { armed: false } as never;
      }
      return { ok: true } as never;
    },
    onEvent(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    async stop() {},
  };

  return {
    helperPort,
    requests,
    tap,
    emit(event: HelperUnsolicitedEvent) {
      for (const listener of listeners) {
        listener(event);
      }
    },
  };
}

function createPolicyStack(extraBlocked: string[] = [], enabled = { value: true }, browsers = { allowed: false }) {
  const fakeHelper = createFakeHelperPort();
  const controlLock = new ControlLock({
    helperPort: fakeHelper.helperPort,
    idleTimeoutMs: 60_000,
  });
  const abortMonitor = new AbortMonitor({
    helperPort: fakeHelper.helperPort,
    controlLock,
  });
  const auditLog = new AuditLog(200);

  const policy: PolicyEngineConfig = {
    controlLock,
    abortMonitor,
    auditLog,
    getExtraBlockedBundleIds: () => extraBlocked,
    isEnabled: () => enabled.value,
    allowBrowserApps: () => browsers.allowed,
  };

  return {
    fakeHelper,
    controlLock,
    abortMonitor,
    auditLog,
    policy,
  };
}

describe("Policy, Lock, Abort & Audit Engine", () => {
  it("refuses every call with computer_use_disabled once the setting is turned off", async () => {
    const enabled = { value: true };
    const { policy, controlLock } = createPolicyStack([], enabled);

    await withComputerUsePolicy(
      policy,
      { callerId: "agent-1", toolName: "click", mutating: true, app: "com.apple.TextEdit" },
      { app: "com.apple.TextEdit" },
      async () => "ok",
    );
    await controlLock.release("agent-1");

    // The agent was created while enabled; turning the setting off must still stop it.
    enabled.value = false;
    let ran = false;
    const refused = withComputerUsePolicy(
      policy,
      { callerId: "agent-1", toolName: "click", mutating: true, app: "com.apple.TextEdit" },
      { app: "com.apple.TextEdit" },
      async () => {
        ran = true;
        return "should-not-run";
      },
    );
    await expect(refused).rejects.toBeInstanceOf(ComputerUseToolError);
    await expect(refused).rejects.toMatchObject({ toolCode: "computer_use_disabled" });
    expect(ran).toBe(false);
    expect(controlLock.getActiveOwner().callerId).toBeNull();
  });

  it("blocks built-in and extra deny-listed bundle IDs", async () => {
    const { policy } = createPolicyStack(["com.custom.secretapp"]);

    await expect(
      withComputerUsePolicy(
        policy,
        {
          callerId: "agent-1",
          toolName: "get_app_state",
          mutating: false,
          app: "com.1password.1password",
        },
        { app: "com.1password.1password" },
        async () => "should-not-run",
      ),
    ).rejects.toMatchObject({
      toolCode: "app_blocked",
      message: expect.stringMatching(/not allowed to use the app 'com\.1password\.1password'/),
    });

    await expect(
      withComputerUsePolicy(
        policy,
        {
          callerId: "agent-1",
          toolName: "get_app_state",
          mutating: false,
          app: "com.custom.secretapp",
        },
        { app: "com.custom.secretapp" },
        async () => "should-not-run",
      ),
    ).rejects.toThrow(/not allowed to use the app 'com\.custom\.secretapp'/);
  });

  it("refuses web browsers with use_browser_tools unless the setting allows them, and lets list tools name them", async () => {
    const browsers = { allowed: false };
    const { policy, controlLock } = createPolicyStack([], { value: true }, browsers);
    const call = (app: string, toolName = "click", listing = false) =>
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName, mutating: toolName === "click", app, ...(listing ? { listing } : {}) },
        { app },
        async () => "ran",
      );

    for (const app of ["com.google.Chrome", "com.apple.safari", "Google Chrome", " safari ", "Microsoft Edge"]) {
      await expect(call(app)).rejects.toMatchObject({ toolCode: "use_browser_tools", message: USE_BROWSER_TOOLS_MESSAGE });
      await expect(call(app, "get_app_state")).rejects.toMatchObject({ toolCode: "use_browser_tools" });
    }
    // Refused before the lock is taken.
    expect(controlLock.getActiveOwner().callerId).toBeNull();
    await expect(call("com.google.Chrome", "list_windows", true)).resolves.toBe("ran");
    await expect(call("com.apple.TextEdit")).resolves.toBe("ran");
    await controlLock.release("agent-1");

    // Read on every call, like the enable switch.
    browsers.allowed = true;
    await expect(call("com.google.Chrome")).resolves.toBe("ran");
    await expect(call("Safari", "get_app_state")).resolves.toBe("ran");
    await controlLock.release("agent-1");
  });

  it("refuses the less common browsers by bundle id and by display name", async () => {
    const { policy } = createPolicyStack();
    const read = (app: string) =>
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName: "get_app_state", mutating: false, app },
        { app },
        async () => "ran",
      );

    for (const app of [
      "com.duckduckgo.macos.browser",
      "com.duckduckgo.mobile.ios",
      "DuckDuckGo",
      "com.operasoftware.OperaGX",
      "Opera GX",
      "org.torproject.torbrowser",
      "Tor Browser",
      "com.brave.Browser.beta",
      "Brave Browser Nightly",
      "com.vivaldi.Vivaldi.snapshot",
      "Vivaldi Snapshot",
      "net.librewolf.librewolf",
      "LibreWolf",
      "net.waterfox.waterfox",
      "Waterfox",
    ]) {
      await expect(read(app), app).rejects.toMatchObject({ toolCode: "use_browser_tools" });
    }
  });

  it("refuses browser web apps by bundle id prefix", async () => {
    const { policy } = createPolicyStack();
    const read = (app: string) =>
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName: "get_app_state", mutating: false, app },
        { app },
        async () => "ran",
      );

    for (const app of ["com.google.Chrome.app.abcdefghijklmnop", "COM.APPLE.SAFARI.WEBAPP.0A1B2C3D"]) {
      await expect(read(app)).rejects.toMatchObject({ toolCode: "use_browser_tools" });
    }
    // Only the web app prefix matches, not every id that starts like a browser.
    await expect(read("com.google.Chrome.application")).resolves.toBe("ran");
  });

  it("keeps a browser the user blocked app_blocked, by bundle id and by display name, whatever the browser setting", async () => {
    const browsers = { allowed: false };
    const { policy, controlLock } = createPolicyStack(["com.google.Chrome"], { value: true }, browsers);
    const call = (app: string, toolName = "click") =>
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName, mutating: toolName === "click", app },
        { app },
        async () => "ran",
      );

    for (const allowed of [false, true]) {
      browsers.allowed = allowed;
      for (const app of ["com.google.Chrome", "Google Chrome", " google chrome "]) {
        await expect(call(app), `${app} allowed=${allowed}`).rejects.toMatchObject({
          toolCode: "app_blocked",
          message: `Computer Use is not allowed to use the app '${app.trim()}' for safety reasons.`,
        });
        await expect(call(app, "get_app_state")).rejects.toMatchObject({ toolCode: "app_blocked" });
      }
    }
    expect(controlLock.getActiveOwner().callerId).toBeNull();
    // Another browser follows the browser setting.
    browsers.allowed = false;
    await expect(call("Safari")).rejects.toMatchObject({ toolCode: "use_browser_tools" });
  });

  it("refuses generic browser names only through the helper, by the bundle id they resolve to", async () => {
    const { policy, controlLock } = createPolicyStack();
    const call = (app: string) =>
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName: "click", mutating: true, app },
        { app },
        async () => "ran",
      );

    // An app named "Dia" (a diagram editor) or "Zen" is not refused by name;
    // the helper decides once it knows the bundle id.
    for (const app of ["Dia", "Zen", "Orion", "Arc"]) {
      await expect(call(app), app).resolves.toBe("ran");
      await controlLock.release("agent-1");
    }
    for (const app of ["company.thebrowser.dia", "app.zen-browser.zen", "com.kagi.kagimacOS", "company.thebrowser.Browser"]) {
      await expect(call(app), app).rejects.toMatchObject({ toolCode: "use_browser_tools" });
    }
  });

  it("turns the helper's refusal of a browser into use_browser_tools by the refused bundle id and leaves other refusals alone", () => {
    const refusal = (id: string) =>
      new ComputerUseError({
        code: "app_blocked",
        message: `Computer Use is not allowed to use the app '${id}' for safety reasons.`,
        bundleId: id,
      });

    for (const id of ["com.google.Chrome", "company.thebrowser.dia", "com.google.Chrome.app.abcdef", "com.apple.Safari.WebApp.0A1B"]) {
      expect(asBrowserRefusal(refusal(id), []), id).toMatchObject({
        toolCode: "use_browser_tools",
        message: USE_BROWSER_TOOLS_MESSAGE,
      });
    }
    // The user blocked this browser: it stays app_blocked.
    const userBlocked = refusal("com.google.Chrome");
    expect(asBrowserRefusal(userBlocked, ["com.google.chrome"])).toBe(userBlocked);
    const passwords = refusal("com.apple.Passwords");
    expect(asBrowserRefusal(passwords, [])).toBe(passwords);
    // The message alone is not read: without the field the refusal stays
    // app_blocked.
    const withoutField = new ComputerUseError({
      code: "app_blocked",
      message: "Computer Use is not allowed to use the app 'com.google.Chrome' for safety reasons.",
    });
    expect(asBrowserRefusal(withoutField, [])).toBe(withoutField);
    const other = new ComputerUseError({ code: "accessibility_error", message: "failed", bundleId: "com.google.Chrome" });
    expect(asBrowserRefusal(other, [])).toBe(other);
  });

  it("enforces single-owner lock contention with computer_busy and arms/disarms abort_tap", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();

    await withComputerUsePolicy(
      policy,
      { callerId: "agent-owner", toolName: "click", mutating: true, app: "com.apple.Finder" },
      { app: "com.apple.Finder" },
      async () => "ok",
    );

    expect(controlLock.getActiveOwner().callerId).toBe("agent-owner");
    expect(fakeHelper.requests.some((r) => r.cmd === "abort_tap.arm")).toBe(true);

    await expect(
      withComputerUsePolicy(
        policy,
        { callerId: "agent-contender", toolName: "click", mutating: true, app: "com.apple.Finder" },
        { app: "com.apple.Finder" },
        async () => "should-fail",
      ),
    ).rejects.toThrow(/computer_busy/);

    // A held lock is a refusal with its own code, never a user takeover.
    const busy = await withComputerUsePolicy(
      policy,
      { callerId: "agent-contender", toolName: "click", mutating: true, app: "com.apple.Finder" },
      { app: "com.apple.Finder" },
      async () => "should-fail",
    ).catch((error: unknown) => error);
    expect(toToolErrorCode(busy)).toBe("computer_busy");
    expect(busy).not.toBeInstanceOf(ComputerUseError);

    await controlLock.release("agent-owner");
    expect(controlLock.getActiveOwner().callerId).toBeNull();
    expect(fakeHelper.requests.some((r) => r.cmd === "abort_tap.disarm")).toBe(true);
  });

  it("aborts in-flight requests on physical Escape, releases lock, and blocks calls until the host turn-end hook clears it", async () => {
    const { policy, controlLock, abortMonitor, fakeHelper } = createPolicyStack();

    const inFlight = withComputerUsePolicy(
      policy,
      {
        callerId: "agent-1",
        turnId: "turn-1",
        toolName: "drag",
        mutating: true,
        app: "com.apple.Notes",
      },
      { app: "com.apple.Notes" },
      async (_input, { signal }) => {
        await new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(signal.reason), {
            once: true,
          });
        });
      },
    );

    await new Promise((r) => setTimeout(r, 10));
    fakeHelper.emit({ event: "abort", reason: "escape_key" });

    await expect(inFlight).rejects.toThrow(PHYSICAL_ESCAPE_STOP_MESSAGE);
    expect(controlLock.getActiveOwner().callerId).toBeNull();

    // Further calls in the same turn are blocked immediately
    await expect(
      withComputerUsePolicy(
        policy,
        {
          callerId: "agent-1",
          turnId: "turn-1",
          toolName: "click",
          mutating: true,
          app: "com.apple.Notes",
        },
        { app: "com.apple.Notes" },
        async () => "should-not-run",
      ),
    ).rejects.toThrow(PHYSICAL_ESCAPE_STOP_MESSAGE);

    // A new turn id sent by the agent does not clear the stop.
    await expect(
      withComputerUsePolicy(
        policy,
        {
          callerId: "agent-1",
          turnId: "turn-2",
          toolName: "click",
          mutating: true,
          app: "com.apple.Notes",
        },
        { app: "com.apple.Notes" },
        async () => "should-not-run",
      ),
    ).rejects.toThrow(PHYSICAL_ESCAPE_STOP_MESSAGE);

    // Only the host turn-end hook clears it.
    abortMonitor.clearCallerAbort("agent-1");
    const nextTurnRes = await withComputerUsePolicy(
      policy,
      {
        callerId: "agent-1",
        turnId: "turn-2",
        toolName: "get_app_state",
        mutating: false,
        app: "com.apple.Notes",
      },
      { app: "com.apple.Notes" },
      async () => "turn-2-ok",
    );
    expect(nextTurnRes).toBe("turn-2-ok");
  });

  it("handles mouse shake user_intervened abort with USER_INTERVENED_STOP_MESSAGE", async () => {
    const { policy, fakeHelper } = createPolicyStack();

    await withComputerUsePolicy(
      policy,
      {
        callerId: "agent-shake",
        turnId: "turn-shake",
        toolName: "click",
        mutating: true,
        app: "com.apple.Notes",
      },
      { app: "com.apple.Notes" },
      async () => "ok",
    );

    fakeHelper.emit({ event: "abort", reason: "user_intervened" });

    await expect(
      withComputerUsePolicy(
        policy,
        {
          callerId: "agent-shake",
          turnId: "turn-shake",
          toolName: "click",
          mutating: true,
          app: "com.apple.Notes",
        },
        { app: "com.apple.Notes" },
        async () => "blocked",
      ),
    ).rejects.toThrow(USER_INTERVENED_STOP_MESSAGE);
  });

  it("does not take the lock or arm the Escape tap for read tools", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();

    await withComputerUsePolicy(
      policy,
      { callerId: "agent-owner", toolName: "click", mutating: true, app: "com.apple.Finder" },
      { app: "com.apple.Finder" },
      async () => "ok",
    );
    const armsBefore = fakeHelper.requests.filter((r) => r.cmd === "abort_tap.arm").length;

    // Another agent can still read while the owner holds the computer.
    const read = await withComputerUsePolicy(
      policy,
      { callerId: "agent-reader", toolName: "get_app_state", mutating: false, app: "com.apple.Finder" },
      { app: "com.apple.Finder" },
      async () => "state",
    );
    expect(read).toBe("state");
    expect(controlLock.getActiveOwner().callerId).toBe("agent-owner");

    await controlLock.release("agent-owner");
    await withComputerUsePolicy(
      policy,
      { callerId: "agent-reader", toolName: "list_apps", mutating: false },
      {},
      async () => "apps",
    );
    expect(controlLock.getActiveOwner().callerId).toBeNull();
    expect(fakeHelper.requests.filter((r) => r.cmd === "abort_tap.arm")).toHaveLength(armsBefore);
  });

  it("refuses mutating tools with permission_missing when the Escape tap cannot be armed", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();
    fakeHelper.tap.canArm = false;

    let ran = false;
    const refused = await withComputerUsePolicy(
      policy,
      { callerId: "agent-1", toolName: "type_text", mutating: true, app: "com.apple.TextEdit" },
      { app: "com.apple.TextEdit" },
      async () => {
        ran = true;
        return "should-not-run";
      },
    ).catch((error: unknown) => error);

    expect(ran).toBe(false);
    expect(toToolErrorCode(refused)).toBe("permission_missing");
    expect(String(refused)).toMatch(/Accessibility/);
    // A refused agent does not keep the computer.
    expect(controlLock.getActiveOwner().callerId).toBeNull();

    // Reading still works without the tap.
    await expect(
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName: "get_app_state", mutating: false, app: "com.apple.TextEdit" },
        { app: "com.apple.TextEdit" },
        async () => "state",
      ),
    ).resolves.toBe("state");
  });

  it("re-arms the Escape tap on the next mutating call after the helper restarts", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();
    const run = () =>
      withComputerUsePolicy(
        policy,
        { callerId: "agent-1", toolName: "click", mutating: true, app: "com.apple.TextEdit" },
        { app: "com.apple.TextEdit" },
        async () => "ok",
      );
    const arms = () => fakeHelper.requests.filter((r) => r.cmd === "abort_tap.arm").length;

    await run();
    await run();
    expect(arms()).toBe(1);
    expect(controlLock.isAbortTapArmed()).toBe(true);

    fakeHelper.emit({ event: "exited", code: 1, signal: null });
    expect(controlLock.isAbortTapArmed()).toBe(false);

    // Same owner, new helper process: the tap is armed again.
    await run();
    expect(arms()).toBe(2);
    expect(controlLock.isAbortTapArmed()).toBe(true);
    expect(controlLock.getActiveOwner().callerId).toBe("agent-1");
  });

  it("refuses the action and disarms Escape when a release lands while the tap is still arming", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();
    let openArm: () => void = () => {};
    fakeHelper.tap.armGate = new Promise<void>((resolve) => {
      openArm = resolve;
    });
    let acted = false;

    const call = withComputerUsePolicy(
      policy,
      { callerId: "agent-1", toolName: "click", mutating: true, app: "com.apple.TextEdit" },
      { app: "com.apple.TextEdit" },
      async () => {
        acted = true;
        return "clicked";
      },
    ).catch((error: unknown) => error);

    await expect.poll(() => fakeHelper.requests.some((r) => r.cmd === "abort_tap.arm")).toBe(true);
    // Stop (or a turn end) releases the computer before the arm reply.
    await controlLock.release("agent-1");
    openArm();

    const error = await call;
    expect(toToolErrorCode(error)).toBe("aborted_by_user");
    expect(acted).toBe(false);
    expect(controlLock.getActiveOwner().callerId).toBeNull();
    expect(controlLock.isAbortTapArmed()).toBe(false);
    const cmds = fakeHelper.requests.map((r) => r.cmd);
    expect(cmds.lastIndexOf("abort_tap.disarm")).toBeGreaterThan(cmds.indexOf("abort_tap.arm"));
  });

  it("reports permission_missing, not a user stop, when a release lands during an arm that fails", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();
    fakeHelper.tap.canArm = false;
    let openArm: () => void = () => {};
    fakeHelper.tap.armGate = new Promise<void>((resolve) => {
      openArm = resolve;
    });

    const call = withComputerUsePolicy(
      policy,
      { callerId: "agent-1", toolName: "click", mutating: true, app: "com.apple.TextEdit" },
      { app: "com.apple.TextEdit" },
      async () => "clicked",
    ).catch((error: unknown) => error);

    await expect.poll(() => fakeHelper.requests.some((r) => r.cmd === "abort_tap.arm")).toBe(true);
    await controlLock.release("agent-1");
    openArm();

    expect(toToolErrorCode(await call)).toBe("permission_missing");
    expect(controlLock.getActiveOwner().callerId).toBeNull();
    expect(controlLock.isAbortTapArmed()).toBe(false);
  });

  it("does not let a second agent take the lock while the first is still arming", async () => {
    const { policy, controlLock, fakeHelper } = createPolicyStack();
    let openArm: () => void = () => {};
    fakeHelper.tap.armGate = new Promise<void>((resolve) => {
      openArm = resolve;
    });
    const first = withComputerUsePolicy(
      policy,
      { callerId: "agent-1", toolName: "click", mutating: true },
      {},
      async () => "first",
    );
    const second = withComputerUsePolicy(
      policy,
      { callerId: "agent-2", toolName: "click", mutating: true },
      {},
      async () => "second",
    ).catch((error: unknown) => error);
    openArm();
    await expect(first).resolves.toBe("first");
    expect(toToolErrorCode(await second)).toBe("computer_busy");
    expect(controlLock.getActiveOwner().callerId).toBe("agent-1");
  });
  it("keeps a change of the frontmost app in the audit entry of the action", async () => {
    const { policy, auditLog, fakeHelper } = createPolicyStack();
    const changed = "user_focus_changed: com.apple.Safari -> com.apple.TextEdit";
    const detail =
      "focus_watch: restored key_down_idle=100.000s mouse_down_idle=2.050s checked_after_action=1.600s front_from_after_action=1.500s";
    const helperPort: HelperPort = {
      ...fakeHelper.helperPort,
      async request(cmd, params, options) {
        if (cmd === "press_key") {
          return {
            ok: true,
            verification: { state: "unverified", reason: "events posted; effect not checked" },
            userFocusChanged: changed,
            focusWatchDetail: detail,
          } as never;
        }
        return fakeHelper.helperPort.request(cmd, params, options);
      },
    };
    const driver = createHelperDriver({
      helperPort,
      policy,
      getCallerContext: () => ({ callerId: "agent-1" }),
    });

    const result = await driver.pressKey({ app: "com.apple.TextEdit", key: "Return" });
    expect(result).toMatchObject({ userFocusChanged: changed });
    const [entry] = auditLog.list().filter((candidate) => candidate.toolName === "press_key");
    expect(entry?.userFocusChanged).toBe(changed);
    expect(entry?.focusWatchDetail).toBe(detail);
    expect(entry?.status).toBe("completed");
  });

  it("keeps a change of the frontmost app in the audit entry of an action that failed", async () => {
    const { policy, auditLog, fakeHelper } = createPolicyStack();
    const changed = "user_focus_changed: com.apple.Safari -> com.apple.TextEdit";
    const detail =
      "focus_watch: restored key_down_idle=100.000s mouse_down_idle=2.050s checked_after_action=1.600s front_from_after_action=1.500s";
    const helperPort: HelperPort = {
      ...fakeHelper.helperPort,
      async request(cmd, params, options) {
        if (cmd === "press_key") {
          throw new ComputerUseError({
            code: "accessibility_error",
            message: "failed after the keys were sent",
            userFocusChanged: changed,
            focusWatchDetail: detail,
          });
        }
        return fakeHelper.helperPort.request(cmd, params, options);
      },
    };
    const driver = createHelperDriver({
      helperPort,
      policy,
      getCallerContext: () => ({ callerId: "agent-1" }),
    });

    await expect(driver.pressKey({ app: "com.apple.TextEdit", key: "Return" })).rejects.toBeInstanceOf(
      ComputerUseError,
    );
    const [entry] = auditLog.list().filter((candidate) => candidate.toolName === "press_key");
    expect(entry?.userFocusChanged).toBe(changed);
    expect(entry?.focusWatchDetail).toBe(detail);
    expect(entry?.status).toBe("failed");
  });
});
