import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { describe, expect, it } from "vitest";
import { createComputerUseService } from "../server/computer-use-mcp";
import { buildHelperBinary } from "../server/computer-use-mcp/helper/build";
import { HelperProcess } from "../server/computer-use-mcp/helper/process";
import { UnixSocketTransport } from "./unix-socket-transport";

describe("End-to-end: MCP client -> plugin socket -> real Swift helper", () => {
  it(
    "compiles the native helper, connects over the Unix socket, and runs the read tools",
    async () => {
      if (process.platform !== "darwin") return;

      const tmpDir = mkdtempSync(path.join(tmpdir(), "paseo-cu-e2e-"));
      const socketPath = path.join(tmpDir, "mcp.sock");
      const helperProcess = new HelperProcess({
        resolveBinary: () => buildHelperBinary({ cacheRootDir: path.join(tmpDir, "cache") }),
      });

      const service = createComputerUseService({
        helperPort: helperProcess,
        socketPath,
        getSettings: () => ({
          enabled: true,
          extraBlockedBundleIds: [],
          screenshots: "auto",
        }),
      });

      await service.start();
      const client = new Client({ name: "e2e-agent", version: "1.0.0" });

      try {
        const status = await service.getStatus();
        expect(status.enabled).toBe(true);
        expect(status.platformSupported).toBe(true);
        expect(typeof status.inputSourceId).toBe("string");

        await client.connect(
          new UnixSocketTransport(socketPath, {
            clientId: "e2e-client-1",
            provider: "claude",
            agentId: "agent-e2e-1",
          }),
        );
        expect(client.getServerVersion()?.name).toBe("paseo-computer");

        const { tools } = await client.listTools();
        expect(tools.map((tool) => tool.name)).toContain("get_app_state");

        const statusResult = await client.callTool({ name: "status", arguments: {} });
        expect(statusResult.isError).toBeFalsy();

        const apps = await client.callTool({ name: "list_apps", arguments: {} });
        expect(apps.isError).toBeFalsy();
        expect(apps.structuredContent).toBeUndefined();
        expect(JSON.stringify(apps.content)).toContain("com.apple.finder");
      } finally {
        await client.close();
        await service.stop();
        await helperProcess.stop();
        rmSync(tmpDir, { recursive: true, force: true });
      }
    },
    120_000,
  );
});
