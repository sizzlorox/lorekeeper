import * as fs from "node:fs";
import * as path from "node:path";
import type {
  TextContent,
  ToolCall,
  AssistantMessage,
  UserMessage,
  ToolResultMessage,
} from "@oh-my-pi/pi-ai";
import type { AgentMessage } from "@oh-my-pi/pi-agent-core";
import { resolveLorekeeperHome } from "./paths.js";

/**
 * autonote.{ps1,sh} expects a Claude-Code session JSONL where each line is
 *
 *   {"type":"user"|"assistant","message":{"content": string | Part[]}}
 *
 * with Part being `{type:"text",text:string}` or `{type:"tool_use",name:string}`.
 *
 * omp emits a richer shape (UserMessage / AssistantMessage / ToolResultMessage
 * with `toolCall` parts), so we transcode per turn into the legacy shape that
 * the lorekeeper scripts already understand. The synthesized transcripts live
 * at `$LOREKEEPER_HOME/transcripts/<session-id>.jsonl` and are best-effort:
 * we never read them back inside the plugin.
 */
export class TranscriptWriter {
  readonly #file: string;

  constructor(sessionId: string) {
    const safeId = sessionId.replace(/[^a-zA-Z0-9_-]/g, "_") || `sess-${Date.now()}`;
    const dir = path.join(resolveLorekeeperHome(), "transcripts");
    try {
      fs.mkdirSync(dir, { recursive: true });
    } catch {
      /* surfaces on first append */
    }
    this.#file = path.join(dir, `${safeId}.jsonl`);
  }

  get path(): string {
    return this.#file;
  }

  /**
   * Append one omp AgentMessage as a Claude-shaped transcript line.
   * Returns the number of `tool_use` parts written (the structural gate in
   * autonote counts those to decide if the session is "substantial").
   */
  appendAgentMessage(message: AgentMessage): number {
    // UserMessage / AssistantMessage map directly. ToolResultMessage is a
    // synthetic assistant turn for the gate's purposes (it confirms a tool
    // was actually invoked). DeveloperMessage and extension messages are
    // ignored — autonote only inspects user/assistant types.
    if (isUserMessage(message)) return this.#writeUser(message);
    if (isAssistantMessage(message)) return this.#writeAssistant(message);
    if (isToolResultMessage(message)) return this.#writeToolResult(message);
    return 0;
  }

  #writeUser(msg: UserMessage): number {
    const content = typeof msg.content === "string"
      ? msg.content
      : flattenText(msg.content);
    if (!content) return 0;
    this.#write({ type: "user", message: { content } });
    return 0;
  }

  #writeAssistant(msg: AssistantMessage): number {
    type Part = { type: "text"; text: string } | { type: "tool_use"; name: string };
    const parts: Part[] = [];
    let toolUseCount = 0;
    for (const c of msg.content) {
      if (c.type === "text" && typeof (c as TextContent).text === "string") {
        const text = (c as TextContent).text.trim();
        if (text) parts.push({ type: "text", text });
      } else if (c.type === "toolCall") {
        parts.push({ type: "tool_use", name: (c as ToolCall).name });
        toolUseCount++;
      }
      // Thinking / RedactedThinking are dropped — autonote's gate doesn't
      // count or condense them.
    }
    if (parts.length === 0) return 0;
    this.#write({ type: "assistant", message: { content: parts } });
    return toolUseCount;
  }

  /**
   * Tool results are normally rendered into the next assistant turn. We
   * still emit a `tool_use`-shaped assistant line so the structural gate
   * keeps its arithmetic intact even on weird transcripts (e.g. parallel
   * tool calls without a wrapping assistant turn yet).
   */
  #writeToolResult(msg: ToolResultMessage): number {
    this.#write({
      type: "assistant",
      message: { content: [{ type: "tool_use", name: msg.toolName }] },
    });
    return 1;
  }

  #write(line: Record<string, unknown>): void {
    try {
      fs.appendFileSync(this.#file, JSON.stringify(line) + "\n", "utf8");
    } catch {
      /* swallow — transcript is best-effort */
    }
  }
}

function flattenText(parts: ReadonlyArray<{ type: string; text?: string }>): string {
  const out: string[] = [];
  for (const p of parts) {
    if (p.type === "text" && typeof p.text === "string" && p.text.trim()) {
      out.push(p.text);
    }
  }
  return out.join(" ");
}

function isUserMessage(m: AgentMessage): m is UserMessage {
  return (m as { role?: string }).role === "user";
}
function isAssistantMessage(m: AgentMessage): m is AssistantMessage {
  return (m as { role?: string }).role === "assistant";
}
function isToolResultMessage(m: AgentMessage): m is ToolResultMessage {
  return (m as { role?: string }).role === "toolResult";
}
