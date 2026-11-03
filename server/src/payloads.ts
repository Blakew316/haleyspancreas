import { delta } from "./alerts.js";
import type { AlertEvent, AlertSettings, Reading } from "./types.js";

/**
 * JSON shapes sent to the iPhone. The Live Activity content state must match
 * `GlucoseActivityAttributes.ContentState` in ios/Shared/GlucoseActivityAttributes.swift
 * field for field. Times are Unix seconds (not Swift's 2001 reference date).
 */

export const ACTIVITY_ATTRIBUTES_TYPE = "GlucoseActivityAttributes";

/** After this long without an update, iOS greys the Live Activity out as stale. */
export const STALE_AFTER_SEC = 11 * 60;

export interface ContentState {
  mgdl: number;
  trend: string;
  readingTime: number;
  delta?: number;
  unit: string;
  low: number;
  high: number;
  iob?: number;
  podExpiresAt?: number;
  /** Last hour of readings, oldest first, for the mini graph. */
  history: number[];
}

export interface ContentInput {
  readings: Reading[];
  settings: AlertSettings;
  iob?: number;
  podExpiresAt?: number;
}

const sec = (ms: number) => Math.floor(ms / 1000);

export function contentState(input: ContentInput): ContentState | undefined {
  const latest = input.readings[0];
  if (!latest) return undefined;
  const hourAgo = latest.time - 60 * 60_000;
  const history = input.readings
    .filter((r) => r.time > hourAgo)
    .map((r) => r.mgdl)
    .reverse();
  const state: ContentState = {
    mgdl: latest.mgdl,
    trend: latest.trend,
    readingTime: sec(latest.time),
    unit: input.settings.unit,
    low: input.settings.low,
    high: input.settings.high,
    history,
  };
  const d = delta(input.readings);
  if (d !== undefined) state.delta = d;
  if (input.iob !== undefined && input.iob > 0) state.iob = input.iob;
  if (input.podExpiresAt !== undefined) state.podExpiresAt = sec(input.podExpiresAt);
  return state;
}

/**
 * With `alert`, iOS lights the screen and expands the Dynamic Island. No sound is set here,
 * because the separate alert notification plays the sound.
 */
export function liveActivityUpdate(state: ContentState, nowMs: number, alert?: AlertEvent) {
  return {
    aps: {
      timestamp: sec(nowMs),
      event: "update",
      "content-state": state,
      "stale-date": state.readingTime + STALE_AFTER_SEC,
      "relevance-score": 100,
      ...(alert ? { alert: { title: alert.title, body: alert.body } } : {}),
    },
  };
}

export function liveActivityStart(state: ContentState, patientName: string, nowMs: number) {
  return {
    aps: {
      timestamp: sec(nowMs),
      event: "start",
      "content-state": state,
      "stale-date": state.readingTime + STALE_AFTER_SEC,
      "relevance-score": 100,
      "attributes-type": ACTIVITY_ATTRIBUTES_TYPE,
      attributes: { name: patientName },
      // iOS requires an alert on push-to-start. It is shown silently in the Live Activity.
      alert: { title: `${patientName}'s glucose`, body: "Live updates resumed." },
    },
  };
}

export function liveActivityEnd(nowMs: number) {
  return {
    aps: {
      timestamp: sec(nowMs),
      event: "end",
      "dismissal-date": sec(nowMs),
    },
  };
}

export function alertNotification(event: AlertEvent) {
  const critical = event.level === "critical";
  return {
    aps: {
      alert: { title: event.title, body: event.body },
      // Critical sound only plays if Apple granted the critical-alerts entitlement;
      // otherwise iOS falls back to a normal time-sensitive notification.
      sound: critical ? { critical: 1, name: "default", volume: 1.0 } : "default",
      "interruption-level": critical ? "critical" : "time-sensitive",
      "thread-id": "glucose-alerts",
      "relevance-score": critical ? 1 : 0.8,
    },
    kind: event.kind,
  };
}
