declare module "openclaw/plugin-sdk" {
  export interface OpenClawPluginLogger {
    info(message: string, ...args: unknown[]): void;
    warn(message: string, ...args: unknown[]): void;
    error(message: string, ...args: unknown[]): void;
    debug?(message: string, ...args: unknown[]): void;
  }

  export interface OpenClawToolDefinition {
    name: string;
    description?: string;
    parameters?: unknown;
    execute?: (toolCallId: string, params: unknown, signal?: AbortSignal) => unknown | Promise<unknown>;
  }

  export interface OpenClawPluginApi {
    logger: OpenClawPluginLogger;
    registerTool(factory: (ctx: any) => OpenClawToolDefinition[]): void;
  }

  export function emptyPluginConfigSchema(): Record<string, unknown>;
  export function jsonResult(value: unknown): unknown;
}