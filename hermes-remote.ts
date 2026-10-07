#!/usr/bin/env bun
// Bridge between the Omarchy panel and a remote `hermes serve` backend.
//
//   hermes-remote stdio               NDJSON commands on stdin, NDJSON events on stdout (client of the daemon)
//   hermes-remote daemon              the one long-lived connection, shared by every panel over a Unix socket
//   hermes-remote status              one-shot status as JSON
//   hermes-remote chat <profile> <text>   one-shot chat, streams events
//
// Credentials: ~/.config/hermes-remote/credentials.env
//   HERMES_REMOTE_URL, HERMES_REMOTE_USER, HERMES_REMOTE_PASSWORD

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, openSync, closeSync, rmSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Socket } from "node:net";
import { normalize } from "node:path";
import type { ServerWebSocket } from "bun";

type Json = Record<string, unknown>;
type Command =
  | { cmd: "refresh" }
  | { cmd: "reconnect" }
  // Test hook: feed a raw gateway frame through onFrame (used to exercise notice handling without a backend trigger).
  | { cmd: "inject"; frame: Json }
  | { cmd: "speak"; profile: string; text: string; play?: boolean }
  | { cmd: "speak.stop" }
  | { cmd: "template.export"; profile: string }
  | { cmd: "template.import"; path: string; name: string }
  | { cmd: "dictate.start" }
  | { cmd: "dictate.stop"; profile: string }
  | { cmd: "dictate.file"; profile: string; path: string }
  | { cmd: "demo.start" | "demo.stop"; profile: string }
  | { cmd: "groups" }
  | { cmd: "group.create"; name: string; members: string[] }
  | { cmd: "group.open"; room: string }
  | { cmd: "group.close" }
  | { cmd: "group.send"; room: string; text: string; thread?: string }
  | { cmd: "group.rename"; room: string; name: string }
  | { cmd: "group.stop" | "group.disband"; room: string }
  | { cmd: "group.approve"; room: string; member: string; taskId: string; generation: number; requestId: string; choice: "once" | "deny" }
  | { cmd: "group.retry"; room: string; taskId: string }
  | { cmd: "create"; name: string; description?: string }
  | { cmd: "delete"; name: string }
  | { cmd: "profile.get"; profile: string }
  | { cmd: "profile.save"; profile: string; description?: string; soul?: string }
  | { cmd: "profile.duplicate"; profile: string; newName: string }
  | { cmd: "profile.pin" | "profile.hide"; profile: string; value: boolean }
  | { cmd: "profile.section"; profile: string; section: string }
  | { cmd: "new"; profile: string }
  | { cmd: "load"; profile: string }
  | { cmd: "send"; profile: string; text: string }
  | { cmd: "interrupt"; profile: string }
  | { cmd: "steer"; profile: string; text: string }
  | { cmd: "queue"; profile: string; text: string }
  | { cmd: "approve"; requestId: string | number; choice: Choice }
  | { cmd: "clarify"; requestId: string | number; answer: string; questionId?: string }
  | { cmd: "model"; profile: string; provider: string; model: string }
  | { cmd: "effort.get"; profile: string }
  | { cmd: "subagents"; profile: string }
  | { cmd: "subagent.steer"; profile: string; id: string; text: string }
  | { cmd: "subagent.stop"; profile: string; id: string }
  | { cmd: "effort.set"; profile: string; value: string }
  | { cmd: "attach"; profile: string; path?: string; clipboard?: boolean }
  | { cmd: "sessions"; profile: string }
  | { cmd: "skills"; profile: string }
  | { cmd: "skill.save"; profile: string; name: string; content: string; category?: string }
  | { cmd: "open"; profile: string; session: string }
  | { cmd: "session.rename"; profile: string; id: string; title: string }
  | { cmd: "session.archive" | "session.delete"; profile: string; id: string }
  | { cmd: "screen.url"; profile: string; open?: boolean }
  | { cmd: "screen.take"; profile: string }
  | { cmd: "screen.handback"; profile: string }
  | { cmd: "routines"; profile: string }
  | { cmd: "routine.create"; profile: string; name: string; schedule: string; prompt: string }
  | { cmd: "routine.pause" | "routine.resume" | "routine.run" | "routine.delete" | "routine.runs"; profile: string; id: string };
type Choice = "once" | "session" | "always" | "deny";
type ScreenState = { profile: string; running: boolean; lease: Json | null; mine: boolean };
type RfbLink = { profile: string; upstream: WebSocket | null; backlog: (string | Buffer)[]; closed: boolean };
type HistoryRow = { role: "you" | "bot" | "tool"; text: string };
type AttachBytes = { bytes: Uint8Array; name: string; mime: string; path: string };

const cacheDir = `${process.env.HOME}/.cache/puri.hermes`;
const ATTACH_MAX_BYTES = 25 * 1024 * 1024;
const MEDIA_RE = /MEDIA:(\S+)/g;
// Resumed sessions whose stored source is not "desktop" get the TUI prompt, which prints a bare
// path instead of MEDIA:. Mirrors Hermes extract_local_files (gateway/platforms/base.py): absolute
// path with a deliverable extension, not inside a URL or code span.
const DELIVERY_EXTS = "png|jpe?g|gif|webp|bmp|tiff|svg|mp4|mov|avi|mkv|webm|3gp|mp3|m2a|wav|ogg|opus|m4a|flac|pdf|docx?|odt|rtf|txt|md|epub|xlsx?|ods|csv|tsv|json|xml|ya?ml|kmz|kml|geojson|gpx|pptx?|odp|key|zip|tar|gz|tgz|bz2|xz|7z|rar|apk|ipa|html?";
const BARE_PATH_RE = new RegExp(`(?<![/:\\w.])/(?:[\\w.\\-]+/)*[\\w.\\-]+\\.(?:${DELIVERY_EXTS})\\b`, "gi");
const CODE_SPAN_RE = /```[\s\S]*?```|`[^`\n]*`/g;
// Anything else in a MEDIA: tag (pdf, csv, zip, ...) is fetched as a plain file download.
const IMAGE_PATH_RE = /\.(png|jpe?g|gif|webp|bmp|svg|ico)$/i;
const CRON_POLL_MS = 30000;
// hermes_constants.VALID_REASONING_EFFORTS plus "none" (thinking off).
const EFFORT_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
const ROOM_WATCH_MS = 20000;
const NOVNC_DIR = `${import.meta.dir}/novnc`;
const SOCKET_PATH = process.env.XDG_RUNTIME_DIR
  ? `${process.env.XDG_RUNTIME_DIR}/puri-hermes.sock` : `/tmp/puri-hermes-${process.getuid?.() ?? 0}.sock`;
const DAEMON_PID = `${cacheDir}/daemon.pid`;
const DAEMON_LOG = `${cacheDir}/daemon.log`;

// Served by the helper on 127.0.0.1; its RFB socket is spliced to the gateway display bridge.
const SCREEN_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>Bot screen</title>
<style>
html,body{margin:0;height:100%;background:#111;color:#ddd;font:14px system-ui,sans-serif}
#bar{display:flex;gap:10px;align-items:center;height:40px;padding:0 12px;background:#1d1d1d;box-sizing:border-box}
#bar .grow{flex:1}
#status{color:#aaa}
button{background:#2a2a2a;color:#ddd;border:1px solid #555;border-radius:4px;padding:4px 10px;cursor:pointer}
button:disabled{opacity:.4;cursor:default}
#screen{position:absolute;top:40px;left:0;right:0;bottom:0}
</style></head>
<body>
<div id="bar"><b id="name"></b><span id="status">connecting…</span><span class="grow"></span>
<button id="reconnect" hidden>Reconnect</button><button id="take" disabled>Take over</button><button id="back" disabled>Hand back</button></div>
<div id="screen"></div>
<script type="module">
import RFB from "/novnc/core/rfb.js";
const profile = new URLSearchParams(location.search).get("profile") || "default";
const q = "profile=" + encodeURIComponent(profile);
const $ = (id) => document.getElementById(id);
document.title = "@" + profile + " screen";
$("name").textContent = "@" + profile;
let rfb = null;
let you = false;
function connect() {
  $("reconnect").hidden = true;
  $("status").textContent = "connecting…";
  rfb = new RFB($("screen"), "ws://" + location.host + "/rfb?" + q, { shared: true });
  rfb.scaleViewport = true;
  rfb.viewOnly = !you;
  rfb.addEventListener("connect", refresh);
  rfb.addEventListener("disconnect", (e) => {
    rfb = null;
    $("status").textContent = e.detail.clean ? "disconnected" : "connection lost";
    $("reconnect").hidden = false;
  });
}
function paint(s) {
  const human = s.lease && s.lease.holder === "human";
  you = human && s.mine;
  if (rfb) {
    rfb.viewOnly = !you;
    $("status").textContent = !s.running ? "screen not running" : you ? "you have control"
      : human ? "someone else has control" : "bot has control";
  }
  $("take").disabled = you || !s.running;
  $("back").disabled = !you;
}
async function call(path, init) {
  const r = await fetch(path, init);
  const body = await r.json();
  if (!r.ok) throw new Error(body.error || "HTTP " + r.status);
  return body;
}
async function refresh() {
  try { paint(await call("/state?" + q)); } catch (e) { $("status").textContent = e.message; }
}
async function lease(op) {
  try { paint(await call("/lease?" + q + "&op=" + op, { method: "POST" })); } catch (e) { $("status").textContent = e.message; }
}
$("take").onclick = () => lease("take");
$("back").onclick = () => lease("handback");
$("reconnect").onclick = connect;
connect();
setInterval(refresh, 2000);
</script>
</body></html>
`;

// An exclusive-create marker per cron run: a run is announced once, also across daemon restarts.
function claimOnce(dir: string, key: string): boolean {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  try {
    closeSync(openSync(`${dir}/${key.replace(/[^A-Za-z0-9_.-]/g, "_")}`, "wx"));
    return true;
  } catch {
    return false;
  }
}

const startsWith = (b: Uint8Array, sig: number[], at = 0) => sig.every((v, i) => b[at + i] === v);

const imageExt = (b: Uint8Array): string | null => {
  if (startsWith(b, [0x89, 0x50, 0x4e, 0x47])) return ".png";
  if (startsWith(b, [0xff, 0xd8, 0xff])) return ".jpg";
  if (startsWith(b, [0x47, 0x49, 0x46, 0x38])) return ".gif";
  if (startsWith(b, [0x52, 0x49, 0x46, 0x46]) && startsWith(b, [0x57, 0x45, 0x42, 0x50], 8)) return ".webp";
  if (startsWith(b, [0x42, 0x4d])) return ".bmp";
  return null;
};

async function saveCache(kind: string, bytes: Uint8Array, ext: string): Promise<string> {
  const dir = `${cacheDir}/${kind}`;
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = `${dir}/${createHash("sha1").update(bytes).digest("hex").slice(0, 16)}${ext}`;
  await Bun.write(path, bytes);
  return path;
}

// An image on the clipboard wins; otherwise a copied file (text/uri-list from a file manager).
async function readClipboard(): Promise<AttachBytes> {
  const types = Bun.spawnSync(["wl-paste", "--list-types"]);
  const list = new TextDecoder().decode(types.stdout).split("\n").map((t) => t.trim());
  const imageType = list.find((t) => t.startsWith("image/"));
  if (types.exitCode === 0 && imageType) {
    const data = Bun.spawnSync(["wl-paste", "--no-newline", "--type", imageType]);
    if (data.exitCode !== 0 || data.stdout.length === 0) throw new RemoteError("no image in clipboard");
    return { bytes: new Uint8Array(data.stdout), name: `clipboard${imageType.replace("image/", ".")}`, mime: imageType, path: "" };
  }
  if (types.exitCode === 0 && list.includes("text/uri-list")) {
    const uris = new TextDecoder().decode(Bun.spawnSync(["wl-paste", "--no-newline", "--type", "text/uri-list"]).stdout);
    const first = uris.split(/\r?\n/).map((l) => l.trim()).find((l) => l.startsWith("file://"));
    if (first) return readAttachFile(first);
  }
  throw new RemoteError("no image or file in clipboard");
}

