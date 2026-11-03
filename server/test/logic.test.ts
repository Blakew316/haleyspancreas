import crypto from "node:crypto";
import { describe, expect, it } from "vitest";
import { delta, evaluateAlerts, rateOfChange } from "../src/alerts.js";
import { createProviderToken } from "../src/apns.js";
import { parseReadings, parseShareDate, parseTrend } from "../src/dexcom.js";
import { fractionRemaining, insulinOnBoard, podStatus } from "../src/insulin.js";
import { contentState, liveActivityUpdate } from "../src/payloads.js";
import { DEFAULT_TIMING, nextPollDelay } from "../src/schedule.js";
import { DEFAULT_SETTINGS, type AlertState, type Reading, type Trend } from "../src/types.js";

const MIN = 60_000;
const T0 = Date.UTC(2026, 10, 3, 12, 0, 0);

/** Readings every 5 minutes ending at `end`, newest first. */
function series(values: number[], end = T0, trend: Trend = "flat"): Reading[] {
  return values
    .map((mgdl, i) => ({ mgdl, trend, time: end - (values.length - 1 - i) * 5 * MIN }))
    .reverse();
}

describe("Dexcom Share parsing", () => {
  it("parses dates with and without offsets", () => {
    expect(parseShareDate("Date(1691455258000)")).toBe(1691455258000);
    expect(parseShareDate("Date(1691455258000-0400)")).toBe(1691455258000);
    expect(parseShareDate(undefined)).toBeUndefined();
  });

  it("parses string and numeric trends", () => {
    expect(parseTrend("FortyFiveDown")).toBe("fortyFiveDown");
    expect(parseTrend(1)).toBe("doubleUp");
    expect(parseTrend("whatever")).toBe("none");
  });

  it("returns readings newest first and skips bad rows", () => {
    const readings = parseReadings([
      { WT: "Date(1000)", Value: 100, Trend: "Flat" },
      { WT: "Date(3000)", Value: 120, Trend: "SingleUp" },
      { WT: "garbage", Value: 90 },
      { WT: "Date(2000)", Value: 0 },
    ]);
    expect(readings.map((r) => r.time)).toEqual([3000, 1000]);
    expect(readings[0]).toEqual({ mgdl: 120, trend: "singleUp", time: 3000 });
  });
});

describe("poll scheduling", () => {
  it("sleeps until shortly before the next reading", () => {
    // 1 minute after a reading: next due at 5:00, start checking at 4:45.
    expect(nextPollDelay(T0 + 1 * MIN, T0)).toBe(2 * MIN); // capped at maxSleep
    expect(nextPollDelay(T0 + 3 * MIN, T0)).toBe(1.75 * MIN);
  });

  it("checks quickly while a reading is due", () => {
    expect(nextPollDelay(T0 + 4.8 * MIN, T0)).toBe(DEFAULT_TIMING.fastIntervalMs);
    expect(nextPollDelay(T0 + 6 * MIN, T0)).toBe(DEFAULT_TIMING.fastIntervalMs);
  });

  it("goes back to sleep after the fast window when a reading was missed", () => {
    // 8:10 after the last reading: the 10:00 slot starts checking at 9:45.
    expect(nextPollDelay(T0 + 8 * MIN + 10_000, T0)).toBe(95_000);
  });

  it("never sleeps for long even with a bad clock", () => {
    expect(nextPollDelay(T0 - 60 * MIN, T0)).toBe(DEFAULT_TIMING.maxSleepMs);
  });
});

