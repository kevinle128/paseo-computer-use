import { execFile } from "node:child_process";
import type { RpcInput } from "@getpaseo/plugin";
import type { PluginServerContext } from "@getpaseo/plugin/server";
import {
  controlStopRpc,
  permissionsOpenRpc,
  statusGetRpc,
} from "../../shared/rpc";
import type { ComputerUseService } from "../computer-use-mcp";

export interface RpcHandlerOptions {
  // The socket listener starts once at plugin start, outside the service
  // status, so its failure is reported here.
  getSocketError?: () => string | null;
}

export function registerComputerUseRpcHandlers(
  server: PluginServerContext,
  service: ComputerUseService,
  options: RpcHandlerOptions = {},
): void {
  server.handle(statusGetRpc, async () => {
    const status = await service.getStatus();
    return { ...status, socketError: options.getSocketError?.() ?? null };
  });

  server.handle(controlStopRpc, async () => {
    return service.stopControl();
  });

  server.handle(
    permissionsOpenRpc,
    async ({ pane }: RpcInput<typeof permissionsOpenRpc>) => {
      if (process.platform !== "darwin") {
        return { opened: false };
      }
      const targetUrl =
        pane === "accessibility"
          ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
          : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";

      await new Promise<void>((resolve) => {
        execFile("open", [targetUrl], () => resolve());
      });
      return { opened: true };
    },
  );
}
