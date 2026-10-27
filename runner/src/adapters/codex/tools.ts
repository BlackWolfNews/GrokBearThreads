// The threadbare tools for Codex threads. Codex can't take the in-process
// SDK MCP server Claude threads get, so the same tools go in as dynamic
// tools (experimental): a `threadbare` namespace given at thread/start, and
// item/tool/call requests answered by running the same handlers.
//
// Spike 1 (27 Oct): tools given at thread/start survive thread/resume in a
// new process (they're stored in the rollout's session_meta), although
// thread/resume takes no dynamicTools. So:
//  - the handlers are built for the session's own thread on every start and
//    resume, and looked up by namespace and tool name;
//  - a thread's tool list is frozen at thread/start, so a call for a tool
//    this runner doesn't have (renamed or removed since) gets success: false
//    and a sentence, never a JSON-RPC error.
import { z } from 'zod';
import type { ToolApprovalAnswer, ToolApprovalRequest } from '../types.ts';
import { ALWAYS_ASK_TOOLS, SERVER_NAME } from '../../threadbare-mcp.ts';
import { toolTitle, truncateInput } from '../../tools.ts';
import type { DynamicToolCallParams, DynamicToolCallResponse, DynamicToolSpec } from './types.ts';

// What the SDK's tool() makes (buildThreadbareTools' array), loosely typed
// so tools with different argument shapes fit in one list.
export type ToolDefinition = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>; // a zod raw shape
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  handler: (args: any, extra: unknown) => Promise<{ content?: unknown[]; isError?: boolean }>;
};

export const NAMESPACE = SERVER_NAME;

const NAMESPACE_DESCRIPTION =
  "Tools that manage Threadbare, Mike's own app for running agent threads, which this thread runs in: list and read threads, start new ones, message them, rename, snooze, archive, move and delete them, and schedule messages for later. " +
  'Use move_thread when the work belongs in another folder (for example a repo), so this thread runs there from the next turn.';

// The tools as one dynamic-tool namespace, with JSON Schema from zod.
export function dynamicToolSpecs(tools: ToolDefinition[]): DynamicToolSpec[] {
  if (!tools.length) return [];
  return [
    {
      type: 'namespace',
      name: NAMESPACE,
      description: NAMESPACE_DESCRIPTION,
      tools: tools.map((t) => ({ type: 'function', name: t.name, description: t.description, inputSchema: jsonSchema(t) })),
    },
  ];
}

function jsonSchema(t: ToolDefinition): unknown {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const schema = z.toJSONSchema(z.object(t.inputSchema as any)) as Record<string, unknown>;
  delete schema.$schema;
  return schema;
}

function text(t: string, success: boolean): DynamicToolCallResponse {
  return { contentItems: [{ type: 'inputText', text: t }], success };
}

export type CodexToolsDeps = {
  // Asked before a tool that asks every time (delete_thread). Codex never
  // asks before a client-side tool, so the runner does.
  requestApproval(req: ToolApprovalRequest): Promise<ToolApprovalAnswer>;
  cwd(): string;
};

// Answers item/tool/call for one session's thread. A call from a subagent
// acts for the parent thread, like everything else the subagent does.
export class CodexTools {
  private byName = new Map<string, ToolDefinition>();
  private deps: CodexToolsDeps;

  constructor(tools: ToolDefinition[], deps: CodexToolsDeps) {
    for (const t of tools) this.byName.set(t.name, t);
    this.deps = deps;
  }

  async call(params: DynamicToolCallParams, o: { fromChild: boolean; signal: AbortSignal }): Promise<DynamicToolCallResponse> {
    const ns = params?.namespace ?? null;
    const name = typeof params?.tool === 'string' ? params.tool : '';
    const tool = ns === NAMESPACE ? this.byName.get(name) : undefined;
    if (!tool) {
      const shown = ns ? `${ns}.${name}` : name;
      return text(
        `Threadbare has no tool called ${shown || '(unnamed)'} any more. This thread's tool list was fixed when it started; the threadbare tools it has now are: ${[...this.byName.keys()].join(', ') || 'none'}.`,
        false,
      );
    }
    const raw = params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments) ? (params.arguments as Record<string, unknown>) : {};
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const parsed = z.object(tool.inputSchema as any).safeParse(raw);
    if (!parsed.success) return text(`Those arguments don't fit ${name}: ${z.prettifyError(parsed.error)}`, false);
    const args = parsed.data as Record<string, unknown>;
    const fullName = `mcp__${NAMESPACE}__${name}`;
    if (ALWAYS_ASK_TOOLS.has(fullName)) {
      const ans = await this.deps.requestApproval({
        toolUseId: o.fromChild ? undefined : params.callId,
        name: fullName,
        title: toolTitle(fullName, args, this.deps.cwd()),
        input: truncateInput(args),
        canAlwaysAllow: false,
        signal: o.signal,
      });
      if (ans.decision !== 'allow' && ans.decision !== 'allowAlways') {
        return text(ans.message || (ans.decision === 'expired' ? 'The request expired before the user answered.' : 'The user denied this. Ask them how to proceed.'), false);
      }
    }
    try {
      const result = await tool.handler(args, {});
      const out = (result.content ?? [])
        .map((c) => (c && typeof c === 'object' && (c as { type?: string }).type === 'text' ? String((c as { text?: unknown }).text ?? '') : ''))
        .filter(Boolean)
        .join('\n');
      return text(out, !result.isError);
    } catch (e) {
      return text((e as Error)?.message ?? String(e), false);
    }
  }
}
