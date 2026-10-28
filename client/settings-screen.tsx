import { useCallback, useEffect, useMemo, useState } from "react";
import { Text } from "react-native";
import {
  useRpc,
  useSettings,
  type PluginSurfaceProps,
  type SettingsState,
} from "@getpaseo/plugin/client";
import {
  SettingsAction,
  SettingsCard,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsSelect,
  SettingsSwitch,
} from "@getpaseo/plugin/client/ui";
import {
  controlStopRpc,
  permissionsOpenRpc,
  statusGetRpc,
  type ComputerUseStatusOutput,
} from "../shared/rpc";
import {
  SUPPORTED_PROVIDERS,
  computerUseSettings,
  parseBundleIdList,
  toggleProvider,
} from "../shared/settings";

const ENABLE_WARNING =
  "Computer Use lets agents see and control the apps on this Mac as you: they can read " +
  "windows, click, type, and press keys in any app that is not on the blocked list. " +
  "Press Esc or Paseo's Stop button to take control back at once.";

const BUILTIN_BLOCK_HINT =
  "Keychain Access, Passwords, the login window, the system password prompt, and the " +
  "1Password, Bitwarden, Dashlane, LastPass, NordPass, and Proton Pass apps are always " +
  "blocked. Add more bundle ids here, separated by commas or new lines.";

const BROWSER_HINT = "Off: agents use Paseo's browser tools for the web.";

const screenshotOptions = [
  { label: "Auto (AX first; screenshot on request or for a sparse tree)", value: "auto" },
  { label: "Always include screenshot", value: "always" },
  { label: "AX tree only (no screenshot sent to the agent)", value: "never" },
] as const;

type ReadySettings = Extract<
  SettingsState<typeof computerUseSettings.schema>,
  { status: "ready" }
>;

function grantedLabel(status: ComputerUseStatusOutput | null, granted: boolean): string {
  if (!status) return "Checking";
  if (status.helperBuildState !== "ready") return "Unknown until the helper is built";
  return granted ? "Granted" : "Missing";
}

function BlockedAppsEditor({ settings }: { settings: ReadySettings }) {
  // The draft owns only the text. The save merges it into the current
  // values at the current revision, so a provider or enable change made
  // while the user types is neither lost nor reported as a conflict. A
  // change to the saved list itself remounts this editor with the new list.
  const [draft, setDraft] = useState(() => settings.values.extraBlockedBundleIds.join("\n"));
  const save = useCallback(() => {
    void settings.save(
      { ...settings.values, extraBlockedBundleIds: parseBundleIdList(draft) },
      settings.revision,
    );
  }, [settings, draft]);

  return (
    <SettingsCard>
      <SettingsInput
        label="Extra blocked apps"
        hint={BUILTIN_BLOCK_HINT}
        initialValue={draft}
        placeholder="com.example.Bank"
        onChangeText={setDraft}
        disabled={settings.saving}
        error={settings.saveError}
      />
      <SettingsAction
        label={`${settings.values.extraBlockedBundleIds.length} extra blocked`}
        actionLabel="Save blocked apps"
        disabled={settings.saving}
        onPress={save}
      />
    </SettingsCard>
  );
}

