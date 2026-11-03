import crypto from "node:crypto";
import http from "node:http";
import { delta, rateOfChange } from "./alerts.js";
import { insulinOnBoard, podStatus } from "./insulin.js";
import type { GlucoseMonitor } from "./monitor.js";
import type { AlertSettings, ApnsEnvironment, Device } from "./types.js";

/**
 * Small JSON API the iPhone app talks to. Every route except /health needs
 * `Authorization: Bearer <APP_SECRET>`.
 */

export interface ApiOptions {
  monitor: GlucoseMonitor;
  appSecret: string;
  now?: () => number;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

const MAX_BODY_BYTES = 64 * 1024;
const HEALTHY_POLL_MS = 3 * 60_000;

function safeEqual(a: string, b: string): boolean {
  const ha = crypto.createHash("sha256").update(a).digest();
  const hb = crypto.createHash("sha256").update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

async function readJson(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, "Request body too large");
    chunks.push(chunk as Buffer);
  }
  if (size === 0) return {};
  try {
    const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error();
    return parsed as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "Body must be a JSON object");
  }
}

function num(body: Record<string, unknown>, key: string, opts?: { min?: number; max?: number; optional?: false }): number;
function num(body: Record<string, unknown>, key: string, opts: { min?: number; max?: number; optional: true }): number | undefined;
function num(body: Record<string, unknown>, key: string, opts: { min?: number; max?: number; optional?: boolean } = {}): number | undefined {
  const v = body[key];
  if (v === undefined || v === null) {
    if (opts.optional) return undefined;
    throw new HttpError(400, `${key} is required`);
  }
  if (typeof v !== "number" || !Number.isFinite(v)) throw new HttpError(400, `${key} must be a number`);
  if (opts.min !== undefined && v < opts.min) throw new HttpError(400, `${key} must be at least ${opts.min}`);
  if (opts.max !== undefined && v > opts.max) throw new HttpError(400, `${key} must be at most ${opts.max}`);
  return v;
}

function str(body: Record<string, unknown>, key: string, opts?: { optional?: false; max?: number }): string;
function str(body: Record<string, unknown>, key: string, opts: { optional: true; max?: number }): string | undefined;
function str(body: Record<string, unknown>, key: string, opts: { optional?: boolean; max?: number } = {}): string | undefined {
  const v = body[key];
  if (v === undefined || v === null) {
    if (opts.optional) return undefined;
    throw new HttpError(400, `${key} is required`);
  }
  if (typeof v !== "string") throw new HttpError(400, `${key} must be a string`);
  if (v.length > (opts.max ?? 512)) throw new HttpError(400, `${key} is too long`);
  return v;
}

function bool(body: Record<string, unknown>, key: string): boolean | undefined {
  const v = body[key];
  if (v === undefined) return undefined;
  if (typeof v !== "boolean") throw new HttpError(400, `${key} must be true or false`);
  return v;
}

/** Times from the app are Unix seconds. */
function timeFrom(body: Record<string, unknown>, now: number): number {
  const t = num(body, "time", { optional: true });
  if (t === undefined) return now;
  const ms = t * 1000;
  if (ms > now + 5 * 60_000) throw new HttpError(400, "time is in the future");
  if (ms < now - 7 * 24 * 3_600_000) throw new HttpError(400, "time is more than 7 days ago");
  return ms;
}

const sec = (ms: number | undefined) => (ms === undefined ? undefined : Math.floor(ms / 1000));

