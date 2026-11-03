/**
 * Decides when to check Dexcom Share next.
 *
 * The G6 transmitter produces one reading every 5 minutes, and Share only has it once
 * the Dexcom app has uploaded it. Polling slowly adds delay; polling constantly risks
 * Dexcom locking the account. So we sleep until just before the next reading is due,
 * check every few seconds until it shows up, then sleep again.
 */

export const READING_INTERVAL_MS = 5 * 60_000;

export interface PollTiming {
  /** How often to check while a reading is due. */
  fastIntervalMs: number;
  /** Start checking this long before a reading is due (transmitter timing drifts a little). */
  leadMs: number;
  /** Keep checking fast for this long after a reading was due. */
  fastWindowMs: number;
  /** Never sleep longer than this, so clock problems cannot stall polling. */
  maxSleepMs: number;
  /** Used when we have no readings at all. */
  noDataIntervalMs: number;
}

export const DEFAULT_TIMING: PollTiming = {
  fastIntervalMs: 10_000,
  leadMs: 15_000,
  fastWindowMs: 3 * 60_000,
  maxSleepMs: 2 * 60_000,
  noDataIntervalMs: 30_000,
};

export function nextPollDelay(
  now: number,
  latestReadingTime: number | undefined,
  timing: PollTiming = DEFAULT_TIMING,
): number {
  if (latestReadingTime === undefined) return timing.noDataIntervalMs;

  const sinceLatest = now - latestReadingTime;
  const windowStart = READING_INTERVAL_MS - timing.leadMs;

  let delay: number;
  if (sinceLatest < windowStart) {
    // The next reading is not due yet.
    delay = windowStart - sinceLatest;
  } else {
    // Readings stay on the transmitter's 5-minute grid even after missed readings,
    // so work out where we are within the current 5-minute slot.
    const pos = ((sinceLatest % READING_INTERVAL_MS) + READING_INTERVAL_MS) % READING_INTERVAL_MS;
    if (pos >= windowStart || pos <= timing.fastWindowMs) {
      delay = timing.fastIntervalMs;
    } else {
      delay = windowStart - pos;
    }
  }
  return Math.max(1_000, Math.min(delay, timing.maxSleepMs));
}
