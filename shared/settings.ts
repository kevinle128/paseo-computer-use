import { defineSettings } from "@getpaseo/plugin";
import { z } from "zod";

// Providers whose Paseo adapter accepts injected MCP servers and that this
// plugin is tested with, in the order the settings screen lists them.
export const SUPPORTED_PROVIDERS = [
  { id: "claude", label: "Claude" },
  { id: "codex", label: "Codex" },
  { id: "omp", label: "Oh My Pi" },
] as const;

export const computerUseSettingsSchema = z.object({
  enabled: z.boolean().default(false),
  injectProviders: z.array(z.string()).default(SUPPORTED_PROVIDERS.map((provider) => provider.id)),
  extraBlockedBundleIds: z.array(z.string()).default([]),
  screenshots: z.enum(["auto", "always", "never"]).default("auto"),
});

export type ComputerUseSettingsValues = z.infer<typeof computerUseSettingsSchema>;

export const computerUseSettings = defineSettings({
  id: "computer-use",
  scope: "host",
  version: 1,
  schema: computerUseSettingsSchema,
});

/**
 * Adds or removes one provider. Ids the screen does not list are kept, so a
 * value saved by a newer version of the plugin survives an edit here.
 */
export function toggleProvider(
  current: readonly string[],
  provider: string,
  enabled: boolean,
): string[] {
  const without = current.filter((id) => id !== provider);
  return enabled ? [...without, provider] : without;
}

/**
 * Reads bundle ids typed one per line or separated by commas. Blank entries
 * and repeats are dropped; the first spelling of each id is kept.
 */
export function parseBundleIdList(text: string): string[] {
  const seen = new Set<string>();
  const ids: string[] = [];
  for (const part of text.split(/[\s,]+/)) {
    const id = part.trim();
    if (id && !seen.has(id)) {
      seen.add(id);
      ids.push(id);
    }
  }
  return ids;
}
