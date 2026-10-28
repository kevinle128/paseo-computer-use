import {
  COMPUTER_USE_TOOLS,
  findComputerUseTool,
  SERVER_INSTRUCTIONS,
  type ToolContext,
} from "./tools";

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: number | string | null;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcSuccessResponse {
  jsonrpc: "2.0";
  id: number | string | null;
  result: unknown;
}

export interface JsonRpcErrorResponse {
  jsonrpc: "2.0";
  id: number | string | null;
  error: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export type JsonRpcResponse = JsonRpcSuccessResponse | JsonRpcErrorResponse;

export interface ComputerUseMcpServerOptions {
  tools: ToolContext;
  serverName?: string;
  serverVersion?: string;
}

export class ComputerUseMcpServer {
  private readonly tools: ToolContext;
  private readonly serverName: string;
  private readonly serverVersion: string;

  constructor(options: ComputerUseMcpServerOptions) {
    this.tools = options.tools;
    this.serverName = options.serverName ?? "paseo-computer";
    this.serverVersion = options.serverVersion ?? "0.2.0";
  }

  async handleMessage(
    raw: unknown,
  ): Promise<JsonRpcResponse | null> {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: -32600,
          message: "Invalid Request",
        },
      };
    }

    const req = raw as Partial<JsonRpcRequest>;
    const hasId = Object.prototype.hasOwnProperty.call(req, "id");
    const id = req.id ?? null;

    if (typeof req.method !== "string") {
      if (!hasId) {
        return null;
      }
      return {
        jsonrpc: "2.0",
        id,
        error: {
          code: -32600,
          message: "Invalid Request: missing method",
        },
      };
    }

    const method = req.method;
    const params =
      typeof req.params === "object" && req.params !== null ? req.params : {};

    // Notifications without an id do not produce a response
    if (method === "notifications/initialized" || method.startsWith("notifications/")) {
      if (!hasId) {
        return null;
      }
      return {
        jsonrpc: "2.0",
        id,
        result: {},
      };
    }

    if (method === "initialize") {
      const requestedProtocol =
        typeof params.protocolVersion === "string"
          ? params.protocolVersion
          : "2024-11-05";
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: requestedProtocol,
          capabilities: {
            tools: {},
          },
          serverInfo: {
            name: this.serverName,
            version: this.serverVersion,
          },
          instructions: SERVER_INSTRUCTIONS,
        },
      };
    }

    if (method === "ping") {
      return {
        jsonrpc: "2.0",
        id,
        result: {},
      };
    }

    if (method === "tools/list") {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          tools: COMPUTER_USE_TOOLS,
        },
      };
    }

    if (method === "tools/call") {
      const toolName = typeof params.name === "string" ? params.name : "";
      const tool = findComputerUseTool(toolName);
      if (!tool) {
        return {
          jsonrpc: "2.0",
          id,
          error: {
            code: -32602,
            message: `Unknown tool: ${toolName || String(params.name)}`,
          },
        };
      }
      const result = await tool.call(params.arguments, this.tools);
      return { jsonrpc: "2.0", id, result };
    }

    return {
      jsonrpc: "2.0",
      id,
      error: {
        code: -32601,
        message: `Method not found: ${method}`,
      },
    };
  }
}