async function readAttachFile(raw: string): Promise<AttachBytes> {
  let path = raw.trim().replace(/^~(?=\/)/, process.env.HOME ?? "~");
  if (path.startsWith("file://")) path = decodeURIComponent(path.slice(7).replace(/^localhost(?=\/)/, ""));
  const file = Bun.file(path);
  if (!path || !(await file.exists())) throw new RemoteError(`file not found: ${raw}`);
  if (file.size > ATTACH_MAX_BYTES) throw new RemoteError(`file too large (max 25 MB): ${raw}`);
  return { bytes: new Uint8Array(await file.arrayBuffer()), name: path.split("/").pop() || "attachment",
    mime: (file.type || "application/octet-stream").split(";")[0], path };
}

function decodeDataUrl(url: string): Uint8Array {
  const comma = url.indexOf(",");
  if (!url.startsWith("data:") || comma < 0) throw new RemoteError("media response was not a data URL");
  return new Uint8Array(Buffer.from(url.slice(comma + 1), "base64"));
}

const historyRow = (m: Json): HistoryRow | null => {
  switch (m.role) {
    case "user": return { role: "you", text: String(m.text ?? "") };
    case "assistant": return m.text ? { role: "bot", text: String(m.text) } : null;
    case "tool": return { role: "tool", text: `⚙ ${String(m.name ?? "tool")}` };
    default: return null;
  }
};

class RemoteError extends Error {}

// FastAPI `detail` may be a string, a validation list, or an object (e.g. cron create 424
// {error, job_saved, ...}); job_saved matters because retrying would duplicate the job.
function errorDetail(detail: unknown): string {
  if (detail === undefined || detail === null || detail === "") return "";
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail)) return detail.map((d) => (d && typeof d === "object" && "msg" in d ? String((d as Json).msg) : JSON.stringify(d))).join("; ");
  if (typeof detail === "object") {
    const d = detail as Json;
    if (typeof d.error !== "string") return JSON.stringify(d);
    const saved = d.job_saved === true ? ` (job was saved${d.job_id ? ` as ${d.job_id}` : ""}; do not retry create)` : d.job_saved === false ? " (job was not saved)" : "";
    return d.error + saved;
  }
  return String(detail);
}

// Teach by demonstration: the RFB input a person sends while holding the Bot Screen, as readable steps.
const MODIFIER_KEYS: Record<number, string> = {
  0xffe1: "Shift", 0xffe2: "Shift", 0xffe3: "Ctrl", 0xffe4: "Ctrl", 0xffe7: "Alt", 0xffe8: "Alt",
  0xffe9: "Alt", 0xffea: "Alt", 0xffeb: "Super", 0xffec: "Super" };
const KEY_NAMES: Record<number, string> = {
  0xff0d: "Enter", 0xff8d: "Enter", 0xff09: "Tab", 0xff08: "Backspace", 0xff1b: "Escape", 0xffff: "Delete",
  0xff50: "Home", 0xff57: "End", 0xff55: "PageUp", 0xff56: "PageDown", 0xff63: "Insert",
  0xff51: "Left", 0xff52: "Up", 0xff53: "Right", 0xff54: "Down",
  ...Object.fromEntries(Array.from({ length: 12 }, (_, i) => [0xffbe + i, `F${i + 1}`])) };
const DEMO_MAX_STEPS = 200;

function keysymChar(sym: number): string | null {
  if ((sym >= 0x20 && sym <= 0x7e) || (sym >= 0xa0 && sym <= 0xff)) return String.fromCharCode(sym);
  if (sym >= 0x01000100 && sym <= 0x0110ffff) return String.fromCodePoint(sym - 0x01000000);
  return null;
}

class DemoRecorder {
  private steps: string[] = [];
  private typed = "";
  private mods = new Set<string>();
  private mask = 0;
  private press: { x: number; y: number } | null = null;
  private lastClick: { x: number; y: number; t: number } | null = null;
  private scroll: { dir: string; n: number; x: number; y: number } | null = null;

  // noVNC flushes every client message as its own WebSocket frame, so one frame is one message.
  // Handshake frames and the other message types never match these exact shapes.
  feed(frame: Uint8Array, now = Date.now()) {
    const v = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
    if (frame.length === 8 && frame[0] === 4) this.key(frame[1] !== 0, v.getUint32(4));
    else if (frame.length === 12 && frame[0] === 255 && frame[1] === 0) this.key(v.getUint16(2) !== 0, v.getUint32(4));
    else if (frame.length === 6 && frame[0] === 5) this.pointer(frame[1], v.getUint16(2), v.getUint16(4), now);
  }

  finish(): string[] {
    this.flush();
    return this.steps;
  }

  private push(step: string) {
    if (this.steps.length < DEMO_MAX_STEPS) this.steps.push(step);
  }

  private flush() {
    if (this.typed) this.push(`type ${JSON.stringify(this.typed)}`);
    if (this.scroll) this.push(`scroll ${this.scroll.dir} ${this.scroll.n}x at (${this.scroll.x}, ${this.scroll.y})`);
    this.typed = "";
    this.scroll = null;
  }

  private chord(name: string, keepShift: boolean) {
    return [...[...this.mods].filter((m) => keepShift || m !== "Shift"), name].join("+");
  }

  private key(down: boolean, sym: number) {
    const mod = MODIFIER_KEYS[sym];
    if (mod) {
      if (down) this.mods.add(mod);
      else this.mods.delete(mod);
      return;
    }
    if (!down) return;
    const ch = keysymChar(sym);
    const plain = [...this.mods].every((m) => m === "Shift");
    if (ch && plain) {
      if (this.scroll) this.flush();
      this.typed += ch;
      return;
    }
    if (sym === 0xff08 && plain && this.typed) {
      this.typed = this.typed.slice(0, -1);
      return;
    }
    this.flush();
    this.push(`press ${this.chord(ch ? ch.toUpperCase() : KEY_NAMES[sym] ?? `key 0x${sym.toString(16)}`, !ch)}`);
  }

  private pointer(mask: number, x: number, y: number, now: number) {
    const prev = this.mask;
    const pressed = (bit: number) => (mask & bit) !== 0 && (prev & bit) === 0;
    const released = (bit: number) => (mask & bit) === 0 && (prev & bit) !== 0;
    this.mask = mask;
    for (const [bit, dir] of [[8, "up"], [16, "down"]] as const) {
      if (!pressed(bit)) continue;
      if (this.scroll?.dir === dir) this.scroll.n++;
      else {
        this.flush();
        this.scroll = { dir, n: 1, x, y };
      }
    }
    if (pressed(1)) {
      this.flush();
      this.press = { x, y };
    }
    if (released(1) && this.press) {
      const from = this.press;
      this.press = null;
      const last = this.lastClick;
      if (Math.hypot(x - from.x, y - from.y) > 8) {
        this.push(`drag from (${from.x}, ${from.y}) to (${x}, ${y})`);
        this.lastClick = null;
      } else if (last && now - last.t < 450 && Math.hypot(x - last.x, y - last.y) <= 8
          && this.steps.at(-1)?.endsWith(`click at (${last.x}, ${last.y})`)) {
        this.steps[this.steps.length - 1] = `${this.chord("double-click", true)} at (${x}, ${y})`;
        this.lastClick = null;
      } else {
        this.push(`${this.chord("click", true)} at (${x}, ${y})`);
        this.lastClick = { x, y, t: now };
      }
    }
    if (pressed(4)) {
      this.flush();
      this.push(`${this.chord("right-click", true)} at (${x}, ${y})`);
    }
    if (pressed(2)) {
      this.flush();
      this.push(`${this.chord("middle-click", true)} at (${x}, ${y})`);
    }
  }
}

// A room driver pending action the panel can resolve: a member's tool approval, or a turn that
// ended indeterminately and only runs again after an explicit retry.
function roomAction(a: Json): Json | null {
  if (a.kind === "retry") return { kind: "retry", taskId: String(a.task_id ?? "") };
  if (a.kind !== "approval") return null;
  const ap = (a.approval as Json | undefined) ?? {};
  return { kind: "approval", member: String(a.member_id ?? ""), taskId: String(a.task_id ?? ""),
    generation: Number(a.execution_generation ?? 0), requestId: String(a.request_id ?? ap.request_id ?? ""),
    command: String(ap.command ?? ""), description: String(ap.description ?? ""),
    choices: (ap.choices as string[] | undefined) ?? ["once", "deny"] };
}

// One hosted-room log event as a panel row; turn bookkeeping (started/settled/activity) is dropped.
function roomRow(e: Json): Json | null {
  const p = (e.payload as Json | undefined) ?? {};
  const a = (e.actor as Json | undefined) ?? {};
  const member = String(p.member_id ?? a.display_name ?? a.profile ?? a.id ?? "");
  switch (e.kind) {
    case "message.user": return { seq: e.seq, role: "you", who: "you", text: String(p.text ?? ""), thread: String(p.thread_id ?? "") };
    case "message.member":
      return { seq: e.seq, role: "bot", who: String(a.display_name ?? a.profile ?? member), text: String(p.text ?? ""),
        thread: String(p.thread_id ?? "") };
    case "turn.failed": return { seq: e.seq, role: "status", who: member, text: `hit an error: ${String(p.error ?? p.reason_code ?? "").split("\n")[0]}` };
    case "turn.cancelled": return { seq: e.seq, role: "status", who: member, text: "was stopped" };
    case "member.unavailable": return { seq: e.seq, role: "status", who: member, text: "is unavailable" };
    case "room.renamed": return { seq: e.seq, role: "status", who: "", text: `renamed to ${String(p.name ?? "")}` };
    case "room.disbanded": return { seq: e.seq, role: "status", who: "", text: "group disbanded" };
    default: return null;
  }
}

const credPath = `${process.env.HOME}/.config/hermes-remote/credentials.env`;

async function loadCredentials() {
  const file = Bun.file(credPath);
  if (!(await file.exists())) throw new RemoteError(`missing ${credPath}`);
  const env = Object.fromEntries(
    (await file.text()).split("\n").filter((l) => l.includes("=")).map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i).trim(), l.slice(i + 1).trim()];
    }),
  );
  const { HERMES_REMOTE_URL: url, HERMES_REMOTE_USER: user, HERMES_REMOTE_PASSWORD: password } = env;
  if (!url || !user || !password) throw new RemoteError("credentials.env is incomplete");
  return { url: url.replace(/\/$/, ""), user, password };
}

// In daemon mode this becomes a broadcast to every connected panel.
let emit = (ev: Json) => { process.stdout.write(`${JSON.stringify(ev)}\n`); };

class Remote {
  private cookie = "";
  private ws: WebSocket | null = null;
  private nextId = 0;
  private pending = new Map<number, (m: Json) => void>();
  private sessionByProfile = new Map<string, string>();
  private replyBySession = new Map<string, string>();
  private knownProfiles = new Set<string>(["default"]);

  constructor(private creds: { url: string; user: string; password: string }) {}

