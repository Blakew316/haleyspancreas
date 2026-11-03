import type {
  AlertEvent,
  AlertKind,
  AlertSettings,
  AlertState,
  GlucoseUnit,
  Reading,
  Trend,
} from "./types.js";

/** Glucose-based alerts only fire from a reading at most this old. Older data triggers "no data" instead. */
export const FRESH_READING_MS = 12 * 60_000;

/** These cannot be snoozed. */
const UNSNOOZABLE: ReadonlySet<AlertKind> = new Set(["urgentLow", "urgentLowSoon"]);

const CRITICAL: ReadonlySet<AlertKind> = new Set(["urgentLow", "urgentLowSoon", "low"]);

export const TREND_ARROWS: Record<Trend, string> = {
  none: "",
  doubleUp: "⇈",
  singleUp: "↑",
  fortyFiveUp: "↗",
  flat: "→",
  fortyFiveDown: "↘",
  singleDown: "↓",
  doubleDown: "⇊",
  notComputable: "?",
  rateOutOfRange: "?",
};

export function formatGlucose(mgdl: number, unit: GlucoseUnit): string {
  return unit === "mmol" ? `${(mgdl / 18.0182).toFixed(1)} mmol/L` : `${Math.round(mgdl)} mg/dL`;
}

/** Change from the previous reading, if it is from about 5 minutes earlier. */
export function delta(readings: Reading[]): number | undefined {
  const [latest, previous] = readings;
  if (!latest || !previous) return undefined;
  if (latest.time - previous.time > 11 * 60_000) return undefined;
  return latest.mgdl - previous.mgdl;
}

/** mg/dL per minute over roughly the last 15 minutes. Needs at least 2 readings 4+ minutes apart. */
export function rateOfChange(readings: Reading[]): number | undefined {
  const latest = readings[0];
  if (!latest) return undefined;
  let oldest: Reading | undefined;
  for (const r of readings.slice(1)) {
    if (latest.time - r.time > 16 * 60_000) break;
    oldest = r;
  }
  if (!oldest) return undefined;
  const minutes = (latest.time - oldest.time) / 60_000;
  if (minutes < 4) return undefined;
  return (latest.mgdl - oldest.mgdl) / minutes;
}

export interface EvaluateInput {
  /** Newest first. */
  readings: Reading[];
  settings: AlertSettings;
  state: AlertState;
  now: number;
  patientName: string;
}

export interface EvaluateResult {
  events: AlertEvent[];
  state: AlertState;
}

/** Works out which alerts should fire now. Pure: the caller stores the returned state. */
export function evaluateAlerts(input: EvaluateInput): EvaluateResult {
  const { readings, settings, now, patientName } = input;
  const latest = readings[0];
  const fresh = latest !== undefined && now - latest.time <= FRESH_READING_MS;
  const rate = rateOfChange(readings);
  const unit = settings.unit;
  const value = latest ? formatGlucose(latest.mgdl, unit) : "";
  const arrow = latest ? TREND_ARROWS[latest.trend] : "";
  const ageMin = latest ? Math.floor((now - latest.time) / 60_000) : undefined;

  const conditions: Partial<Record<AlertKind, Omit<AlertEvent, "kind" | "level">>> = {};

  if (fresh && latest) {
    const isUrgentLow = latest.mgdl <= settings.urgentLow;
    const isLow = latest.mgdl <= settings.low;

    if (isUrgentLow) {
      conditions.urgentLow = {
        title: `URGENT LOW ${value} ${arrow}`.trim(),
        body: `${patientName} is at ${value}. Treat now.`,
      };
    } else if (isLow) {
      conditions.low = {
        title: `Low ${value} ${arrow}`.trim(),
        body: `${patientName} is at ${value}.`,
      };
    }

    if (!isUrgentLow && settings.urgentLowSoonMinutes > 0 && rate !== undefined && rate < 0) {
      const projected = latest.mgdl + rate * settings.urgentLowSoonMinutes;
      if (projected <= settings.urgentLow) {
        const minutesUntil = Math.max(1, Math.round((settings.urgentLow - latest.mgdl) / rate));
        conditions.urgentLowSoon = {
          title: `Urgent low soon ${value} ${arrow}`.trim(),
          body: `${patientName} is ${value} and falling. Expected urgent low in about ${minutesUntil} min.`,
        };
      }
    }

    if (latest.mgdl >= settings.high) {
      conditions.high = {
        title: `High ${value} ${arrow}`.trim(),
        body: `${patientName} is at ${value}.`,
      };
    }

    if (settings.fastRate > 0) {
      if (latest.trend === "doubleUp" || (rate !== undefined && rate >= settings.fastRate)) {
        conditions.risingFast = {
          title: `Rising fast ${value} ${arrow}`.trim(),
          body: `${patientName} is ${value} and rising quickly.`,
        };
      }
      if (latest.trend === "doubleDown" || (rate !== undefined && rate <= -settings.fastRate)) {
        conditions.fallingFast = {
          title: `Falling fast ${value} ${arrow}`.trim(),
          body: `${patientName} is ${value} and falling quickly.`,
        };
      }
    }
  }

  const noDataMs = settings.noDataMinutes * 60_000;
  if (!latest || now - latest.time >= noDataMs) {
    conditions.noData = {
      title: "No glucose data",
      body: latest
        ? `No new reading for ${ageMin} min. Last was ${value} ${arrow}. Check ${patientName}'s Dexcom app and phone.`.replace(
            /\s+\./,
            ".",
          )
        : `No readings from Dexcom Share. Check ${patientName}'s Dexcom app and phone.`,
    };
  }

  const repeatMs = (kind: AlertKind): number => {
    const minutes = (settings.repeatMinutes as Record<string, number | undefined>)[kind] ?? 0;
    return minutes * 60_000;
  };

  const snoozed = input.state.snoozeUntil !== undefined && now < input.state.snoozeUntil;
  const nextActive: AlertState["active"] = {};
  const events: AlertEvent[] = [];

  for (const [k, content] of Object.entries(conditions) as [AlertKind, (typeof conditions)[AlertKind]][]) {
    if (!content) continue;
    const prior = input.state.active[k];
    const suppressed = snoozed && !UNSNOOZABLE.has(k);
    let fire = false;
    if (!prior) {
      fire = !suppressed;
    } else {
      const every = repeatMs(k);
      fire = !suppressed && every > 0 && now - prior.lastFired >= every;
    }
    nextActive[k] = {
      since: prior?.since ?? now,
      // A suppressed alert counts as "never fired" so it goes off once the snooze ends.
      lastFired: fire ? now : (prior?.lastFired ?? 0),
    };
    if (fire) {
      events.push({ kind: k, ...content, level: CRITICAL.has(k) ? "critical" : "timeSensitive" });
    }
  }

  return {
    events,
    state: {
      active: nextActive,
      snoozeUntil: snoozed ? input.state.snoozeUntil : undefined,
    },
  };
}
