import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

export const auditEntrySchema = z.object({
  timestamp: z.string(),
  callerId: z.string(),
  toolName: z.string(),
  app: z.string().nullable(),
  status: z.string(),
  durationMs: z.number(),
  textLength: z.number().optional(),
});

export const statusOutputSchema = z.object({
  enabled: z.boolean(),
  platformSupported: z.boolean(),
  helperBuildState: z.enum(["idle", "building", "ready", "failed"]),
  helperBuildError: z.string().nullable(),
  axTrusted: z.boolean(),
  screenCaptureGranted: z.boolean(),
  abortTapAvailable: z.boolean(),
  inputSourceId: z.string().nullable(),
  isInputMethod: z.boolean(),
  activeOwner: z.string().nullable(),
  activeAgentId: z.string().nullable(),
  auditEntries: z.array(auditEntrySchema),
  // Why the MCP socket is not serving agents, for example because another
  // daemon on the same Paseo home already owns it. Null while it serves.
  socketError: z.string().nullable(),
});

export type ComputerUseStatusOutput = z.infer<typeof statusOutputSchema>;

export const statusGetRpc = defineRpc({
  name: "computer-use.status.get",
  input: z.object({}),
  output: statusOutputSchema,
});

export const controlStopRpc = defineRpc({
  name: "computer-use.control.stop",
  input: z.object({}),
  output: z.object({
    stopped: z.boolean(),
  }),
});

export const permissionsOpenRpc = defineRpc({
  name: "computer-use.permissions.open",
  input: z.object({
    pane: z.enum(["accessibility", "screen-recording"]),
  }),
  output: z.object({
    opened: z.boolean(),
  }),
});
