import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

interface EventRow {
  t?: number;
  bot?: string;
  kind?: string;
  event?: string;
  reason?: string;
  result?: string;
  label?: string;
  action?: string;
  [key: string]: unknown;
}

const logsDir = join(process.cwd(), "logs", "bots");
const requestedPrefix = process.argv[2] ?? latestPrefix();
const files = readdirSync(logsDir)
  .filter(file => file.startsWith(requestedPrefix) && file.endsWith(".jsonl"))
  .sort();

if (files.length === 0) {
  throw new Error(`No bot logs found for prefix ${requestedPrefix}`);
}

const counts = new Map<string, number>();
const samples = new Map<string, EventRow>();
let colorSystems = 0;
let roleSystems = 0;
const finishReasons = new Map<string, number>();
const colorExchangeGroups = new Map<string, number[]>();
const roleExchangeGroups = new Map<string, number[]>();

for (const file of files) {
  const lines = readFileSync(join(logsDir, file), "utf-8").split(/\n/).filter(Boolean);
  for (const line of lines) {
    const row = JSON.parse(line) as EventRow;
    const key = `${row.kind ?? "unknown"}:${row.event ?? row.reason ?? row.result ?? row.label ?? row.action ?? ""}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
    if (!samples.has(key)) samples.set(key, row);

    if (row.kind === "message_count_increased") {
      const messages = [...asArray(row.recentWhispers), ...asArray(row.recentShouts)];
      if (messages.some(m => String(m.text ?? "").toUpperCase().includes("COLOR XCHG"))) colorSystems++;
      if (messages.some(m => String(m.text ?? "").toUpperCase().includes("ROLE XCHG"))) roleSystems++;
      recordExchangeGroups(row, messages, "COLOR", colorExchangeGroups);
      recordExchangeGroups(row, messages, "ROLE", roleExchangeGroups);
    }

    if (row.kind === "activity_finished") {
      const reason = String(row.reason ?? "unknown");
      finishReasons.set(reason, (finishReasons.get(reason) ?? 0) + 1);
    }
  }
}

const interesting = [
  "pursue_telemetry:opening_own_whisper",
  "pursue_telemetry:host_blocked_by_nearby_whisper_escape",
  "pursue_telemetry:host_blocked_by_nearby_whisper_retarget",
  "pursue_telemetry:target_seen_in_crowd_retarget",
  "pursue_telemetry:target_already_in_conversation_retarget",
  "pursue_telemetry:open_attempt_timeout_retarget",
  "pursue_telemetry:requesting_entry",
  "pursue_telemetry:waiting_entry_timeout_cancel",
  "pursue_telemetry:alone_whisper_timeout",
  "reactive_atomic_queued:grant_entry",
  "reactive_telemetry:grant_entry_blocked",
  "reactive_atomic_queued:reactive_color_offer",
  "whisper_action_selected:reactive_color_offer",
  "reactive_atomic_queued:accept_color",
  "whisper_action_selected:accept_color",
  "target_penalty_started:",
  "target_penalty_expired:",
  "ui_navigation_failed:reactive_color_offer",
];

console.log(`prefix=${requestedPrefix} files=${files.length}`);
console.log(`visible system exchange messages: color=${colorSystems} role=${roleSystems}`);
printExchangeSummary("unique color exchange groups", colorExchangeGroups);
printExchangeSummary("unique role exchange groups", roleExchangeGroups);
console.log("");
console.log("selected buckets:");
for (const key of interesting) {
  console.log(`${String(counts.get(key) ?? 0).padStart(5)}  ${key}`);
}

console.log("");
console.log("top pursue/activity buckets:");
for (const [key, count] of [...counts.entries()]
  .filter(([key]) => key.startsWith("pursue_telemetry:") || key.startsWith("activity_finished:"))
  .sort((a, b) => b[1] - a[1])
  .slice(0, 35)) {
  console.log(`${String(count).padStart(5)}  ${key}`);
}

console.log("");
console.log("top activity finish reasons:");
for (const [reason, count] of [...finishReasons.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20)) {
  console.log(`${String(count).padStart(5)}  ${reason}`);
}

function latestPrefix(): string {
  const latest = readdirSync(logsDir)
    .filter(file => file.endsWith(".jsonl"))
    .sort()
    .at(-1);
  if (!latest) throw new Error(`No bot logs found in ${logsDir}`);
  return latest.split("-")[0];
}

function asArray(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value) ? value as Array<Record<string, unknown>> : [];
}

function recordExchangeGroups(
  row: EventRow,
  messages: Array<Record<string, unknown>>,
  mode: "COLOR" | "ROLE",
  groups: Map<string, number[]>,
): void {
  const hasExchange = messages.some(m => {
    const text = String(m.text ?? "").toUpperCase();
    return text.includes(`${mode} XCHG`) || (text.includes(mode) && text.includes("SWAPPED"));
  });
  if (!hasExchange) return;

  const self = typeof row.self === "string" ? row.self : typeof row.bot === "string" ? row.bot : null;
  const occupants = asStringArray(row.occupants);
  const participants = [self, ...occupants].filter((name): name is string => !!name).sort();
  if (participants.length < 2) return;

  const key = participants.join("+");
  const ticks = groups.get(key) ?? [];
  const tick = typeof row.t === "number" ? row.t : -1;
  if (!ticks.includes(tick)) ticks.push(tick);
  groups.set(key, ticks);
}

function printExchangeSummary(label: string, groups: Map<string, number[]>): void {
  const repeats = [...groups.entries()].filter(([, ticks]) => ticks.length > 1);
  console.log(`${label}: ${groups.size} (${repeats.length} repeated groups)`);
  for (const [group, ticks] of [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0])).slice(0, 30)) {
    console.log(`  ${group}: ${ticks.length} sighting${ticks.length === 1 ? "" : "s"} @ ${ticks.slice(0, 6).join(",")}`);
  }
}

function asStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}