describe("insulin on board", () => {
  it("starts at the full dose and decays to zero", () => {
    expect(fractionRemaining(0)).toBe(1);
    expect(fractionRemaining(360)).toBe(0);
    expect(fractionRemaining(120)).toBeGreaterThan(0.4);
    expect(fractionRemaining(120)).toBeLessThan(0.75);
    // Monotonic.
    let prev = 1;
    for (let t = 5; t <= 360; t += 5) {
      const f = fractionRemaining(t);
      expect(f).toBeLessThanOrEqual(prev + 1e-9);
      prev = f;
    }
  });

  it("sums doses and ignores future ones", () => {
    const entries = [
      { id: "a", units: 2, time: T0 },
      { id: "b", units: 5, time: T0 + 60 * MIN },
    ];
    expect(insulinOnBoard(entries, T0)).toBe(2);
    expect(insulinOnBoard(entries, T0 + 7 * 60 * MIN)).toBe(0);
  });

  it("works out pod expiry from the latest change", () => {
    const pod = podStatus([
      { id: "old", time: T0 - 100 * 60 * MIN },
      { id: "new", time: T0 },
    ]);
    expect(pod?.id).toBe("new");
    expect(pod?.expiresAt).toBe(T0 + 72 * 60 * MIN);
    expect(pod?.graceEndsAt).toBe(T0 + 80 * 60 * MIN);
  });
});

describe("trend maths", () => {
  it("computes delta from the previous reading", () => {
    expect(delta(series([100, 110]))).toBe(10);
    expect(delta([{ mgdl: 100, trend: "flat", time: T0 }, { mgdl: 90, trend: "flat", time: T0 - 20 * MIN }])).toBeUndefined();
  });

  it("computes rate over about 15 minutes", () => {
    expect(rateOfChange(series([120, 105, 90, 75]))).toBeCloseTo(-3);
    expect(rateOfChange(series([100]))).toBeUndefined();
  });
});

describe("alerts", () => {
  const base = { settings: DEFAULT_SETTINGS, patientName: "Haley" };
  const empty: AlertState = { active: {} };

  it("fires urgent low as critical and repeats every 5 minutes", () => {
    const readings = series([60, 54]);
    const first = evaluateAlerts({ ...base, readings, state: empty, now: T0 });
    expect(first.events.map((e) => e.kind)).toContain("urgentLow");
    expect(first.events.find((e) => e.kind === "urgentLow")?.level).toBe("critical");
    expect(first.events.map((e) => e.kind)).not.toContain("low");

    const soon = evaluateAlerts({ ...base, readings, state: first.state, now: T0 + 2 * MIN });
    expect(soon.events).toHaveLength(0);

    const later = evaluateAlerts({ ...base, readings: series([54, 52], T0 + 5 * MIN), state: first.state, now: T0 + 5 * MIN });
    expect(later.events.map((e) => e.kind)).toContain("urgentLow");
  });

  it("predicts urgent low soon from the falling rate", () => {
    const readings = series([110, 100, 90, 80]); // -2 mg/dL/min, 80 -> 40 in 20 min
    const result = evaluateAlerts({ ...base, readings, state: empty, now: T0 });
    expect(result.events.map((e) => e.kind)).toContain("urgentLowSoon");
  });

  it("does not alert on glucose from a stale reading but does alert no data", () => {
    const readings = series([50], T0 - 25 * MIN);
    const result = evaluateAlerts({ ...base, readings, state: empty, now: T0 });
    expect(result.events.map((e) => e.kind)).toEqual(["noData"]);
    expect(result.events[0]?.body).toContain("Last was 50 mg/dL");
  });

  it("snooze silences high but never urgent low", () => {
    const snoozed: AlertState = { active: {}, snoozeUntil: T0 + 30 * MIN };
    const high = evaluateAlerts({ ...base, readings: series([260, 262]), state: snoozed, now: T0 });
    expect(high.events).toHaveLength(0);
    const low = evaluateAlerts({ ...base, readings: series([60, 50]), state: snoozed, now: T0 });
    expect(low.events.map((e) => e.kind)).toContain("urgentLow");
  });

  it("fires a snoozed alert once the snooze ends", () => {
    const snoozed: AlertState = { active: {}, snoozeUntil: T0 + 10 * MIN };
    const during = evaluateAlerts({ ...base, readings: series([260, 262]), state: snoozed, now: T0 });
    const after = evaluateAlerts({
      ...base,
      readings: series([262, 263], T0 + 15 * MIN),
      state: during.state,
      now: T0 + 15 * MIN,
    });
    expect(after.events.map((e) => e.kind)).toContain("high");
  });

  it("re-arms an alert after its condition clears", () => {
    const low1 = evaluateAlerts({ ...base, readings: series([75, 68]), state: empty, now: T0 });
    const ok = evaluateAlerts({ ...base, readings: series([68, 90], T0 + 5 * MIN), state: low1.state, now: T0 + 5 * MIN });
    expect(ok.state.active.low).toBeUndefined();
    const low2 = evaluateAlerts({ ...base, readings: series([90, 69], T0 + 10 * MIN), state: ok.state, now: T0 + 10 * MIN });
    expect(low2.events.map((e) => e.kind)).toContain("low");
  });
});

