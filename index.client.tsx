import type { PluginClientContext } from "@getpaseo/plugin/client";
import { ComputerUseSettingsScreen } from "./client/settings-screen";

export default function contribute(client: PluginClientContext) {
  client.addSettingsScreen({
    id: "computer-use",
    title: "Computer Use",
    icon: "Monitor",
    Component: ComputerUseSettingsScreen,
  });

  return () => {};
}
