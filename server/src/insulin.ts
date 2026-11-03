import type { InsulinEntry, PodChange } from "./types.js";

/**
 * Insulin on board from manually logged doses, using the exponential insulin action
 * curve that Loop uses for rapid-acting insulin.
 *
 * This is an ESTIMATE from what was logged. Omnipod 5 adjusts insulin automatically
 * and that delivery is not visible to this app, so the real number can be different.
 * The Omnipod 5 app's own IOB is the one to trust for dosing.
 */

export interface InsulinModel {
  /** Total duration of insulin action, minutes. */
  actionDurationMin: number;
  /** Time of peak activity, minutes. */
  peakMin: number;
}

/** Adult rapid-acting (Humalog / Novolog / Admelog), as in Loop. */
export const RAPID_ACTING_ADULT: InsulinModel = { actionDurationMin: 360, peakMin: 75 };

/** Fraction of a dose still active `minutes` after it was given (1 at t=0, 0 at the end). */
export function fractionRemaining(minutes: number, model: InsulinModel = RAPID_ACTING_ADULT): number {
  const td = model.actionDurationMin;
  const tp = model.peakMin;
  if (minutes <= 0) return 1;
  if (minutes >= td) return 0;
  const tau = (tp * (1 - tp / td)) / (1 - (2 * tp) / td);
  const a = (2 * tau) / td;
  const S = 1 / (1 - a + (1 + a) * Math.exp(-td / tau));
  const t = minutes;
  const remaining =
    1 - S * (1 - a) * ((t * t / (tau * td * (1 - a)) - t / tau - 1) * Math.exp(-t / tau) + 1);
  return Math.min(1, Math.max(0, remaining));
}

export function insulinOnBoard(
  entries: InsulinEntry[],
  now: number,
  model: InsulinModel = RAPID_ACTING_ADULT,
): number {
  let total = 0;
  for (const e of entries) {
    if (e.time > now) continue;
    total += e.units * fractionRemaining((now - e.time) / 60_000, model);
  }
  return Math.round(total * 100) / 100;
}

export const POD_LIFETIME_MS = 72 * 3_600_000;
export const POD_GRACE_MS = 8 * 3_600_000;

export interface PodStatus {
  id: string;
  changedAt: number;
  expiresAt: number;
  /** Omnipod pods keep delivering for 8 hours after expiry. */
  graceEndsAt: number;
}

export function podStatus(changes: PodChange[]): PodStatus | undefined {
  const latest = [...changes].sort((a, b) => b.time - a.time)[0];
  if (!latest) return undefined;
  return {
    id: latest.id,
    changedAt: latest.time,
    expiresAt: latest.time + POD_LIFETIME_MS,
    graceEndsAt: latest.time + POD_LIFETIME_MS + POD_GRACE_MS,
  };
}
