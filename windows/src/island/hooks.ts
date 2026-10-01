// Claude Code hook events → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ApprovalInfo } from "../core/state";
import type { Island } from "./island";

const CLAUDE_ID = "integration_claude";

/** Per request: drops its card once the relay has given up on it. */
const approvalTimers = new Map<string, number>();

/**
 * A session that moved on — its turn ended, or the user typed a new prompt —
 * cannot still be waiting for a permission: whatever it asked was answered in
 * the terminal. Its cards go, and the relay is released.
 */
function dropSessionApprovals(island: Island, sessionId: string | undefined) {
  if (!sessionId) return;
  for (const a of State.approvals.filter((x) => x.sessionId === sessionId)) {
    releaseApproval(island, a.requestId);
  }
}

/** Identifies one tool call, to match a request with the call it asked about. */
function callKey(tool: string, input: Record<string, unknown>): string {
  return `${tool}\u0000${JSON.stringify(input)}`;
}

/** Forgets a request, stopping its timer and releasing its relay. */
function releaseApproval(island: Island, requestId: string) {
  const timer = approvalTimers.get(requestId);
  if (timer != null) window.clearTimeout(timer);
  approvalTimers.delete(requestId);
  void Bridge.approvalDecline(requestId);
  island.approvalGone(requestId);
}

/**
 * The tool call a card asks about ran, failed or was denied: the user answered
 * in the terminal — Claude Code sends no event for that answer itself — and the
 * card would now be asking about something already settled. Matched on
 * tool_use_id when both sides carry it, else on the tool and its exact input.
 */
function releaseAnsweredElsewhere(island: Island, payload: HookPayload) {
  const id = payload.tool_use_id ?? "";
  const key = callKey(payload.tool_name ?? "", payload.tool_input ?? {});
  const sessionId = payload.session_id ?? "";
  const same = (a: ApprovalInfo) =>
    a.sessionId === sessionId && (id && a.toolUseId ? a.toolUseId === id : a.callKey === key);
  for (const a of State.approvals.filter(same)) {
    releaseApproval(island, a.requestId);
  }
}

interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** PostToolUseFailure: what went wrong. */
  error?: unknown;
  /** Identifies one tool call across PermissionRequest, PostToolUse… */
  tool_use_id?: string;
  /** Optional agent tag: lowercase, digits and hyphens, ≤ 24 chars. */
  coucou_agent?: string;
}

/** Same rule as HookServer.validateAgent on macOS. "claude" is reserved. */
function validateAgent(raw: string | undefined): string | null {
  if (!raw || raw.length > 24 || raw === "claude") return null;
  if (!/^[a-z0-9-]+$/.test(raw)) return null;
  return raw;
}

const FALLBACK_COLORS = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];

function agentColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) {
    h = (Math.imul(31, h) + name.charCodeAt(i)) | 0;
  }
  return FALLBACK_COLORS[Math.abs(h) % FALLBACK_COLORS.length];
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function lastPathComponent(p: string): string {
  const cleaned = p.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

/** frenchStep() — same labels as the macOS app. */
// English, like the rest of the Windows island (the Mac build says these
// in French).
const TOOL_LABELS: Record<string, string> = {
  Bash: "Run",
  Read: "Read",
  Write: "Write",
  Edit: "Edit",
  Glob: "Find",
  Grep: "Search",
  WebSearch: "Web search",
  WebFetch: "Fetch",
  TodoWrite: "Todos",
  Task: "Agent",
  LS: "List",
  MultiEdit: "Edit",
  NotebookEdit: "Notebook",
  PowerShell: "Run",
};

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const file = str("file_path");
  if (file) return `${label} · ${lastPathComponent(file)}`;
  const query = str("query");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

/**
 * What the Allow button actually authorises. Approving "Write" tells you nothing
 * — approving `Write · C:\…\.env` tells you everything, and the difference is
 * the whole point of approving from the island rather than blind.
 *
 * Ordered by how specific the field is, so an unfamiliar tool still shows
 * whatever identifying string it carries instead of falling back to its name.
 */
const APPROVAL_FIELDS = [
  "command", // Bash, PowerShell
  "file_path", // Write, Edit, MultiEdit, NotebookEdit
  "path", // Read, LS
  "url", // WebFetch
  "query", // WebSearch
  "pattern", // Glob, Grep
  "prompt", // Task
] as const;

function approvalTarget(tool: string, input: Record<string, unknown>): string {
  for (const field of APPROVAL_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) {
      return `${tool} · ${value.trim()}`;
    }
  }
  return tool;
}

function upsert(projectName: string, cwd: string) {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.name = projectName;
  if (cwd) t.sessionCwd = cwd;
}

function clearSession() {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.name = "Claude Code";
  t.pillBadge = null;
}

export function registerHookHandlers(island: Island) {
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
  // The relay hung up: Claude Code stopped waiting for it (answered in the
  // terminal, or the session was interrupted). Its card has nothing left to do.
  void onEvent<{ requestId: string }>("approval-gone", ({ requestId }) => {
    const timer = approvalTimers.get(requestId);
    if (timer != null) window.clearTimeout(timer);
    approvalTimers.delete(requestId);
    island.approvalGone(requestId);
    State.notify();
  });
}