  private async login() {
    const r = await fetch(`${this.creds.url}/auth/password-login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ provider: "basic", username: this.creds.user, password: this.creds.password }),
      signal: AbortSignal.timeout(15000),
    });
    if (!r.ok) throw new RemoteError(`login failed (HTTP ${r.status})`);
    this.cookie = r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  }

  async api(path: string, init: RequestInit = {}, retried = false): Promise<Json> {
    if (!this.cookie) await this.login();
    const r = await fetch(`${this.creds.url}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", Cookie: this.cookie, ...(init.headers ?? {}) },
      signal: AbortSignal.timeout(45000),
    });
    if (r.status === 401 && !retried) {
      this.cookie = "";
      return this.api(path, init, true);
    }
    const body = (await r.json().catch(() => ({}))) as Json;
    if (!r.ok) throw new RemoteError(errorDetail(body.detail) || `HTTP ${r.status} on ${path}`);
    return body;
  }

  async status() {
    const s = await (await fetch(`${this.creds.url}/api/status`, { signal: AbortSignal.timeout(10000) })).json() as Json;
    const p = await this.api("/api/profiles");
    // Pin/hide live in ui_meta, which only the gateway RPC returns; the roster still works without it.
    const meta = await this.botMeta().catch(() => new Map<string, { meta: Json; rev: number }>());
    const profiles = ((p.profiles as Json[]) ?? []).map((x) => {
      const m = meta.get(String(x.name))?.meta ?? {};
      return {
        name: x.name, model: x.model, provider: x.provider, description: x.description || x.description_auto || "",
        isDefault: x.is_default === true, pinned: m.pinned === true, hidden: m.hidden === true,
      };
    });
    this.knownProfiles = new Set(["default", ...profiles.map((x) => String(x.name))]);
    // A broken sections file must not take the roster down with it; it is reported on the next write.
    const layout = await this.readSections().catch(() => ({ sections: [] as string[], assign: {} as Record<string, string> }));
    const sections = { order: layout.sections,
      assign: Object.fromEntries(Object.entries(layout.assign).map(([bot, name]) => [bot.toLowerCase(), name])) };
    return { ev: "status", ok: true, url: this.creds.url, version: s.version,
      gatewayRunning: s.gateway_running === true, activeSessions: s.active_sessions, profiles, sections };
  }

  private async socket(): Promise<WebSocket> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return this.ws;
    const { ticket } = (await this.api("/api/auth/ws-ticket", { method: "POST" })) as { ticket: string };
    const ws = new WebSocket(`${this.creds.url.replace(/^http/, "ws")}/api/ws?ticket=${encodeURIComponent(ticket)}`);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new RemoteError("websocket ready timeout")), 20000);
      ws.onmessage = (e) => {
        for (const line of String(e.data).split("\n").filter(Boolean)) {
          const m = JSON.parse(line) as Json;
          if (m.method === "gateway.ready" || (m.params as Json | undefined)?.type === "gateway.ready") {
            clearTimeout(timer);
            resolve();
          }
          this.onFrame(m);
        }
      };
      ws.onerror = () => { clearTimeout(timer); reject(new RemoteError("websocket error")); };
      ws.onclose = (e) => {
        this.ws = null;
        this.sessionByProfile.clear();
        this.keyByProfile.clear();
        // Calls still waiting on this socket never get a reply; fail them so the daemon's queue moves on.
        for (const settle of this.pending.values()) settle({ error: { message: "websocket closed" } });
        this.pending.clear();
        // viewer_id is only honored on the gateway connection that minted it.
        this.viewerByProfile.clear();
        emit({ ev: "disconnected", code: e.code });
      };
    });
    this.ws = ws;
    await this.rpc("client.capabilities", { server_requests: true });
    return ws;
  }

  private async rpc(method: string, params: Json): Promise<Json> {
    const ws = await this.socket();
    const id = ++this.nextId;
    const reply = new Promise<Json>((resolve) => this.pending.set(id, resolve));
    ws.send(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    const m = await reply;
    if (m.error) throw new RemoteError(String((m.error as Json).message ?? method));
    return (m.result as Json) ?? {};
  }

  private onFrame(m: Json) {
    if (typeof m.id === "number" && this.pending.has(m.id)) {
      this.pending.get(m.id)?.(m);
      this.pending.delete(m.id);
      return;
    }
    if (typeof m.method === "string" && m.method !== "event" && m.id !== undefined && m.id !== null) {
      this.onServerRequest(m.id as string | number, m.method, (m.params as Json) ?? {});
      return;
    }
    const p = (m.params as Json) ?? {};
    const sid = String(p.session_id ?? "");
    const payload = (p.payload as Json) ?? {};
    switch (p.type) {
      case "message.start":
        this.replyBySession.set(sid, "");
        emit({ ev: "start", session: sid });
        emit({ ev: "activity", session: sid, text: "thinking" });
        break;
      case "message.delta": {
        const text = String(payload.text ?? "");
        this.replyBySession.set(sid, (this.replyBySession.get(sid) ?? "") + text);
        emit({ ev: "delta", session: sid, text });
        break;
      }
      case "thinking.delta":
      case "reasoning.delta":
        if (String(payload.text ?? "").trim()) emit({ ev: "activity", session: sid, text: "thinking" });
        break;
      case "tool.generating":
        emit({ ev: "activity", session: sid, text: `preparing ${String(payload.name ?? "tool")}` });
        break;
      case "status.update": {
        const text = String(payload.text ?? "").trim();
        if (text) emit({ ev: "activity", session: sid, text });
        // Rate-limit warnings and model fallbacks are worth a banner, not just a status line.
        const kind = String(payload.kind ?? "");
        if (text && (kind === "warn" || kind === "fallback"))
          emit({ ev: "notice", key: `status.${kind}`, level: "warn", kind: "ttl", ttl_ms: 15000, text });
        break;
      }
      case "notification.show":
        if (String(payload.text ?? "").trim())
          emit({ ev: "notice", key: String(payload.key || payload.id || payload.text), level: String(payload.level ?? "info"),
            kind: String(payload.kind ?? "sticky"), ttl_ms: Number(payload.ttl_ms ?? 0), text: String(payload.text).trim() });
        break;
      case "notification.clear":
        emit({ ev: "notice_clear", key: String(payload.key ?? "") });
        break;
      // delegate_task children report on the parent's sid; the child's own text stream is not forwarded.
      case "subagent.start":
      case "subagent.tool":
      case "subagent.progress":
      case "subagent.complete": {
        const phase = p.type === "subagent.start" ? "start" : p.type === "subagent.complete" ? "done" : "tool";
        emit({ ev: "subagent", session: sid, phase, id: String(payload.subagent_id ?? payload.delegation_id ?? ""),
          goal: String(payload.goal ?? "").slice(0, 160),
          tool: String(payload.tool_preview ?? payload.tool_name ?? payload.text ?? "").replace(/\s+/g, " ").slice(0, 80),
          count: Number(payload.tool_count ?? 0), status: String(payload.status ?? ""),
          summary: String(payload.summary ?? "").trim().slice(0, 400), secs: Number(payload.duration_seconds ?? 0) });
        break;
      }
      case "session.usage": {
        const u = (payload.usage as Json) ?? {};
        emit({ ev: "usage", session: sid, total: Number(u.total ?? 0), contextPercent: Number(u.context_percent ?? 0) });
        break;
      }
      case "todo.updated":
        // Full snapshot of the bot's own task list; the panel shows it while the bot works.
        emit({ ev: "todos", session: sid, todos: ((payload.todos as Json[]) ?? []).map((t) => ({
          text: String(t.content ?? t.text ?? t.title ?? ""), status: String(t.status ?? "pending") })) });
        break;
      case "tool.start":
      case "tool.complete": {
        const name = String(payload.name ?? payload.tool_name ?? payload.tool ?? "tool");
        const context = String(payload.context ?? "").replace(/\s+/g, " ").trim().slice(0, 80);
        const phase = p.type === "tool.start" ? "start" : "done";
        emit({ ev: "tool", session: sid, phase, name, context });
        emit({ ev: "activity", session: sid, text: phase === "start" ? `${name}${context ? ` ${context}` : ""}` : "thinking" });
        break;
      }
      case "message.complete":
      {
        const text = String(payload.text ?? this.replyBySession.get(sid) ?? "");
        emit({ ev: "done", session: sid, text });
        void this.fetchMedia(sid, this.profileOf(sid), text);
        break;
      }
      case "error":
        emit({ ev: "error", session: sid, message: String(payload.message ?? p.message ?? "error") });
        break;
      case "request.cancel":
        // A question/approval expired or was withdrawn server-side; the panel must drop its card.
        this.batchClarify.delete(String(payload.id ?? ""));
        emit({ ev: "request.cancel", session: sid, requestId: payload.id, method: String(payload.method ?? ""),
          reason: String(payload.reason ?? "") });
        break;
      case "display.lease":
      case "display.status": {
        const profile = this.profileByKey.get(String(payload.profile_key ?? ""));
        if (profile) this.noteScreen(profile, payload);
        break;
      }
    }
  }

  autoApprove: Choice | "" = "";

  private reply(id: string | number, body: Json) {
    this.ws?.send(`${JSON.stringify({ jsonrpc: "2.0", id, ...body })}\n`);
  }

  private onServerRequest(id: string | number, method: string, params: Json) {
    if (method === "clarify") {
      const batch = Array.isArray(params.questions);
      const questions = batch
        ? (params.questions as Json[]).map((q) => ({ qid: String(q.qid), question: String(q.question ?? ""),
          choices: (q.choices as string[]) ?? [] }))
        : [{ qid: "", question: String(params.question ?? ""), choices: (params.choices as string[]) ?? [] }];
      this.batchClarify.set(String(id), batch);
      emit({ ev: "clarify", requestId: id, session: String(params.session_id ?? ""), batch, questions });
      return;
    }
    if (method !== "approval") {
      this.reply(id, { error: { code: -32601, message: `${method} is not supported by hermes-remote` } });
      return;
    }
    if (this.autoApprove) {
      this.reply(id, { result: { choice: this.autoApprove } });
      emit({ ev: "approval.auto", requestId: id, choice: this.autoApprove });
      return;
    }
    emit({ ev: "approval", requestId: id, session: String(params.session_id ?? ""),
      command: String(params.command ?? params.action ?? ""), description: String(params.description ?? ""),
      choices: (params.choices as string[]) ?? ["once", "deny"] });
  }

  approve(requestId: string | number, choice: Choice) {
    this.reply(requestId, { result: { choice } });
  }

  private batchClarify = new Map<string, boolean>();

  async answerClarify(requestId: string | number, answer: string, questionId = "") {
    if (this.batchClarify.get(String(requestId))) {
      const r = await this.rpc("clarify.lock", { request_id: String(requestId), question_id: questionId, answer });
      if (r.remaining === 0 || r.status === "expired") this.batchClarify.delete(String(requestId));
      return;
    }
    this.batchClarify.delete(String(requestId));
    this.reply(requestId, { result: { answer } });
  }

  private profileParam(profile: string): Json {
    return profile && profile !== "default" ? { profile } : {};
  }

  private async requireProfile(profile: string) {
    if (this.knownProfiles.has(profile)) return;
    await this.status();
    if (!this.knownProfiles.has(profile)) throw new RemoteError(`unknown bot: ${profile}`);
  }

  async load(profile: string) {
    await this.requireProfile(profile);
    // A panel that (re)connects to the long-lived daemon needs the conversation the daemon already
    // holds; resuming its stored key reattaches the live session and returns its messages.
    const live = this.sessionByProfile.get(profile);
    const key = live ? this.keyByProfile.get(profile) : undefined;
    if (live && !key) return emit({ ev: "history", profile, session: live, messages: [] });
    let stored = key ?? "";
    let title = "";
    if (!key) {
      const recent = await this.rpc("session.most_recent", this.profileParam(profile));
      stored = recent.session_id ? String(recent.session_id) : "";
      title = String(recent.title ?? "");
      if (!stored) {
        emit({ ev: "history", profile, session: "", messages: [] });
        return;
      }
    }
    let r: Json;
    try {
      r = await this.rpc("session.resume", { session_id: stored, cols: 100, ...this.profileParam(profile) });
    } catch (e) {
      // A fresh chat has no stored row until its first turn.
      if (live) return emit({ ev: "history", profile, session: live, messages: [] });
      throw e;
    }
    const sid = String(r.session_id);
    this.sessionByProfile.set(profile, sid);
    this.keyByProfile.set(profile, stored);
    if (!key) this.storedByProfile.set(profile, stored);
    const messages = ((r.messages as Json[]) ?? []).map(historyRow).filter((x): x is HistoryRow => x !== null);
    emit({ ev: "history", profile, session: sid, title, messages });
    for (const m of messages) if (m.role === "bot") void this.fetchMedia(sid, profile, m.text);
  }

  private profileOf(sid: string): string {
    for (const [profile, s] of this.sessionByProfile) if (s === sid) return profile;
    return "default";
  }

  private async download(remote: string, profile: string): Promise<string> {
    const q = encodeURIComponent(remote);
    let dataUrl = "";
    try {
      dataUrl = String((await this.api(`/api/media?path=${q}`)).data_url ?? "");
    } catch {
      const scope = profile !== "default" ? `&profile=${encodeURIComponent(profile)}` : "";
      dataUrl = String((await this.api(`/api/fs/read-data-url?path=${q}${scope}`)).dataUrl ?? "");
    }
    const bytes = decodeDataUrl(dataUrl);
    const ext = imageExt(bytes);
    if (!ext) throw new RemoteError("not an image");
    return saveCache("media", bytes, ext);
  }

  // /api/fs/download has no size cap, unlike read-data-url (16 MiB).
  private async downloadFile(remote: string, profile: string): Promise<string> {
    if (!this.cookie) await this.login();
    const scope = profile !== "default" ? `&profile=${encodeURIComponent(profile)}` : "";
    const get = () => fetch(`${this.creds.url}/api/fs/download?path=${encodeURIComponent(remote)}${scope}`,
      { headers: { Cookie: this.cookie }, signal: AbortSignal.timeout(120000) });
    let r = await get();
    if (r.status === 401) {
      await this.login();
      r = await get();
    }
    if (!r.ok) {
      const body = (await r.json().catch(() => ({}))) as Json;
      throw new RemoteError(errorDetail(body.detail) || `HTTP ${r.status}`);
    }
    const base = (remote.split("/").pop() || "file").replace(/[^\w.\- ]/g, "_");
    const dir = `${cacheDir}/files`;
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    // Same basename in different remote dirs must not share (and overwrite) one cache file.
    const key = createHash("sha1").update(normalize(remote)).digest("hex").slice(0, 12);
    const local = `${dir}/${key}-${base}`;
    await Bun.write(local, r);
    return local;
  }

  async fetchMedia(session: string, profile: string, text: string) {
    // remote keeps the text as written so the panel can find the row; seen dedupes by normalized path.
    const refs: { remote: string; tagged: boolean }[] = [];
    const seen = new Set<string>();
    const add = (remote: string, tagged: boolean) => {
      const key = normalize(remote);
      if (seen.has(key)) return;
      seen.add(key);
      refs.push({ remote, tagged });
    };
    for (const match of text.matchAll(MEDIA_RE)) add(match[1].replace(/[)\].,;'"`*]+$/, ""), true);
    for (const match of text.replace(CODE_SPAN_RE, (s) => " ".repeat(s.length)).matchAll(BARE_PATH_RE)) add(match[0], false);
    for (const { remote, tagged } of refs) {
      // A bare path may be prose or a file that was never written; like Hermes, skip it silently if absent.
      const report = (ev: Json) => { if (tagged || !ev.error) emit(ev); };
      if (!IMAGE_PATH_RE.test(remote)) {
        const name = remote.split("/").pop() || remote;
        try {
          report({ ev: "file", session, profile, remote, name, local: await this.downloadFile(remote, profile) });
        } catch (e) {
          report({ ev: "file", session, profile, remote, name, error: e instanceof Error ? e.message : String(e) });
        }
        continue;
      }
      try {
        report({ ev: "media", session, profile, remote, local: await this.download(remote, profile) });
      } catch (e) {
        report({ ev: "media", session, profile, remote, error: e instanceof Error ? e.message : String(e) });
      }
    }
  }

  async attach(profile: string, from: { path?: string; clipboard?: boolean }) {
    await this.requireProfile(profile);
    const src = from.clipboard ? await readClipboard() : await readAttachFile(from.path ?? "");
    if (src.bytes.length > ATTACH_MAX_BYTES) throw new RemoteError(`file too large (max 25 MB): ${src.name}`);
    if (!this.sessionByProfile.has(profile)) await this.load(profile);
    const sid = this.sessionByProfile.get(profile) ?? (await this.newSession(profile));
    const ext = imageExt(src.bytes);
    if (ext) {
      const local = await saveCache("outgoing", src.bytes, ext);
      await this.rpc("image.attach_bytes", {
        session_id: sid, content_base64: Buffer.from(src.bytes).toString("base64"), filename: src.name });
      return emit({ ev: "attached", kind: "image", profile, session: sid, local, name: src.name });
    }
    // file.attach only stages the bytes; the agent sees the file through the @file: ref in the prompt.
    const r = await this.rpc("file.attach", { session_id: sid, name: src.name, ...this.profileParam(profile),
      data_url: `data:${src.mime};base64,${Buffer.from(src.bytes).toString("base64")}` });
    const ref = String(r.ref_text || (r.ref_path ? `@file:${r.ref_path}` : ""));
    if (!ref) throw new RemoteError(`file.attach returned no ref for ${src.name}`);
    this.pendingRefs.set(profile, [...(this.pendingRefs.get(profile) ?? []), ref]);
    emit({ ev: "attached", kind: "file", profile, session: sid, name: String(r.name || src.name), ref, local: src.path });
  }

  private pendingRefs = new Map<string, string[]>();

  async newSession(profile: string) {
    await this.requireProfile(profile);
    const r = await this.rpc("session.create", { cols: 100, source: "desktop", ...this.profileParam(profile) });
    const sid = String(r.session_id);
    this.sessionByProfile.set(profile, sid);
    this.keyByProfile.set(profile, String(r.stored_session_id ?? ""));
    this.storedByProfile.delete(profile);
    this.pendingRefs.delete(profile);
    emit({ ev: "session", profile, session: sid, model: (r.info as Json | undefined)?.model ?? "" });
    return sid;
  }

  async send(profile: string, text: string) {
    await this.requireProfile(profile);
    if (!this.sessionByProfile.has(profile)) await this.load(profile);
    const sid = this.sessionByProfile.get(profile) ?? (await this.newSession(profile));
    emit({ ev: "sent", profile, session: sid });
    const refs = this.pendingRefs.get(profile) ?? [];
    this.pendingRefs.delete(profile);
    let prompt = text;
    // A known skill goes through command.dispatch: the panel shows its safe display text, the model gets
    // the generated directive. Anything else starting with "/" is ordinary prompt text.
    const slash = /^\/([^\s/]+)(?:\s+([\s\S]*))?$/.exec(text.trim());
    if (slash && (await this.isSkill(profile, slash[1]))) {
      const r = await this.rpc("command.dispatch", { session_id: sid, name: slash[1], arg: slash[2] ?? "", ...this.profileParam(profile) });
      if (r.type === "skill" && r.message) {
        emit({ ev: "skillShown", profile, session: sid, display: String(r.display || text) });
        prompt = String(r.message);
      }
    }
    await this.rpc("prompt.submit", { session_id: sid, text: refs.length ? `${refs.join("\n")}\n\n${prompt}` : prompt });
  }

  private skillsByProfile = new Map<string, Json[]>();

  async skills(profile: string) {
    await this.requireProfile(profile);
    const rows = (await this.api(`/api/skills?profile=${encodeURIComponent(profile)}`)) as unknown as Json[];
    const skills = (Array.isArray(rows) ? rows : []).map((s) => ({
      name: String(s.name ?? ""), description: String(s.description ?? ""),
      category: String(s.category ?? ""), enabled: s.enabled !== false,
    })).filter((s) => s.name);
    this.skillsByProfile.set(profile, skills);
    emit({ ev: "skills", profile, skills });
    return skills;
  }

  // A miss refetches once, so a skill saved from another client is still recognized.
  private async isSkill(profile: string, name: string): Promise<boolean> {
    const has = (list: Json[]) => list.some((s) => s.name === name && s.enabled !== false);
    const cached = this.skillsByProfile.get(profile);
    return (cached !== undefined && has(cached)) || has(await this.skills(profile));
  }

  async skillSave(profile: string, name: string, content: string, category?: string) {
    await this.requireProfile(profile);
    await this.api("/api/skills", { method: "POST",
      body: JSON.stringify({ name, content, profile, ...(category ? { category } : {}) }) });
    emit({ ev: "skillSaved", profile, name });
    // The server caches its skill scan for ~30 s, so a fresh save may be missing from this first list.
    await this.skills(profile);
  }

  // Steer injects text into the running turn; queue holds it until the turn ends. Both are
  // per-message so the global busy_input_mode in the user's config.yaml is never touched.
  // session.steer answers "queued" on accept and "rejected" when the turn already ended.
  async steer(profile: string, text: string) {
    await this.requireProfile(profile);
    const sid = this.sessionByProfile.get(profile);
    try {
      const r = sid ? await this.rpc("session.steer", { session_id: sid, text }) : { status: "rejected" };
      if (r.status === "rejected") {
        await this.send(profile, text);
        return emit({ ev: "steered", profile, session: this.sessionByProfile.get(profile), status: "sent", text });
      }
      emit({ ev: "steered", profile, session: sid, status: String(r.status), text });
    } catch (e) {
      emit({ ev: "steered", profile, session: sid, text, error: e instanceof Error ? e.message : String(e) });
    }
  }

  // prompt.submit with queued:true never steers or interrupts; on an idle session it starts
  // a normal turn and answers "streaming".
  async queue(profile: string, text: string) {
    await this.requireProfile(profile);
    if (!this.sessionByProfile.has(profile)) await this.load(profile);
    const sid = this.sessionByProfile.get(profile) ?? (await this.newSession(profile));
    try {
      const r = await this.rpc("prompt.submit", { session_id: sid, text, queued: true });
      emit({ ev: "queued", profile, session: sid, status: r.status === "streaming" ? "sent" : String(r.status), text });
    } catch (e) {
      emit({ ev: "queued", profile, session: sid, text, error: e instanceof Error ? e.message : String(e) });
    }
  }

  async interrupt(profile: string) {
    const sid = this.sessionByProfile.get(profile);
    if (sid) await this.rpc("session.interrupt", { session_id: sid });
  }

  // Delegated workers of this bot's open chat, straight from the server, so a panel that
  // reloaded mid-run shows the ones it never saw start.
  async subagentList(profile: string) {
    const sid = this.sessionByProfile.get(profile);
    if (!sid) return;
    const r = await this.rpc("subagent.list", { session_id: sid });
    const rows = Array.isArray(r.subagents) ? (r.subagents as Json[]) : [];
    emit({ ev: "subagents", profile, list: rows.filter((s) => s.subagent_id).map((s) => ({
      id: String(s.subagent_id), goal: String(s.goal ?? "").slice(0, 160), tool: String(s.last_tool ?? "").slice(0, 80),
      count: Number(s.tool_count ?? 0), startedAt: Math.round(Number(s.started_at ?? 0) * 1000) })) });
  }

  // The worker reads the text after its current tool call; "queued" is accepted, not yet read.
  async subagentSteer(profile: string, id: string, text: string) {
    const sid = this.sessionByProfile.get(profile);
    try {
      const r = sid ? await this.rpc("subagent.steer", { session_id: sid, subagent_id: id, text }) : { status: "rejected" };
      emit({ ev: "subagent.steered", profile, id, status: String(r.status), text });
    } catch (e) {
      emit({ ev: "subagent.steered", profile, id, text, error: e instanceof Error ? e.message : String(e) });
    }
  }

  async subagentStop(profile: string, id: string) {
    const sid = this.sessionByProfile.get(profile);
    const r = sid ? await this.rpc("subagent.interrupt", { session_id: sid, subagent_id: id }) : { found: false };
    emit({ ev: "subagent.stopped", profile, id, found: r.found === true });
  }

  async listSessions(profile: string) {
    await this.requireProfile(profile);
    const r = await this.rpc("session.list", { limit: 20, ...this.profileParam(profile) });
    const sessions = ((r.sessions as Json[]) ?? []).map((s) => ({
      id: String(s.resolved_id ?? s.id), title: String(s.title || s.preview || "(untitled)").slice(0, 80),
      source: String(s.source ?? ""), startedAt: Number(s.started_at ?? 0), messages: Number(s.message_count ?? 0),
      current: String(s.resolved_id ?? s.id) === this.storedByProfile.get(profile),
    }));
    emit({ ev: "sessions", profile, sessions });
  }

  // REST PATCH/DELETE /api/sessions/{id} (the dashboard's own calls); the list is re-read afterwards.
  async manageSession(profile: string, id: string, action: "rename" | "archive" | "delete", title = "") {
    await this.requireProfile(profile);
    const path = `/api/sessions/${encodeURIComponent(id)}`;
    if (action === "delete") {
      // The server deletes rows the live agent still flushes into; keep the open conversation.
      // keyByProfile also covers a chat started with New, whose stored id storedByProfile does not hold.
      const open = this.sessionByProfile.has(profile) ? this.keyByProfile.get(profile) : undefined;
      if (id === this.storedByProfile.get(profile) || id === open) throw new RemoteError("cannot delete the open conversation");
      await this.api(`${path}?profile=${encodeURIComponent(profile)}`, { method: "DELETE" });
    } else {
      const body = action === "rename" ? { title, profile } : { archived: true, profile };
      await this.api(path, { method: "PATCH", body: JSON.stringify(body) });
    }
    await this.listSessions(profile);
  }

  // Live session ids differ from the stored ids session.list returns; remember which stored
  // conversation each bot is showing so the History list can mark it.
  private storedByProfile = new Map<string, string>();
  // Stored key of each live session (also for a new chat), used to reattach it for a reconnecting panel.
  private keyByProfile = new Map<string, string>();

  // Panel Reconnect: a fresh login and gateway WebSocket, whatever state the old ones were stuck in.
  // Bot templates: role (description + SOUL), model, the bot's own (non-bundled) skills and its routines,
  // as one JSON file. Conversations, memory and credentials are never included.
  async templateExport(profile: string) {
    await this.requireProfile(profile);
    const scope = `profile=${encodeURIComponent(profile)}`;
    const roster = ((await this.api("/api/profiles")).profiles as Json[]) ?? [];
    const row = roster.find((p) => p.name === profile) ?? {};
    const soul = profile === "default" ? {} : await this.api(`/api/profiles/${encodeURIComponent(profile)}/soul`).catch(() => ({}));
    const skillRows = ((await this.api(`/api/skills?${scope}`)) as unknown as Json[]) ?? [];
    const skills: Json[] = [];
    for (const s of skillRows.filter((x) => x.provenance !== "bundled")) {
      const c = await this.api(`/api/skills/content?name=${encodeURIComponent(String(s.name))}&${scope}`);
      skills.push({ name: s.name, category: s.category ?? "", content: c.content ?? "" });
    }
    const jobs = ((await this.api(`/api/cron/jobs?${scope}`)) as unknown as Json[]) ?? [];
    const routines = jobs.map((j) => {
      const sched = (j.schedule as Json | undefined) ?? {};
      return { name: j.name, schedule: sched.kind === "cron" ? sched.expr : (j.schedule_display ?? sched.display), prompt: j.prompt };
    });
    const template = { format: "puri.hermes/bot-template", version: 1, exportedFrom: profile, exportedAt: new Date().toISOString(),
      description: String(row.description ?? ""), soul: String((soul as Json).content ?? ""), provider: String(row.provider ?? ""),
      model: String(row.model ?? ""), skills, routines };
    const dir = existsSync(`${process.env.HOME}/Downloads`) ? `${process.env.HOME}/Downloads` : `${cacheDir}/templates`;
    mkdirSync(dir, { recursive: true });
    const path = `${dir}/hermes-bot-${profile}.json`;
    await Bun.write(path, JSON.stringify(template, null, 2));
    emit({ ev: "template.exported", profile, path, skills: skills.length, routines: routines.length });
  }

  async templateImport(rawPath: string, name: string) {
    const path = rawPath.trim().replace(/^~(?=\/)/, process.env.HOME ?? "~").replace(/^file:\/\//, "");
    const file = Bun.file(path);
    if (!(await file.exists())) throw new RemoteError(`template not found: ${rawPath}`);
    const t = (await file.json().catch(() => null)) as Json | null;
    if (!t || t.format !== "puri.hermes/bot-template") throw new RemoteError("not a puri.hermes bot template");
    const bot = name.trim().toLowerCase().replace(/[^a-z0-9_-]/g, "-");
    if (!bot) throw new RemoteError("template import needs a bot name");
    await this.status();
    if (this.knownProfiles.has(bot)) throw new RemoteError(`@${bot} already exists`);
    await this.create(bot, String(t.description ?? ""));
    await this.profileSave(bot, String(t.description ?? ""), String(t.soul ?? ""));
    if (t.model) await this.setModel(bot, String(t.provider || "custom"), String(t.model));
    for (const s of (t.skills as Json[]) ?? []) await this.skillSave(bot, String(s.name), String(s.content), String(s.category || "") || undefined);
    for (const r of (t.routines as Json[]) ?? []) await this.routineCreate(bot, String(r.name), String(r.schedule), String(r.prompt ?? ""));
    emit({ ev: "template.imported", profile: bot, skills: ((t.skills as Json[]) ?? []).length, routines: ((t.routines as Json[]) ?? []).length });
  }

  // Voice. Speech is synthesised on the server (POST /api/audio/speak) and played locally with pw-play;
  // dictation records the laptop mic with pw-record and transcribes on the server (POST /api/audio/transcribe).
  private player: ReturnType<typeof Bun.spawn> | null = null;
  private recorder: ReturnType<typeof Bun.spawn> | null = null;
  private recordPath = "";

  async speak(profile: string, text: string, play: boolean) {
    await this.requireProfile(profile);
    const clean = text.replace(/^\s*MEDIA:\S+\s*$/gm, "").trim().slice(0, 4000);
    if (!clean) throw new RemoteError("nothing to read aloud");
    const r = await this.api(`/api/audio/speak?profile=${encodeURIComponent(profile)}`, {
      method: "POST", body: JSON.stringify({ text: clean }) });
    const mime = String(r.mime_type ?? "audio/mpeg");
    const local = await saveCache("audio", decodeDataUrl(String(r.data_url ?? "")),
      mime.includes("wav") ? ".wav" : mime.includes("ogg") ? ".ogg" : ".mp3");
    emit({ ev: "speech", profile, local, playing: play });
    if (!play) return;
    this.player?.kill();
    const player = Bun.spawn(["pw-play", local], { stdout: "ignore", stderr: "pipe" });
    this.player = player;
    const code = await player.exited;
    if (this.player === player) this.player = null;
    if (code !== 0 && !player.killed) throw new RemoteError(`could not play audio (pw-play exit ${code})`);
    emit({ ev: "speech.done", profile });
  }

  stopSpeech() {
    this.player?.kill();
    this.player = null;
  }

  dictateStart() {
    if (this.recorder) return;
    mkdirSync(`${cacheDir}/audio`, { recursive: true, mode: 0o700 });
    this.recordPath = `${cacheDir}/audio/dictation-${Date.now()}.wav`;
    this.recorder = Bun.spawn(["pw-record", "--rate", "16000", "--channels", "1", this.recordPath],
      { stdout: "ignore", stderr: "ignore" });
    emit({ ev: "dictation", recording: true });
  }

  async dictateStop(profile: string) {
    const recorder = this.recorder;
    if (!recorder) return;
    this.recorder = null;
    recorder.kill("SIGINT");
    await recorder.exited;
    emit({ ev: "dictation", recording: false });
    try {
      await this.transcribe(profile, this.recordPath);
    } finally {
      await Bun.file(this.recordPath).delete().catch(() => {});
    }
  }

  async transcribe(profile: string, path: string) {
    await this.requireProfile(profile);
    const file = Bun.file(path);
    if (!(await file.exists()) || file.size === 0) throw new RemoteError("no audio was recorded");
    const mime = path.endsWith(".mp3") ? "audio/mpeg" : path.endsWith(".ogg") ? "audio/ogg" : "audio/wav";
    const dataUrl = `data:${mime};base64,${Buffer.from(await file.arrayBuffer()).toString("base64")}`;
    const r = await this.api(`/api/audio/transcribe?profile=${encodeURIComponent(profile)}`, {
      method: "POST", body: JSON.stringify({ data_url: dataUrl, mime_type: mime }) });
    emit({ ev: "transcript", profile, text: String(r.transcript ?? "").trim() });
  }

  async reconnect() {
    this.cookie = "";
    const ws = this.ws;
    if (ws) {
      await new Promise<void>((resolve) => {
        ws.addEventListener("close", () => resolve(), { once: true });
        setTimeout(resolve, 3000);
        ws.close();
      });
    }
    emit(await this.status());
  }

  async openSession(profile: string, session: string) {
    await this.requireProfile(profile);
    const r = await this.rpc("session.resume", { session_id: session, cols: 100, ...this.profileParam(profile) });
    const sid = String(r.session_id);
    this.sessionByProfile.set(profile, sid);
    this.keyByProfile.set(profile, session);
    this.storedByProfile.set(profile, session);
    this.pendingRefs.delete(profile);
    const messages = ((r.messages as Json[]) ?? []).map(historyRow).filter((x): x is HistoryRow => x !== null);
    emit({ ev: "history", profile, session: sid, replace: true, messages });
    for (const m of messages) if (m.role === "bot") void this.fetchMedia(sid, profile, m.text);
  }

  private cronSeen = new Map<string, string>();
  private cronRunning = new Set<string>();

  // The agent session of THIS execution; script-gated runs that found nothing new write no session,
  // and the newest run row would then be an older report.
  private async cronReport(profile: string, jobId: string, exec: Json): Promise<{ session: string; text: string }> {
    const scope = `profile=${encodeURIComponent(profile)}`;
    const began = Date.parse(String(exec.claimed_at ?? exec.started_at ?? "")) / 1000;
    if (!Number.isFinite(began)) return { session: "", text: "" };
    const runs = ((await this.api(`/api/cron/jobs/${encodeURIComponent(jobId)}/runs?${scope}&limit=1`)).runs as Json[]) ?? [];
    const run = runs.find((r) => Number(r.started_at ?? 0) >= began - 5);
    const session = run ? String(run.id ?? "") : "";
    if (!session) return { session: "", text: "" };
    const msgs = ((await this.api(`/api/sessions/${encodeURIComponent(session)}/messages?${scope}`)).messages as Json[]) ?? [];
    const last = [...msgs].reverse().find((m) => m.role === "assistant" && typeof m.content === "string" && m.content.trim());
    return { session, text: last ? String(last.content).trim() : "" };
  }

  // Scheduled jobs run on the VM with no client attached; poll them so the panel can show
  // "running" and raise a notification when a run finishes.
  async pollCron() {
    const jobs = (await this.api("/api/cron/jobs?profile=all")) as unknown as Json[];
    const seenDir = `${cacheDir}/cron-seen`;
    const firstEver = !existsSync(seenDir);
    for (const job of Array.isArray(jobs) ? jobs : []) {
      const id = String(job.id ?? "");
      const profile = String(job.profile_name || job.profile || "default");
      const name = String(job.name || id);
      const exec = (job.latest_execution as Json | null) ?? {};
      const running = job.state === "running" || ["running", "claimed", "started"].includes(String(exec.status ?? exec.state ?? ""));
      if (running !== this.cronRunning.has(id)) {
        if (running) this.cronRunning.add(id);
        else this.cronRunning.delete(id);
        emit({ ev: "cron.running", profile, job: name, running });
      }
      const last = String(job.last_run_at ?? "");
      if (!last) continue;
      const previous = this.cronSeen.get(id);
      this.cronSeen.set(id, last);
      if (firstEver) { claimOnce(seenDir, `${id}@${last}`); continue; }
      if (previous === last) continue;
      // A fresh claim means no helper has reported this run yet (also covers runs missed while the
      // laptop was off); a live change that another instance already claimed is shown without a toast.
      const owner = claimOnce(seenDir, `${id}@${last}`);
      if (!owner && previous === undefined) continue;
      const report = await this.cronReport(profile, id, exec).catch(() => ({ session: "", text: "" }));
      const failed = String(job.last_status ?? "ok") !== "ok";
      // Nothing new ([SILENT] or no agent run) is not worth a toast; failures always are.
      if (!failed && (report.text === "" || report.text === "[SILENT]")) continue;
      emit({ ev: "cron", profile, job: name, at: last, status: String(job.last_status ?? ""),
        error: String(job.last_error ?? ""), session: report.session, text: report.text, notify: owner });
    }
  }

  // Routine management is always scoped to one bot via ?profile=; never "all".
  async routines(profile: string) {
    await this.requireProfile(profile);
    const jobs = (await this.api(`/api/cron/jobs?profile=${encodeURIComponent(profile)}`)) as unknown as Json[];
    emit({ ev: "routines", profile, jobs: (Array.isArray(jobs) ? jobs : []).map((j) => ({
      id: String(j.id ?? ""), name: String(j.name || j.id || ""), schedule_display: String(j.schedule_display ?? ""),
      enabled: j.enabled !== false, state: String(j.state ?? ""), next_run_at: j.next_run_at ?? null,
      last_run_at: j.last_run_at ?? null, last_status: j.last_status ?? null, last_error: j.last_error ?? null,
      paused: j.state === "paused" || j.enabled === false,
    })) });
  }

  // Writes never reach the user's real bot or the shared default bot, whatever the caller (UI or IPC).
  async routineCreate(profile: string, name: string, schedule: string, prompt: string) {
    await this.requireProfile(profile);
    const job = await this.api(`/api/cron/jobs?profile=${encodeURIComponent(profile)}`, {
      method: "POST", body: JSON.stringify({ name, schedule, prompt, deliver: "local" }) });
    emit({ ev: "routine", profile, action: "created", id: String(job.id ?? "") });
    await this.routines(profile);
  }

  async routineAction(profile: string, id: string, action: "pause" | "resume" | "run" | "delete") {
    await this.requireProfile(profile);
    if (!id) throw new RemoteError("routine id is required");
    const path = `/api/cron/jobs/${encodeURIComponent(id)}`;
    const scope = `?profile=${encodeURIComponent(profile)}`;
    if (action === "delete") await this.api(path + scope, { method: "DELETE" });
    else await this.api(`${path}/${action === "run" ? "trigger" : action}${scope}`, { method: "POST" });
    emit({ ev: "routine", profile, action, id });
    await this.routines(profile);
  }

  async routineRuns(profile: string, id: string) {
    await this.requireProfile(profile);
    const r = await this.api(`/api/cron/jobs/${encodeURIComponent(id)}/runs?profile=${encodeURIComponent(profile)}&limit=10`);
    emit({ ev: "routine.runs", profile, id, runs: ((r.runs as Json[]) ?? []).map((x) => ({
      id: String(x.id ?? ""), started_at: x.started_at ?? null, ended_at: x.ended_at ?? null,
      end_reason: x.end_reason ?? null, title: String(x.title || x.preview || ""),
    })) });
  }

  // A trigger can take a while; keep the NDJSON loop free and report failures against the bot.
  private routineCommand(profile: string, run: () => Promise<unknown>) {
    void run().catch((e) => emit({ ev: "error", profile, message: e instanceof Error ? e.message : String(e) }));
  }

  async create(name: string, description = "") {
    await this.api("/api/profiles", { method: "POST", body: JSON.stringify({ name, description, clone_from: "default" }) });
    emit({ ev: "created", name });
    emit(await this.status());
  }

  // Hermes Bot Mode keeps roster flags in ui_meta["hermes-bots"], guarded by a per-namespace revision.
  private async botMeta(): Promise<Map<string, { meta: Json; rev: number }>> {
    const r = await this.rpc("profiles.list", { include_sessions: false });
    return new Map(((r.profiles as Json[]) ?? []).map((x) => [String(x.name), {
      meta: (((x.ui_meta as Json | undefined) ?? {})["hermes-bots"] as Json | undefined) ?? {},
      rev: Number(((x.ui_meta_revisions as Json | undefined) ?? {})["hermes-bots"] ?? 0),
    }]));
  }

  async profileGet(profile: string) {
    await this.requireProfile(profile);
    const row = (((await this.api("/api/profiles")).profiles as Json[]) ?? []).find((x) => x.name === profile);
    const soul = await this.api(`/api/profiles/${encodeURIComponent(profile)}/soul`);
    const meta = (await this.botMeta().catch(() => null))?.get(profile)?.meta ?? {};
    emit({ ev: "profile", profile, description: String(row?.description ?? ""), soul: String(soul.content ?? ""),
      pinned: meta.pinned === true, hidden: meta.hidden === true });
  }

  async profileSave(profile: string, description?: string, soul?: string) {
    await this.requireProfile(profile);
    const base = `/api/profiles/${encodeURIComponent(profile)}`;
    if (typeof description === "string")
      await this.api(`${base}/description`, { method: "PUT", body: JSON.stringify({ description }) });
    if (typeof soul === "string") await this.api(`${base}/soul`, { method: "PUT", body: JSON.stringify({ content: soul }) });
    emit({ ev: "profileSaved", profile });
    emit(await this.status());
    await this.profileGet(profile);
  }

  // clone_channels stays off so the copy never shares the source's messaging tokens.
  async profileDuplicate(profile: string, newName: string) {
    await this.requireProfile(profile);
    if (!newName) throw new RemoteError("a name for the copy is required");
    await this.api("/api/profiles", { method: "POST", body: JSON.stringify({ name: newName, clone_from: profile }) });
    emit({ ev: "created", name: newName });
    emit(await this.status());
  }

  // Roster sections live in the file the hermes-bot-kit Desktop plugin reads, so Hermes Desktop
  // with that kit shows the same layout: "sections" is the order, "assign" maps a bot to one.
  sectionsPath = `${process.env.HERMES_HOME || `${process.env.HOME}/.hermes`}/bot-sections.json`;

  async readSections() {
    const file = Bun.file(this.sectionsPath);
    let raw: Json = {};
    if (await file.exists()) {
      try { raw = JSON.parse(await file.text()) as Json; } catch { throw new RemoteError(`${this.sectionsPath} is not valid JSON`); }
    }
    const sections: string[] = [];
    const add = (name: unknown) => {
      const s = String(name ?? "").trim();
      if (s === "" || s.toLowerCase() === "unassigned") return "";
      const known = sections.find((x) => x.toLowerCase() === s.toLowerCase());
      if (!known) sections.push(s);
      return known ?? s;
    };
    for (const s of Array.isArray(raw.sections) ? raw.sections : []) add(s);
    const assign: Record<string, string> = {};
    for (const [bot, s] of Object.entries((raw.assign as Json | undefined) ?? {})) {
      const name = add(s);
      if (name !== "") assign[bot] = name;
    }
    return { raw, sections, assign };
  }

  async profileSection(profile: string, section: string) {
    await this.requireProfile(profile);
    const layout = await this.readSections();
    const key = Object.keys(layout.assign).find((k) => k.toLowerCase() === profile.toLowerCase());
    const left = key ? layout.assign[key] : "";
    if (key) delete layout.assign[key];
    const name = section.trim();
    if (name !== "" && name.toLowerCase() !== "unassigned") {
      const known = layout.sections.find((s) => s.toLowerCase() === name.toLowerCase());
      if (!known) layout.sections.push(name);
      layout.assign[profile] = known ?? name;
    }
    // A section lasts as long as a bot is in it: drop the one this bot just emptied.
    if (left !== "" && !Object.values(layout.assign).includes(left)) layout.sections = layout.sections.filter((s) => s !== left);
    await Bun.write(this.sectionsPath, JSON.stringify({ ...layout.raw, sections: layout.sections, assign: layout.assign }, null, 2) + "\n");
    emit(await this.status());
  }

  async profileFlag(profile: string, flag: "pinned" | "hidden", value: boolean) {
    await this.requireProfile(profile);
    const cur = (await this.botMeta()).get(profile) ?? { meta: {}, rev: 0 };
    // The server replaces the whole namespace value, so the other Bot Mode fields are sent back unchanged.
    const r = await this.rpc("profiles.configure", { name: profile, ui_meta: { "hermes-bots": { ...cur.meta, [flag]: value } },
      ui_meta_expected_revisions: { "hermes-bots": cur.rev } });
    const applied = (r.applied as Json | undefined) ?? {};
    if (applied.ui_meta !== true)
      throw new RemoteError(applied.ui_meta_conflicts ? `@${profile} was changed elsewhere; try again` : `could not update @${profile}`);
    emit({ ev: "profileSaved", profile });
    emit(await this.status());
    await this.profileGet(profile);
  }

  async remove(name: string) {
    if (!name || name === "default") throw new RemoteError("the default bot cannot be deleted");
    const sid = this.sessionByProfile.get(name);
    if (sid) this.replyBySession.delete(sid);
    this.sessionByProfile.delete(name);
    await this.api(`/api/profiles/${encodeURIComponent(name)}`, { method: "DELETE" });
    emit({ ev: "deleted", name });
    emit(await this.status());
  }

  async setModel(profile: string, provider: string, model: string) {
    await this.requireProfile(profile);
    const scope = `profile=${encodeURIComponent(profile)}`;
    if (provider === "custom") {
      await this.api(`/api/config?${scope}`, {
        method: "PUT", body: JSON.stringify({ config: { model }, profile }) });
    } else {
      await this.api(`/api/profiles/${encodeURIComponent(profile)}/model`, {
        method: "PUT", body: JSON.stringify({ provider, model }) });
    }
    emit({ ev: "model", profile, provider, model });
    emit(await this.status());
  }

  // Reasoning effort. An open chat reports what its agent runs with; without one the bot's
  // config.yaml answers.
  async effortGet(profile: string) {
    await this.requireProfile(profile);
    const sid = this.sessionByProfile.get(profile);
    const r = await this.rpc("config.get", { key: "reasoning", ...(sid ? { session_id: sid } : {}), ...this.profileParam(profile) });
    emit({ ev: "effort", profile, value: String(r.value ?? "") });
  }

  // scope "global" writes agent.reasoning_effort into this bot's config.yaml (the profile param
  // picks whose) and also switches the open chat's agent, so the choice outlives a new chat.
  async effortSet(profile: string, value: string) {
    await this.requireProfile(profile);
    if (!EFFORT_LEVELS.includes(value)) throw new RemoteError(`unknown reasoning effort: ${value}`);
    const sid = this.sessionByProfile.get(profile);
    await this.rpc("config.set", { key: "reasoning", value, scope: "global",
      ...(sid ? { session_id: sid } : {}), ...this.profileParam(profile) });
    emit({ ev: "effort", profile, value, changed: true });
  }

  // Bot Screen. The display ticket and viewer_id come from display.observe on this helper's /api/ws,
  // so take/hand back must run here too; the page only talks to the loopback server below.
  private screenServer: ReturnType<typeof Bun.serve> | null = null;
  private viewerByProfile = new Map<string, string>();
  private screenByProfile = new Map<string, ScreenState>();
  private profileByKey = new Map<string, string>();

  private noteScreen(profile: string, s: Json): ScreenState {
    if (s.profile_key) this.profileByKey.set(String(s.profile_key), profile);
    const prev = this.screenByProfile.get(profile);
    const lease = (s.lease as Json | undefined) ?? prev?.lease ?? null;
    const viewer = this.viewerByProfile.get(profile);
    // Broadcasts carry only a hash of the holder's viewer_id (first 12 hex of SHA-256).
    const mine = !!viewer && lease?.holder === "human"
      && lease.viewer_hash === createHash("sha256").update(viewer).digest("hex").slice(0, 12);
    const state = { profile, running: typeof s.running === "boolean" ? s.running : prev?.running ?? false, lease, mine };
    this.screenByProfile.set(profile, state);
    emit({ ev: "screen", ...state });
    return state;
  }

  private async ensureScreen(profile: string) {
    await this.requireProfile(profile);
    let s = await this.rpc("display.status", this.profileParam(profile));
    if (!s.running) {
      if (s.supported === false || s.installed === false) {
        const why = String(s.blocker || ((s.missing as string[] | undefined) ?? []).join(", ") || "not installed");
        throw new RemoteError(`@${profile} has no Bot Desktop: ${why}`);
      }
      s = await this.rpc("display.start", this.profileParam(profile));
    }
    this.noteScreen(profile, s);
  }

  private async observe(profile: string): Promise<Json> {
    const viewer = this.viewerByProfile.get(profile);
    const r = await this.rpc("display.observe", { ...this.profileParam(profile), ...(viewer ? { viewer_id: viewer } : {}) });
    this.viewerByProfile.set(profile, String(r.viewer_id));
    this.noteScreen(profile, r);
    return r;
  }

  async screenLease(profile: string, op: "take" | "handback"): Promise<ScreenState> {
    await this.requireProfile(profile);
    if (op === "take") {
      await this.ensureScreen(profile);
      if (!this.viewerByProfile.has(profile)) await this.observe(profile);
      const r = await this.rpc("display.lease.acquire", {
        ...this.profileParam(profile), viewer_id: this.viewerByProfile.get(profile) });
      return this.noteScreen(profile, r);
    }
    const viewer = this.viewerByProfile.get(profile);
    // After a helper restart the viewer id that took control is gone; Hermes then only accepts a
    // forced release (which must omit viewer_id), so Hand back still returns control to the bot.
    const r = await this.rpc("display.lease.release", viewer
      ? { ...this.profileParam(profile), viewer_id: viewer }
      : { ...this.profileParam(profile), force: true });
    return this.noteScreen(profile, r);
  }

  private async openRfb(ws: ServerWebSocket<unknown>) {
    const link = ws.data as RfbLink;
    try {
      await this.ensureScreen(link.profile);
      const { ticket, path } = await this.observe(link.profile);
      if (link.closed) return;
      // No Origin header: the bridge accepts native clients; the ticket is single-use and never logged.
      const up = new WebSocket(`${this.creds.url.replace(/^http/, "ws")}${String(path || "/api/display/ws")}`
        + `?display_ticket=${encodeURIComponent(String(ticket))}`);
      up.binaryType = "arraybuffer";
      link.upstream = up;
      up.onopen = () => { for (const m of link.backlog.splice(0)) up.send(m); };
      up.onmessage = (e) => { ws.send(new Uint8Array(e.data as ArrayBuffer)); };
      up.onclose = (e) => {
        if (link.closed) return;
        link.closed = true;
        ws.close(e.code === 1000 || (e.code >= 3000 && e.code < 5000) ? e.code : 1011, e.reason.slice(0, 100));
      };
    } catch (e) {
      link.closed = true;
      const message = e instanceof Error ? e.message : String(e);
      // The page only sees a close code; surface the backend reason in the panel too.
      emit({ ev: "screen.error", profile: link.profile, message });
      ws.close(1011, message.slice(0, 100));
    }
  }

  private screenBase(): string {
    if (!this.screenServer) {
      this.screenServer = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        fetch: async (req, server) => {
          const url = new URL(req.url);
          // Only this page may drive the lease or the socket; other local pages are refused.
          const origin = req.headers.get("origin");
          if (origin && origin !== `http://127.0.0.1:${server.port}`) return new Response("forbidden", { status: 403 });
          const profile = url.searchParams.get("profile") || "default";
          try {
            switch (url.pathname) {
              case "/screen":
                await this.requireProfile(profile);
                return new Response(SCREEN_HTML, { headers: { "Content-Type": "text/html; charset=utf-8" } });
              case "/state":
                return Response.json(this.screenByProfile.get(profile) ?? { profile, running: false, lease: null, mine: false });
              case "/lease": {
                const op = url.searchParams.get("op");
                if (req.method !== "POST" || (op !== "take" && op !== "handback"))
                  return Response.json({ error: "POST /lease?op=take|handback" }, { status: 400 });
                return Response.json(await this.screenLease(profile, op));
              }
              case "/rfb": {
                await this.requireProfile(profile);
                const link: RfbLink = { profile, upstream: null, backlog: [], closed: false };
                return server.upgrade(req, { data: link }) ? undefined : new Response("websocket expected", { status: 400 });
              }
            }
            if (url.pathname.startsWith("/novnc/")) {
              const path = normalize(`${NOVNC_DIR}/${decodeURIComponent(url.pathname.slice(7))}`);
              const file = Bun.file(path);
              if (path.startsWith(`${NOVNC_DIR}/`) && (await file.exists())) return new Response(file);
            }
            return new Response("not found", { status: 404 });
          } catch (e) {
            const message = e instanceof Error ? e.message : String(e);
            return Response.json({ error: message }, { status: e instanceof RemoteError ? 400 : 500 });
          }
        },
        websocket: {
          open: (ws) => { void this.openRfb(ws); },
          message: (ws, msg) => {
            const link = ws.data as RfbLink;
            this.demoByProfile.get(link.profile)?.feed(typeof msg === "string" ? new TextEncoder().encode(msg) : new Uint8Array(msg));
            if (link.upstream?.readyState === WebSocket.OPEN) link.upstream.send(msg);
            else link.backlog.push(msg);
          },
          close: (ws) => {
            const link = ws.data as RfbLink;
            if (link.closed) return;
            link.closed = true;
            // A clean close lets the bridge hand control back, matching Hermes Desktop closing its pane.
            link.upstream?.close(1000);
          },
        },
      });
    }
    return `http://127.0.0.1:${this.screenServer.port}`;
  }

  // A demonstration records the input this helper relays to the bot's screen while the person holds it.
  private demoByProfile = new Map<string, DemoRecorder>();

  async demoStart(profile: string) {
    const s = await this.screenLease(profile, "take");
    if (!s.mine) throw new RemoteError(`could not take over @${profile}'s screen`);
    this.demoByProfile.set(profile, new DemoRecorder());
    emit({ ev: "demo", profile, recording: true });
  }

  async demoStop(profile: string) {
    const steps = this.demoByProfile.get(profile)?.finish() ?? [];
    this.demoByProfile.delete(profile);
    emit({ ev: "demo", profile, recording: false, steps });
    // Closing the screen page already hands control back; only a still-held screen needs releasing.
    if (this.screenByProfile.get(profile)?.mine) await this.screenLease(profile, "handback");
  }

  // Group chats are hosted rooms on the gateway. The log has no push events, so the room a panel
  // has open is polled; every other room is only listed.
  private openRoom = "";
  private roomSeq = 0;
  private roomTimer: ReturnType<typeof setInterval> | null = null;
  private roomPolling = false;
  private roomStatus = "";

  async groups() {
    const r = await this.rpc("groups.list", { limit: 50 });
    emit({ ev: "groups", rooms: ((r.rooms as Json[]) ?? []).map((x) => ({
      id: String(x.room_id), name: String(x.name ?? x.room_id),
      members: ((x.members as Json[]) ?? []).map((m) => String(m.handle ?? m.profile ?? m.member_id)),
      updatedAt: Number(x.updated_at ?? 0) })) });
  }

  async groupCreate(name: string, members: string[]) {
    const title = String(name ?? "").trim();
    if (!title) throw new RemoteError("a group name is required");
    const bots = [...new Set(members ?? [])];
    if (bots.length < 2 || bots.length > 6) throw new RemoteError("pick 2 to 6 bots for a group");
    for (const p of bots) await this.requireProfile(p);
    const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32) || "group";
    const room = `${slug}-${Date.now().toString(36)}`;
    await this.rpc("groups.create", { room_id: room, name: title,
      members: bots.map((p) => ({ member_id: p, profile: p, handle: p, display_name: p })) });
    await this.groups();
    await this.groupOpen(room);
  }

  async groupOpen(room: string) {
    this.groupClose();
    // Start from the recent tail instead of replaying a long room from the first event.
    const head = await this.rpc("groups.log", { room_id: room, since_seq: 0, limit: 1 });
    this.openRoom = room;
    this.roomSeq = Math.max(0, Number(head.latest_seq ?? 0) - 150);
    emit({ ev: "group.opened", room });
    await this.groupPoll();
    this.roomTimer = setInterval(() => void this.groupPoll(), 2500);
  }

  groupClose() {
    if (this.roomTimer) clearInterval(this.roomTimer);
    this.roomTimer = null;
    this.openRoom = "";
    this.roomStatus = "";
  }

  private async groupPoll() {
    const room = this.openRoom;
    if (!room || this.roomPolling) return;
    this.roomPolling = true;
    try {
      const rows: Json[] = [];
      for (let page = 0; page < 10; page++) {
        const r = await this.rpc("groups.log", { room_id: room, since_seq: this.roomSeq, limit: 200 });
        if (room !== this.openRoom) return;
        for (const e of (r.events as Json[]) ?? []) {
          this.roomSeq = Math.max(this.roomSeq, Number(e.seq ?? 0));
          const row = roomRow(e);
          if (row && (row.role !== "bot" || String(row.text).trim())) rows.push(row);
        }
        if (r.has_more !== true) break;
      }
      const d = ((await this.rpc("groups.state", { room_id: room })).driver_status as Json | undefined) ?? {};
      if (room !== this.openRoom) return;
      const working = d.working === true;
      const actions = ((d.pending_actions as Json[] | undefined) ?? []).map(roomAction).filter((a) => a !== null);
      const status = JSON.stringify([working, actions]);
      // Idle polls stay quiet; every connected panel receives these broadcasts.
      if (rows.length === 0 && status === this.roomStatus) return;
      this.roomStatus = status;
      emit({ ev: "group.log", room, rows, working, actions });
    } catch (e) {
      emit({ ev: "group.error", room, message: e instanceof Error ? e.message : String(e) });
    } finally {
      this.roomPolling = false;
    }
  }

  async groupSend(room: string, text: string, thread = "") {
    const body = String(text ?? "").trim();
    if (!body) return;
    const id = `puri-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    // A new message starts its own thread, like a new topic in Hermes Desktop; a reply reuses the thread.
    await this.rpc("groups.send", { room_id: room, event_id: id, payload: { text: body, thread_id: thread || id } });
    if (room === this.openRoom) await this.groupPoll();
  }

  async groupRename(room: string, name: string) {
    const title = String(name ?? "").trim();
    if (!title) throw new RemoteError("a group name is required");
    await this.rpc("groups.rename", { room_id: room, name: title,
      event_id: `puri-rename-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}` });
    await this.groups();
    if (room === this.openRoom) await this.groupPoll();
  }

  // Rooms the panel is not showing are checked for new member messages, so a reply or an @user
  // call in a background room still reaches the user. The first sight of a room only records it.
  private roomSeen = new Map<string, number>();

  async watchRooms() {
    const r = await this.rpc("groups.list", { limit: 50 });
    for (const x of (r.rooms as Json[]) ?? []) {
      const room = String(x.room_id);
      const latest = Number(x.latest_seq ?? 0);
      const seen = this.roomSeen.get(room);
      this.roomSeen.set(room, latest);
      if (seen === undefined || latest <= seen || room === this.openRoom) continue;
      const log = await this.rpc("groups.log", { room_id: room, since_seq: seen, limit: 100 });
      for (const e of (log.events as Json[]) ?? []) {
        if (e.kind !== "message.member") continue;
        const row = roomRow(e);
        const text = String(row?.text ?? "").trim();
        if (!row || !text) continue;
        emit({ ev: "group.activity", room, name: String(x.name ?? room), who: String(row.who), text: text.slice(0, 300),
          mention: /(^|\s)@(user|everyone|all)\b/i.test(text) });
      }
    }
  }

  async groupApprove(room: string, member: string, taskId: string, generation: number, requestId: string, choice: "once" | "deny") {
    await this.rpc("groups.approve", { room_id: room, member_id: member, task_id: taskId,
      execution_generation: generation, choice, request_id: requestId });
    if (room === this.openRoom) await this.groupPoll();
  }

  async groupRetry(room: string, taskId: string) {
    await this.rpc("groups.retry", { room_id: room, task_id: taskId });
    if (room === this.openRoom) await this.groupPoll();
  }

  async groupStop(room: string) {
    const r = await this.rpc("groups.stop", { room_id: room });
    emit({ ev: "group.stopped", room, cancelled: Number(r.cancelled ?? 0) });
    if (room === this.openRoom) await this.groupPoll();
  }

  async groupDisband(room: string) {
    await this.rpc("groups.disband", { room_id: room });
    if (room === this.openRoom) this.groupClose();
    emit({ ev: "group.disbanded", room });
    await this.groups();
  }

  // Group failures belong to the Groups view; the generic error event would end the selected bot's turn state.
  private async groupCommand(room: string, run: () => Promise<unknown>) {
    try {
      await run();
    } catch (e) {
      emit({ ev: "group.error", room, message: e instanceof Error ? e.message : String(e) });
    }
  }

  private screenCommand(profile: string, run: () => Promise<unknown>) {
    // Starting a screen can take seconds; keep the NDJSON loop free and report failures per bot.
    void run().catch((e) => emit({ ev: "screen.error", profile, message: e instanceof Error ? e.message : String(e) }));
  }

  async handle(c: Command) {
    switch (c.cmd) {
      case "refresh": return emit(await this.status());
      case "reconnect": return this.reconnect();
      case "inject": return this.onFrame(c.frame);
      case "speak": return this.speak(c.profile, c.text, c.play !== false);
      case "speak.stop": return this.stopSpeech();
      case "template.export": return this.templateExport(c.profile);
      case "template.import": return this.templateImport(c.path, c.name);
      case "dictate.start": return this.dictateStart();
      case "dictate.stop": return this.dictateStop(c.profile);
      case "dictate.file": return this.transcribe(c.profile, c.path);
      case "demo.start": return this.demoStart(c.profile);
      case "demo.stop": return this.demoStop(c.profile);
      case "groups": return this.groupCommand("", () => this.groups());
      case "group.create": return this.groupCommand("", () => this.groupCreate(c.name, c.members));
      case "group.open": return this.groupCommand(c.room, () => this.groupOpen(c.room));
      case "group.close": return this.groupClose();
      case "group.send": return this.groupCommand(c.room, () => this.groupSend(c.room, c.text, c.thread));
      case "group.rename": return this.groupCommand(c.room, () => this.groupRename(c.room, c.name));
      case "group.stop": return this.groupCommand(c.room, () => this.groupStop(c.room));
      case "group.approve":
        return this.groupCommand(c.room, () => this.groupApprove(c.room, c.member, c.taskId, c.generation, c.requestId, c.choice));
      case "group.retry": return this.groupCommand(c.room, () => this.groupRetry(c.room, c.taskId));
      case "group.disband": return this.groupCommand(c.room, () => this.groupDisband(c.room));
      case "create": return this.create(c.name, c.description);
      case "delete": return this.remove(c.name);
      case "profile.get": return this.profileGet(c.profile);
      case "profile.save": return this.profileSave(c.profile, c.description, c.soul);
      case "profile.duplicate": return this.profileDuplicate(c.profile, c.newName);
      case "profile.section": return this.profileSection(c.profile, c.section);
      case "profile.pin":
      case "profile.hide":
        return this.profileFlag(c.profile, c.cmd === "profile.pin" ? "pinned" : "hidden", c.value === true);
      case "new": {
        try {
          await this.newSession(c.profile);
          return emit({ ev: "cleared", profile: c.profile });
        } catch (e) {
          return emit({ ev: "error", profile: c.profile, message: e instanceof Error ? e.message : String(e) });
        }
      }
      case "load": return this.load(c.profile);
      case "send": return this.send(c.profile, c.text);
      case "skills": return void (await this.skills(c.profile));
      case "skill.save": return this.skillSave(c.profile, c.name, c.content, c.category);
      case "interrupt": return this.interrupt(c.profile);
      case "steer": return this.steer(c.profile, c.text);
      case "queue": return this.queue(c.profile, c.text);
      case "approve": return this.approve(c.requestId, c.choice);
      case "clarify": return this.answerClarify(c.requestId, c.answer, c.questionId);
      case "model": return this.setModel(c.profile, c.provider, c.model);
      case "effort.get": return this.effortGet(c.profile);
      case "subagents": return this.subagentList(c.profile);
      case "subagent.steer": return this.subagentSteer(c.profile, c.id, c.text);
      case "subagent.stop": return this.subagentStop(c.profile, c.id);
      case "effort.set": return this.effortSet(c.profile, c.value);
      case "attach": return this.attach(c.profile, { path: c.path, clipboard: c.clipboard });
      case "sessions": return this.listSessions(c.profile);
      case "open": return this.openSession(c.profile, c.session);
      case "session.rename":
      case "session.archive":
      case "session.delete": {
        const action = c.cmd.slice(8) as "rename" | "archive" | "delete";
        return this.routineCommand(c.profile, () => this.manageSession(c.profile, c.id, action, "title" in c ? c.title : ""));
      }
      case "screen.url":
        await this.requireProfile(c.profile);
        return emit({ ev: "screen.url", profile: c.profile, base: this.screenBase(), open: c.open === true,
          url: `${this.screenBase()}/screen?profile=${encodeURIComponent(c.profile)}` });
      case "screen.take":
      case "screen.handback": {
        const op = c.cmd === "screen.take" ? "take" : "handback";
        return this.screenCommand(c.profile, () => this.screenLease(c.profile, op));
      }
      case "routines": return this.routineCommand(c.profile, () => this.routines(c.profile));
      case "routine.create":
        return this.routineCommand(c.profile, () => this.routineCreate(c.profile, c.name, c.schedule, c.prompt));
      case "routine.pause":
      case "routine.resume":
      case "routine.run":
      case "routine.delete": {
        const action = c.cmd.slice(8) as "pause" | "resume" | "run" | "delete";
        return this.routineCommand(c.profile, () => this.routineAction(c.profile, c.id, action));
      }
      case "routine.runs": return this.routineCommand(c.profile, () => this.routineRuns(c.profile, c.id));
    }
  }
}

// Identifies the code a daemon runs, so a client from an updated plugin replaces an older daemon.
const ownVersion = async () => createHash("sha1").update(await Bun.file(import.meta.path).bytes()).digest("hex").slice(0, 12);

function dial(): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const sock = createConnection(SOCKET_PATH);
    sock.once("error", reject);
    sock.once("connect", () => {
      sock.off("error", reject);
      sock.setEncoding("utf8");
      resolve(sock);
    });
  });
}

function spawnDaemon() {
  mkdirSync(cacheDir, { recursive: true, mode: 0o700 });
  const log = openSync(DAEMON_LOG, "a");
  // The lock serializes racing starts (both panels at once, or an update while the old daemon still exits);
  // the loser gives up and its client connects to the winner.
  spawn("sh", ["-c", 'exec 9>"$2"; flock -w 5 9 || exit 0; exec "$0" "$1" daemon',
    process.execPath, import.meta.path, `${SOCKET_PATH}.lock`], { detached: true, stdio: ["ignore", log, log] }).unref();
  closeSync(log);
}

// Connects (starting the daemon if needed) and reads its greeting; the socket is left paused after it.
async function attachDaemon(): Promise<{ sock: Socket; ready: Json; rest: string }> {
  let sock = await dial().catch(() => null);
  if (!sock) {
    spawnDaemon();
    const deadline = Date.now() + 5000;
    while (!sock && Date.now() < deadline) {
      await Bun.sleep(100);
      sock = await dial().catch(() => null);
    }
    if (!sock) throw new RemoteError(`helper daemon did not start (see ${DAEMON_LOG})`);
  }
  const conn = sock;
  return new Promise((resolve, reject) => {
    let buf = "";
    const onClose = () => reject(new RemoteError("helper daemon closed the connection"));
    const onData = (chunk: string) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      conn.pause();
      conn.off("data", onData);
      conn.off("close", onClose);
      try {
        resolve({ sock: conn, ready: JSON.parse(buf.slice(0, nl)) as Json, rest: buf.slice(nl + 1) });
      } catch (e) {
        reject(e);
      }
    };
    conn.on("data", onData);
    conn.on("close", onClose);
  });
}

// What Panel.qml runs: a pipe between the panel and the shared daemon, same NDJSON both ways.
async function client() {
  await loadCredentials(); // report a missing credentials file in the panel, not only in the daemon log
  const version = await ownVersion();
  let { sock, ready, rest } = await attachDaemon();
  if (ready.version !== version) {
    sock.write(`${JSON.stringify({ cmd: "shutdown" })}\n`);
    const deadline = Date.now() + 5000;
    while (existsSync(SOCKET_PATH) && Date.now() < deadline) await Bun.sleep(100);
    sock.destroy();
    ({ sock, ready, rest } = await attachDaemon());
    if (ready.version !== version) throw new RemoteError(`helper daemon runs ${ready.version}, expected ${version}`);
  }
  process.stdout.write(`${JSON.stringify(ready)}\n${rest}`);
  sock.on("data", (chunk: string) => { process.stdout.write(chunk); });
  sock.on("error", () => {});
  // Exit non-zero so the panel's restart timer relaunches the client (and with it a daemon).
  sock.on("close", () => {
    process.stderr.write("helper daemon closed the connection\n");
    process.exit(1);
  });
  sock.resume();
  for await (const line of console) if (line.trim()) sock.write(`${line}\n`);
  process.exit(0);
}

async function daemon(remote: Remote) {
  const version = await ownVersion();
  mkdirSync(cacheDir, { recursive: true, mode: 0o700 });
  if (existsSync(SOCKET_PATH)) {
    if (await dial().then((s) => { s.destroy(); return true; }, () => false)) {
      process.stderr.write("another hermes-remote daemon is already listening\n");
      process.exit(0);
    }
    rmSync(SOCKET_PATH, { force: true });
  }
  const clients = new Set<Socket>();
  const send = (sock: Socket, ev: Json) => sock.write(`${JSON.stringify(ev)}\n`);
  // Cron reports that land while no panel is connected (a shell restart) go to the next one.
  const backlog: Json[] = [];
  emit = (ev: Json) => {
    if (clients.size === 0) {
      if (ev.ev === "cron" || ev.ev === "group.activity") backlog.push(ev);
      return;
    }
    for (const c of clients) send(c, ev);
  };
  const run = (c: Command) => remote.handle(c)
    .catch((e) => emit({ ev: "error", message: e instanceof Error ? e.message : String(e) }));
  let queue: Promise<unknown> = Promise.resolve();
  const server = createServer((sock) => {
    sock.setEncoding("utf8");
    send(sock, { ev: "ready", version });
    // Every panel instance gets every event; only the oldest one raises desktop notifications.
    send(sock, { ev: "role", primary: clients.size === 0 });
    clients.add(sock);
    for (const ev of backlog.splice(0)) send(sock, ev);
    let buf = "";
    sock.on("data", (chunk: string) => {
      buf += chunk;
      for (let nl = buf.indexOf("\n"); nl >= 0; nl = buf.indexOf("\n")) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        let c: Command;
        try {
          c = JSON.parse(line) as Command;
        } catch (e) {
          emit({ ev: "error", message: e instanceof Error ? e.message : String(e) });
          continue;
        }
        if ((c as { cmd: string }).cmd === "shutdown") return shutdown();
        // Out of band: a reconnect must be able to unstick a command waiting on a dead socket.
        if (c.cmd === "reconnect") void run(c);
        else queue = queue.then(() => run(c));
      }
    });
    sock.on("error", () => {});
    sock.on("close", () => {
      const wasPrimary = clients.values().next().value === sock;
      clients.delete(sock);
      const next = clients.values().next().value;
      if (wasPrimary && next) send(next, { ev: "role", primary: true });
    });
  });
  function shutdown() {
    server.close();
    rmSync(SOCKET_PATH, { force: true });
    rmSync(DAEMON_PID, { force: true });
    process.exit(0);
  }
  server.on("error", (e) => {
    process.stderr.write(`daemon socket error: ${e.message}\n`);
    process.exit(1);
  });
  const umask = process.umask(0o077);
  server.listen(SOCKET_PATH, () => {
    process.umask(umask);
    chmodSync(SOCKET_PATH, 0o600);
    writeFileSync(DAEMON_PID, `${process.pid}\n`);
    process.stderr.write(`${new Date().toISOString()} daemon ${version} listening on ${SOCKET_PATH} (pid ${process.pid})\n`);
  });
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  // Nobody can reach a daemon whose socket file is gone, and it would hold the start lock forever.
  setInterval(() => { if (!existsSync(SOCKET_PATH)) shutdown(); }, 10000);
  const pollCron = () => remote.pollCron()
    .catch((e) => process.stderr.write(`cron poll failed: ${e instanceof Error ? e.message : String(e)}\n`))
    .finally(() => setTimeout(pollCron, CRON_POLL_MS));
  void pollCron();
  const watchRooms = () => remote.watchRooms()
    .catch((e) => process.stderr.write(`room watch failed: ${e instanceof Error ? e.message : String(e)}\n`))
    .finally(() => setTimeout(watchRooms, ROOM_WATCH_MS));
  void watchRooms();
}

async function main() {
  const [mode = "stdio", ...rest] = process.argv.slice(2);
  if (mode === "stdio") return client();
  const remote = new Remote(await loadCredentials());
  if (mode === "status") return console.log(JSON.stringify(await remote.status()));
  if (mode === "chat") {
    const [profile = "default", ...words] = rest;
    remote.autoApprove = process.env.HERMES_REMOTE_AUTO_APPROVE === "once" ? "once" : "deny";
    const finished = new Promise<void>((resolve) => {
      const write = process.stdout.write.bind(process.stdout);
      process.stdout.write = ((chunk: string) => {
        if (chunk.includes('"ev":"done"') || chunk.includes('"ev":"error"')) setTimeout(resolve, 0);
        return write(chunk);
      }) as typeof process.stdout.write;
    });
    await remote.send(profile, words.join(" "));
    await finished;
    process.exit(0);
  }
  if (mode === "daemon") return daemon(remote);
  throw new RemoteError(`unknown mode: ${mode}`);
}

main().catch((e) => {
  emit({ ev: "error", fatal: true, message: e instanceof Error ? e.message : String(e) });
  process.exit(1);
});