function SettingsControls({
  settings,
  theme,
}: {
  settings: ReadySettings;
  theme: PluginSurfaceProps["theme"];
}) {
  const getStatus = useRpc(statusGetRpc);
  const openPermissions = useRpc(permissionsOpenRpc);
  const stopControl = useRpc(controlStopRpc);
  const [status, setStatus] = useState<ComputerUseStatusOutput | null>(null);

  useEffect(() => {
    let active = true;
    const poll = async () => {
      try {
        const res = await getStatus({});
        if (active) setStatus(res);
      } catch {
        // A failed poll keeps the last status; the next poll retries.
      }
    };
    void poll();
    const timer = setInterval(poll, 1500);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [getStatus]);

  const textStyle = useMemo(() => ({ color: theme.colors.foreground }), [theme]);

  const onToggleEnabled = useCallback(
    (enabled: boolean) => {
      void settings.save({ ...settings.values, enabled }, settings.revision);
    },
    [settings],
  );

  const onToggleBrowserApps = useCallback(
    (allowBrowserApps: boolean) => {
      void settings.save({ ...settings.values, allowBrowserApps }, settings.revision);
    },
    [settings],
  );

  const onChangeScreenshots = useCallback(
    (screenshots: ReadySettings["values"]["screenshots"]) => {
      void settings.save({ ...settings.values, screenshots }, settings.revision);
    },
    [settings],
  );

  const onToggleProvider = useCallback(
    (provider: string, enabled: boolean) => {
      void settings.save(
        {
          ...settings.values,
          injectProviders: toggleProvider(settings.values.injectProviders, provider, enabled),
        },
        settings.revision,
      );
    },
    [settings],
  );

  const openAccessibility = useCallback(() => {
    void openPermissions({ pane: "accessibility" });
  }, [openPermissions]);

  const openScreenRecording = useCallback(() => {
    void openPermissions({ pane: "screen-recording" });
  }, [openPermissions]);

  const handleStop = useCallback(() => {
    void stopControl({});
  }, [stopControl]);

  const helperState = status?.helperBuildState ?? "checking";

  return (
    <SettingsSection title="Computer Use">
      <SettingsCard>
        <SettingsSwitch
          label="Enable Computer Use"
          hint={ENABLE_WARNING}
          value={settings.values.enabled}
          disabled={settings.saving}
          onValueChange={onToggleEnabled}
        />
        <SettingsSwitch
          label="Allow Computer Use in web browsers"
          hint={BROWSER_HINT}
          value={settings.values.allowBrowserApps}
          disabled={settings.saving}
          onValueChange={onToggleBrowserApps}
        />
        <SettingsSelect
          label="Screenshot mode"
          value={settings.values.screenshots}
          options={screenshotOptions}
          disabled={settings.saving}
          onValueChange={onChangeScreenshots}
        />
      </SettingsCard>

      <SettingsCard>
        <SettingsAction
          label={`Accessibility: ${grantedLabel(status, status?.axTrusted ?? false)}`}
          hint="Grant it to the app that started the Paseo daemon, then quit and reopen that app."
          actionLabel="Open System Settings"
          onPress={openAccessibility}
        />
        <SettingsAction
          label={`Screen Recording: ${grantedLabel(status, status?.screenCaptureGranted ?? false)}`}
          hint="Needed for screenshots. Quit and reopen the app after you grant it."
          actionLabel="Open System Settings"
          onPress={openScreenRecording}
        />
        <SettingsRow label="Helper build" error={status?.helperBuildError ?? null}>
          <Text style={textStyle}>{helperState}</Text>
        </SettingsRow>
        {status?.socketError ? (
          <SettingsRow label="Agent connection" error={status.socketError} />
        ) : null}
        {status?.activeOwner ? (
          <SettingsAction
            label={`In control: ${status.activeAgentId ?? status.activeOwner}`}
            actionLabel="Stop"
            onPress={handleStop}
          />
        ) : null}
      </SettingsCard>

      <SettingsCard>
        {SUPPORTED_PROVIDERS.map((provider) => (
          <SettingsSwitch
            key={provider.id}
            label={`Give ${provider.label} agents computer use`}
            value={settings.values.injectProviders.includes(provider.id)}
            disabled={settings.saving}
            onValueChange={(enabled) => onToggleProvider(provider.id, enabled)}
          />
        ))}
      </SettingsCard>

      {/* Remount only when the saved list changes, so saving another setting
          does not discard ids the user typed but has not saved yet. */}
      <BlockedAppsEditor
        key={settings.values.extraBlockedBundleIds.join("\n")}
        settings={settings}
      />
    </SettingsSection>
  );
}

export function ComputerUseSettingsScreen({ theme }: PluginSurfaceProps) {
  const settings = useSettings(computerUseSettings);
  const style = useMemo(() => ({ color: theme.colors.foreground }), [theme]);

  if (settings.status === "loading") {
    return <Text style={style}>Loading Computer Use settings…</Text>;
  }
  if (settings.status !== "ready") {
    return (
      <SettingsSection title="Computer Use">
        <Text style={style}>{settings.error}</Text>
        <SettingsAction label="Try again" actionLabel="Reload" onPress={settings.reload} />
        {settings.status === "invalid" ? (
          <SettingsAction
            label="Restore default settings"
            actionLabel="Reset"
            onPress={settings.reset}
          />
        ) : null}
      </SettingsSection>
    );
  }

  return <SettingsControls settings={settings} theme={theme} />;
}