function handleHook(island: Island, payload: HookPayload) {
  if (State.paused) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  const cwd = payload.cwd ?? "";
  const raw = lastPathComponent(cwd);
  const projectName = aliasProjectName(raw || "Session");

  // Route to the right pill. Valid coucou_agent → dynamic "agent_<name>" pill.
  // "claude" is reserved; absent or invalid → Claude Code pill unchanged.
  const validAgent = validateAgent(payload.coucou_agent);
  const agentId = validAgent ? `agent_${validAgent}` : CLAUDE_ID;
  const isExternalAgent = validAgent !== null;

  const focused = State.focusId === agentId;

  /** Alerts force the island open; work events only reveal the compact island. */
  const surface = (view: Parameters<Island["alert"]>[0], isAlert: boolean) => {
    if (State.mode === "expanded") {
      if (isAlert) island.setView(view);
    } else if (isAlert) {
      island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  /** Ensure the agent pill exists (no-op for Claude Code). */
  const ensurePill = () => {
    if (isExternalAgent) {
      State.upsertExternalAgent(agentId, validAgent!, agentColor(validAgent!));
    } else {
      upsert(projectName, cwd);
    }
  };

  switch (name) {
    case "SessionStart":
      ensurePill();
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      dropSessionApprovals(island, payload.session_id);
      ensurePill();
      State.updateTask(agentId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(agentId, asked.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      ensurePill();
      State.updateTask(agentId, "working");
      const tool = payload.tool_name ?? "Tool";
      State.appendStep(agentId, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      releaseAnsweredElsewhere(island, payload);
      State.updateTask(agentId, "working");
      break;

    case "PermissionDenied": {
      releaseAnsweredElsewhere(island, payload);
      const tool = TOOL_LABELS[payload.tool_name ?? ""] ?? payload.tool_name ?? "Tool";
      State.appendStep(agentId, `✕ ${tool} denied`);
      break;
    }

    case "PostToolUseFailure": {
      releaseAnsweredElsewhere(island, payload);
      State.updateTask(agentId, "working");
      // Which tool, and why: a bare "failed" said nothing. Most of these are
      // ordinary — a grep with no match or a failing test exits non-zero.
      const tool = TOOL_LABELS[payload.tool_name ?? ""] ?? payload.tool_name ?? "Tool";
      const why = typeof payload.error === "string" ? payload.error.split("\n")[0].slice(0, 40) : "";
      State.appendStep(agentId, why ? `⚠ ${tool} failed · ${why}` : `⚠ ${tool} failed`);
      break;
    }

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        State.updateTask(agentId, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        State.updateTask(agentId, "question");
        State.appendStep(agentId, message);
      }
      break;
    }

    case "Stop":
      dropSessionApprovals(island, payload.session_id);
      State.updateTask(agentId, "finished");
      if (payload.message) State.appendStep(agentId, payload.message.slice(0, 60));
      Sound.play("finish");
      if (focused) surface("finished", true);
      else State.setPillBadge(agentId, "finished");
      window.setTimeout(() => {
        if (isExternalAgent) {
          State.removeTask(agentId);
        } else {
          State.updateTask(agentId, "idle");
          State.setPillBadge(agentId, null);
        }
      }, 5200);
      break;

    case "StopFailure":
      dropSessionApprovals(island, payload.session_id);
      State.updateTask(agentId, "error");
      Sound.play("error");
      if (focused) surface("error", true);
      else State.setPillBadge(agentId, "error");
      break;

    case "SessionEnd":
      dropSessionApprovals(island, payload.session_id);
      if (isExternalAgent) {
        State.removeTask(agentId);
      } else {
        State.updateTask(agentId, "idle");
        clearSession();
      }
      break;

    case "SubagentStart":
      State.appendStep(agentId, "+ subagent");
      break;

    case "SubagentStop":
      State.appendStep(agentId, "• subagent done");
      break;

    case "PermissionRequest": {
      // External agents do not get an approval card — showing one would look like
      // a Claude Code request. Decline immediately so the agent re-asks in its
      // terminal. Approval support for other agents will come with Codex support.
      if (isExternalAgent) {
        if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
        break;
      }

      const requestId = payload.request_id ?? "";
      if (!requestId || State.approvals.some((a) => a.requestId === requestId)) break;
      upsert(projectName, cwd);
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      // Queued, never replaced: a request that arrives while another card is up
      // waits its turn behind it, and each one gets its own answer.
      State.approvals.push({
        requestId,
        sessionId: payload.session_id ?? "",
        project: projectName,
        tool,
        command: approvalTarget(tool, input),
        callKey: callKey(tool, input),
        toolUseId: payload.tool_use_id ?? "",
      });
      const first = State.approvals.length === 1;
      // The relay's short ack window closes in 800 ms; everything below this
      // line is synchronous, so the request really is reachable when it lands.
      void Bridge.approvalAck(requestId);
      State.updateTask(CLAUDE_ID, "approval");
      Sound.play("approval");
      if (!first) {
        // The card is already up (or one click away); it now reads "1 of N".
      } else if (focused) {
        island.alert("approval");
      } else {
        // Another agent holds the view, so the card would yank it away. The badge
        // is the signal instead — but it has to be on screen for that to mean
        // anything, hence the reveal. Opening the island leads to the card.
        State.setPillBadge(CLAUDE_ID, "approval");
        island.reveal();
      }
      // Coucou answers within 108 s or not at all; after that the terminal has
      // taken over and the card would be lying.
      approvalTimers.set(requestId, window.setTimeout(() => {
        approvalTimers.delete(requestId);
        island.approvalGone(requestId);
      }, 110_000));
      break;
    }

    default:
      break;
  }
  State.notify();
}