export function createApi(opts: ApiOptions): http.Server {
  const { monitor, appSecret } = opts;
  const now = opts.now ?? Date.now;

  const statusBody = () => {
    const s = monitor.snapshot;
    const t = now();
    const pod = podStatus(s.podChanges);
    return {
      now: sec(t),
      readings: s.readings.map((r) => ({ mgdl: r.mgdl, trend: r.trend, time: sec(r.time) })),
      delta: delta(s.readings) ?? null,
      ratePerMinute: rateOfChange(s.readings) ?? null,
      iob: insulinOnBoard(s.insulin, t),
      pod: pod
        ? { id: pod.id, changedAt: sec(pod.changedAt), expiresAt: sec(pod.expiresAt), graceEndsAt: sec(pod.graceEndsAt) }
        : null,
      insulin: s.insulin.map((e) => ({ ...e, time: sec(e.time) })),
      carbs: s.carbs.map((e) => ({ ...e, time: sec(e.time) })),
      podChanges: s.podChanges.map((e) => ({ ...e, time: sec(e.time) })),
      settings: s.settings,
      snoozeUntil: sec(s.alertState.snoozeUntil) ?? null,
      activeAlerts: Object.keys(s.alertState.active),
      server: {
        lastPollAt: sec(monitor.lastPollAt) ?? null,
        lastSuccessAt: sec(monitor.lastSuccessAt) ?? null,
        lastError: monitor.lastError ?? null,
      },
    };
  };

  const routes: Array<{
    method: string;
    pattern: RegExp;
    handler: (match: RegExpExecArray, body: Record<string, unknown>) => Promise<unknown>;
  }> = [
    { method: "GET", pattern: /^\/status$/, handler: async () => statusBody() },

    {
      method: "PUT",
      pattern: /^\/devices\/([\w-]{1,64})$/,
      handler: async (m, body) => {
        const id = m[1]!;
        const environment = str(body, "environment", { optional: true });
        if (environment !== undefined && environment !== "sandbox" && environment !== "production") {
          throw new HttpError(400, "environment must be sandbox or production");
        }
        await monitor.mutate((s) => {
          let device = s.devices.find((d) => d.id === id);
          if (!device) {
            device = {
              id,
              name: "iPhone",
              environment: "production",
              alertsEnabled: true,
              wantsLiveActivity: false,
              updatedAt: now(),
            } satisfies Device;
            s.devices.push(device);
          }
          device.name = str(body, "name", { optional: true, max: 64 }) ?? device.name;
          if (environment) device.environment = environment as ApnsEnvironment;
          const alertToken = str(body, "alertToken", { optional: true, max: 200 });
          if (alertToken !== undefined) device.alertToken = alertToken;
          const startToken = str(body, "pushToStartToken", { optional: true, max: 200 });
          if (startToken !== undefined) device.pushToStartToken = startToken;
          device.alertsEnabled = bool(body, "alertsEnabled") ?? device.alertsEnabled;
          device.wantsLiveActivity = bool(body, "wantsLiveActivity") ?? device.wantsLiveActivity;
          device.updatedAt = now();
        });
        return { ok: true };
      },
    },
    {
      method: "DELETE",
      pattern: /^\/devices\/([\w-]{1,64})$/,
      handler: async (m) => {
        await monitor.mutate((s) => {
          s.devices = s.devices.filter((d) => d.id !== m[1]);
        });
        return { ok: true };
      },
    },
    {
      method: "PUT",
      pattern: /^\/devices\/([\w-]{1,64})\/activity$/,
      handler: async (m, body) => {
        const token = str(body, "token", { max: 200 });
        const startedAt = num(body, "startedAt", { optional: true });
        let found = false;
        await monitor.mutate(
          (s) => {
            const device = s.devices.find((d) => d.id === m[1]);
            if (!device) return;
            found = true;
            device.activity = { token, startedAt: startedAt !== undefined ? startedAt * 1000 : now() };
            device.wantsLiveActivity = true;
            device.lastStartAttempt = undefined;
          },
          { refreshActivities: true },
        );
        if (!found) throw new HttpError(404, "Register the device first");
        return { ok: true };
      },
    },
    {
      method: "DELETE",
      pattern: /^\/devices\/([\w-]{1,64})\/activity$/,
      handler: async (m, body) => {
        // keepRunning: true means "this activity ended, but start a new one" (e.g. iOS ended it).
        // With a token, only clear the activity if it is still that one, so a renewal is not undone.
        const keepRunning = bool(body, "keepRunning") ?? false;
        const token = str(body, "token", { optional: true, max: 200 });
        await monitor.mutate((s) => {
          const device = s.devices.find((d) => d.id === m[1]);
          if (!device) return;
          if (token === undefined || device.activity?.token === token) device.activity = undefined;
          if (!keepRunning) device.wantsLiveActivity = false;
        });
        return { ok: true };
      },
    },

    {
      method: "POST",
      pattern: /^\/log\/insulin$/,
      handler: async (_m, body) => {
        const entry = {
          id: crypto.randomUUID(),
          units: num(body, "units", { min: 0.05, max: 30 }),
          time: timeFrom(body, now()),
          note: str(body, "note", { optional: true, max: 200 }),
        };
        await monitor.mutate((s) => s.insulin.push(entry), { refreshActivities: true });
        return entry;
      },
    },
    {
      method: "POST",
      pattern: /^\/log\/carbs$/,
      handler: async (_m, body) => {
        const entry = {
          id: crypto.randomUUID(),
          grams: num(body, "grams", { min: 1, max: 300 }),
          time: timeFrom(body, now()),
          note: str(body, "note", { optional: true, max: 200 }),
        };
        await monitor.mutate((s) => s.carbs.push(entry));
        return entry;
      },
    },
    {
      method: "POST",
      pattern: /^\/log\/pod$/,
      handler: async (_m, body) => {
        const entry = { id: crypto.randomUUID(), time: timeFrom(body, now()) };
        await monitor.mutate((s) => s.podChanges.push(entry), { refreshActivities: true });
        return entry;
      },
    },
    {
      method: "DELETE",
      pattern: /^\/log\/(insulin|carbs|pod)\/([\w-]{1,64})$/,
      handler: async (m) => {
        const [, kind, id] = m;
        await monitor.mutate(
          (s) => {
            if (kind === "insulin") s.insulin = s.insulin.filter((e) => e.id !== id);
            if (kind === "carbs") s.carbs = s.carbs.filter((e) => e.id !== id);
            if (kind === "pod") s.podChanges = s.podChanges.filter((e) => e.id !== id);
          },
          { refreshActivities: kind !== "carbs" },
        );
        return { ok: true };
      },
    },

    {
      method: "PUT",
      pattern: /^\/settings$/,
      handler: async (_m, body) => {
        const current = monitor.snapshot.settings;
        const next: AlertSettings = {
          urgentLow: num(body, "urgentLow", { optional: true, min: 40, max: 80 }) ?? current.urgentLow,
          low: num(body, "low", { optional: true, min: 50, max: 150 }) ?? current.low,
          high: num(body, "high", { optional: true, min: 120, max: 400 }) ?? current.high,
          urgentLowSoonMinutes:
            num(body, "urgentLowSoonMinutes", { optional: true, min: 0, max: 60 }) ?? current.urgentLowSoonMinutes,
          fastRate: num(body, "fastRate", { optional: true, min: 0, max: 10 }) ?? current.fastRate,
          noDataMinutes: num(body, "noDataMinutes", { optional: true, min: 10, max: 120 }) ?? current.noDataMinutes,
          repeatMinutes: current.repeatMinutes,
          unit: current.unit,
        };
        const unit = str(body, "unit", { optional: true });
        if (unit !== undefined) {
          if (unit !== "mgdl" && unit !== "mmol") throw new HttpError(400, "unit must be mgdl or mmol");
          next.unit = unit;
        }
        if (typeof body.repeatMinutes === "object" && body.repeatMinutes !== null) {
          const r = body.repeatMinutes as Record<string, unknown>;
          next.repeatMinutes = {
            urgentLow: num(r, "urgentLow", { optional: true, min: 1, max: 30 }) ?? current.repeatMinutes.urgentLow,
            urgentLowSoon:
              num(r, "urgentLowSoon", { optional: true, min: 0, max: 60 }) ?? current.repeatMinutes.urgentLowSoon,
            low: num(r, "low", { optional: true, min: 0, max: 120 }) ?? current.repeatMinutes.low,
            high: num(r, "high", { optional: true, min: 0, max: 240 }) ?? current.repeatMinutes.high,
            noData: num(r, "noData", { optional: true, min: 0, max: 240 }) ?? current.repeatMinutes.noData,
          };
        }
        if (!(next.urgentLow < next.low && next.low < next.high)) {
          throw new HttpError(400, "Thresholds must be urgent low < low < high");
        }
        await monitor.mutate((s) => (s.settings = next), { refreshActivities: true });
        return next;
      },
    },
    {
      method: "POST",
      pattern: /^\/snooze$/,
      handler: async (_m, body) => {
        const minutes = num(body, "minutes", { min: 0, max: 240 });
        const until = minutes > 0 ? now() + minutes * 60_000 : undefined;
        await monitor.mutate((s) => (s.alertState.snoozeUntil = until));
        return { snoozeUntil: sec(until) ?? null };
      },
    },
    {
      method: "POST",
      pattern: /^\/test-alert$/,
      handler: async (_m, body) => {
        await monitor.testAlert(str(body, "deviceId", { optional: true, max: 64 }));
        return { ok: true };
      },
    },
  ];

  return http.createServer(async (req, res) => {
    const send = (status: number, payload: unknown) => {
      res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(JSON.stringify(payload));
    };
    try {
      const url = new URL(req.url ?? "/", "http://localhost");

      // Process is up. Used by the host's health check, so a Dexcom outage never takes the API offline.
      if (req.method === "GET" && url.pathname === "/health/live") {
        send(200, { ok: true });
        return;
      }

      // Unauthenticated so an uptime monitor can check it: 503 when Dexcom Share has not been
      // reached for 3 minutes. Reveals no glucose data.
      if (req.method === "GET" && url.pathname === "/health") {
        const last = monitor.lastSuccessAt;
        const healthy = last !== undefined && now() - last < HEALTHY_POLL_MS;
        send(healthy ? 200 : 503, { ok: healthy, lastSuccessAt: sec(last) ?? null });
        return;
      }

      const auth = req.headers.authorization ?? "";
      if (!auth.startsWith("Bearer ") || !safeEqual(auth.slice(7), appSecret)) {
        throw new HttpError(401, "Unauthorized");
      }

      for (const route of routes) {
        if (route.method !== req.method) continue;
        const match = route.pattern.exec(url.pathname);
        if (!match) continue;
        const body = req.method === "GET" ? {} : await readJson(req);
        send(200, await route.handler(match, body));
        return;
      }
      throw new HttpError(404, "Not found");
    } catch (err) {
      if (err instanceof HttpError) {
        send(err.status, { error: err.message });
      } else {
        console.error("[api] error", err);
        send(500, { error: "Internal error" });
      }
    }
  });
}
