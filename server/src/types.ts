/** Trend arrows as reported by Dexcom Share, normalised to camelCase. */
export type Trend =
  | "none"
  | "doubleUp"
  | "singleUp"
  | "fortyFiveUp"
  | "flat"
  | "fortyFiveDown"
  | "singleDown"
  | "doubleDown"
  | "notComputable"
  | "rateOutOfRange";

export interface Reading {
  /** Glucose in mg/dL. */
  mgdl: number;
  trend: Trend;
  /** Sensor reading time, ms since Unix epoch. */
  time: number;
}

export interface InsulinEntry {
  id: string;
  units: number;
  /** ms since epoch */
  time: number;
  note?: string;
}

export interface CarbEntry {
  id: string;
  grams: number;
  time: number;
  note?: string;
}

export interface PodChange {
  id: string;
  time: number;
}

export type GlucoseUnit = "mgdl" | "mmol";

export interface AlertSettings {
  /** Fires at or below this value. Never snoozable. */
  urgentLow: number;
  low: number;
  high: number;
  /** Warn when the projection says we reach urgentLow within this many minutes. 0 disables. */
  urgentLowSoonMinutes: number;
  /** mg/dL per minute. Fires when the rate of change is at or beyond this. 0 disables. */
  fastRate: number;
  /** Minutes without a new reading before a "no data" alert. */
  noDataMinutes: number;
  /** How often to repeat an alert while its condition is still true. 0 means once per episode. */
  repeatMinutes: {
    urgentLow: number;
    urgentLowSoon: number;
    low: number;
    high: number;
    noData: number;
  };
  unit: GlucoseUnit;
}

export const DEFAULT_SETTINGS: AlertSettings = {
  urgentLow: 55,
  low: 70,
  high: 250,
  urgentLowSoonMinutes: 20,
  fastRate: 3,
  noDataMinutes: 20,
  repeatMinutes: {
    urgentLow: 5,
    urgentLowSoon: 10,
    low: 15,
    high: 60,
    noData: 30,
  },
  unit: "mgdl",
};

export type AlertKind =
  | "urgentLow"
  | "urgentLowSoon"
  | "low"
  | "high"
  | "risingFast"
  | "fallingFast"
  | "noData"
  | "podExpiring"
  | "dexcomLogin";

export interface AlertEvent {
  kind: AlertKind;
  title: string;
  body: string;
  /** critical = bypasses silent/Focus (needs Apple's critical-alert entitlement); otherwise time-sensitive. */
  level: "critical" | "timeSensitive";
  /** A test from the app's Settings: goes to every channel. */
  test?: boolean;
}

export interface AlertState {
  /** Alerts whose condition is currently true, with when they last fired. */
  active: Partial<Record<AlertKind, { since: number; lastFired: number }>>;
  /** Non-urgent alerts are suppressed until this time (ms epoch). */
  snoozeUntil?: number;
}

export type ApnsEnvironment = "sandbox" | "production";

export interface Device {
  id: string;
  name: string;
  environment: ApnsEnvironment;
  /** Regular push token for alert notifications. */
  alertToken?: string;
  /** ActivityKit push-to-start token, lets the server start a fresh Live Activity. */
  pushToStartToken?: string;
  /** The currently running Live Activity on this device. */
  activity?: { token: string; startedAt: number };
  /** The user turned the Live Activity on in the app; the server keeps it running. */
  wantsLiveActivity: boolean;
  /** Last time the server tried push-to-start, to avoid retrying every reading. */
  lastStartAttempt?: number;
  alertsEnabled: boolean;
  updatedAt: number;
}

/** Everything the server persists. */
export interface PersistedState {
  readings: Reading[];
  devices: Device[];
  insulin: InsulinEntry[];
  carbs: CarbEntry[];
  podChanges: PodChange[];
  settings: AlertSettings;
  alertState: AlertState;
  lastPodAlertFor?: string;
}