describe("payloads", () => {
  it("builds a Live Activity update in Unix seconds", () => {
    const readings = series([100, 104, 108]);
    const state = contentState({ readings, settings: DEFAULT_SETTINGS, iob: 1.2, podExpiresAt: T0 + 3_600_000 });
    expect(state).toMatchObject({ mgdl: 108, delta: 4, readingTime: T0 / 1000, history: [100, 104, 108], iob: 1.2 });
    const payload = liveActivityUpdate(state!, T0);
    expect(payload.aps["stale-date"]).toBe(T0 / 1000 + 11 * 60);
    expect(payload.aps.event).toBe("update");
  });
});

describe("APNs provider token", () => {
  it("produces a verifiable ES256 JWT", () => {
    const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    const jwt = createProviderToken({ keyId: "KEY123", teamId: "TEAM123", privateKey: pem }, 1_700_000_000);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h!, "base64url").toString())).toEqual({ alg: "ES256", kid: "KEY123" });
    expect(JSON.parse(Buffer.from(c!, "base64url").toString())).toEqual({ iss: "TEAM123", iat: 1_700_000_000 });
    const ok = crypto.verify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s!, "base64url"));
    expect(ok).toBe(true);
  });
});

import { pushoverParams, pushoverPriority, PushoverNotifier } from "../src/pushover.js";

describe("Pushover", () => {
  const urgent = { kind: "urgentLow" as const, title: "URGENT LOW 50 mg/dL ↓", body: "Haley is at 50 mg/dL. Treat now.", level: "critical" as const };
  const high = { kind: "high" as const, title: "High 260 mg/dL", body: "Haley is at 260 mg/dL.", level: "timeSensitive" as const };

  it("uses emergency priority for urgent lows, repeating until acknowledged", () => {
    const p = pushoverParams(urgent, "user-key", "app-token");
    expect(p.get("priority")).toBe("2");
    expect(p.get("retry")).toBe("60");
    expect(p.get("expire")).toBe("1800");
    expect(p.get("token")).toBe("app-token");
    expect(p.get("user")).toBe("user-key");
    expect(p.get("message")).toContain("Treat now");
  });

  it("uses high priority for lows and normal for highs", () => {
    expect(pushoverPriority({ ...urgent, kind: "low" })).toBe(1);
    expect(pushoverPriority(high)).toBe(0);
    expect(pushoverParams(high, "u", "t").get("retry")).toBeNull();
  });

  it("posts once per user key and survives a failure", async () => {
    const calls: string[] = [];
    const fakeFetch = (async (_url: string, init: { body: URLSearchParams }) => {
      const user = init.body.get("user")!;
      calls.push(user);
      if (user === "bad") throw new Error("network down");
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;
    await new PushoverNotifier({ appToken: "t", userKeys: ["kyler", "bad", "haley"] }, fakeFetch, () => {}).send(urgent);
    expect(calls.sort()).toEqual(["bad", "haley", "kyler"]);
  });
});
