import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { createApi } from "../src/api.js";
import type { PushRequest, PushResult, Pusher } from "../src/apns.js";
import { DexcomError } from "../src/dexcom.js";
import { ACTIVITY_RENEW_AFTER_MS, GlucoseMonitor, type GlucoseSource } from "../src/monitor.js";
import { MemoryStore } from "../src/store.js";
import type { Reading } from "../src/types.js";

const MIN = 60_000;
const T0 = Date.UTC(2026, 10, 3, 12, 0, 0);

class FakeSource implements GlucoseSource {
  readings: Reading[] = [];
  error: Error | undefined;
  calls = 0;
  async latestReadings(): Promise<Reading[]> {
    this.calls += 1;
    if (this.error) throw this.error;
    return this.readings;
  }
}

class FakePusher implements Pusher {
  sent: PushRequest[] = [];
  invalid = new Set<string>();
  async send(req: PushRequest): Promise<PushResult> {
    this.sent.push(req);
    const bad = this.invalid.has(req.deviceToken);
    return { status: bad ? 410 : 200, tokenInvalid: bad };
  }
  ofType(type: string, token?: string) {
    return this.sent.filter((s) => s.pushType === type && (!token || s.deviceToken === token));
  }
}

async function setup() {
  let now = T0;
  const source = new FakeSource();
  const pusher = new FakePusher();
  const store = new MemoryStore();
  const monitor = new GlucoseMonitor({ source, pusher, store, patientName: "Haley", now: () => now, log: () => {} });
  await monitor.init();
  return {
    source,
    pusher,
    store,
    monitor,
    setNow: (t: number) => (now = t),
  };
}

function addDevice(monitor: GlucoseMonitor, extra: Partial<Parameters<Parameters<GlucoseMonitor["mutate"]>[0]>[0]["devices"][number]> = {}) {
  return monitor.mutate((s) =>
    s.devices.push({
      id: "phone",
      name: "Phone",
      environment: "sandbox",
      alertToken: "alert-token",
      alertsEnabled: true,
      wantsLiveActivity: true,
      updatedAt: T0,
      ...extra,
    }),
  );
}

describe("GlucoseMonitor", () => {
  it("pushes a Live Activity update only when a new reading arrives", async () => {
    const { source, pusher, monitor, setNow } = await setup();
    await addDevice(monitor, { activity: { token: "la-1", startedAt: T0 } });
    source.readings = [{ mgdl: 120, trend: "flat", time: T0 }];
    setNow(T0 + 30_000);
    await monitor.tick();
    expect(pusher.ofType("liveactivity", "la-1")).toHaveLength(1);

    await monitor.tick();
    expect(pusher.ofType("liveactivity", "la-1")).toHaveLength(1);

    source.readings = [{ mgdl: 118, trend: "flat", time: T0 + 5 * MIN }, ...source.readings];
    setNow(T0 + 5.5 * MIN);
    await monitor.tick();
    const updates = pusher.ofType("liveactivity", "la-1");
    expect(updates).toHaveLength(2);
    expect((updates[1]!.payload as { aps: { "content-state": { mgdl: number; delta: number } } }).aps["content-state"]).toMatchObject({
      mgdl: 118,
      delta: -2,
    });
  });

  it("sends an urgent low alert and expands the Live Activity", async () => {
    const { source, pusher, monitor, setNow } = await setup();
    await addDevice(monitor, { activity: { token: "la-1", startedAt: T0 } });
    source.readings = [{ mgdl: 50, trend: "singleDown", time: T0 }];
    setNow(T0 + 30_000);
    await monitor.tick();
    const alerts = pusher.ofType("alert");
    expect(alerts.some((a) => JSON.stringify(a.payload).includes("URGENT LOW"))).toBe(true);
    const la = pusher.ofType("liveactivity")[0]!.payload as { aps: { alert?: { title: string } } };
    expect(la.aps.alert?.title).toContain("URGENT LOW");
  });

  it("renews a Live Activity before iOS ends it at 8 hours", async () => {
    const { source, pusher, monitor, setNow } = await setup();
    await addDevice(monitor, { activity: { token: "la-old", startedAt: T0 }, pushToStartToken: "start-token" });
    const t = T0 + ACTIVITY_RENEW_AFTER_MS + MIN;
    source.readings = [{ mgdl: 110, trend: "flat", time: t }];
    setNow(t + 30_000);
    await monitor.tick();
    const ends = pusher.ofType("liveactivity", "la-old");
    expect((ends[0]!.payload as { aps: { event: string } }).aps.event).toBe("end");
    const starts = pusher.ofType("liveactivity", "start-token");
    expect((starts[0]!.payload as { aps: { event: string } }).aps.event).toBe("start");
    expect(monitor.snapshot.devices[0]!.activity).toBeUndefined();
  });

  it("forgets a dead token", async () => {
    const { source, pusher, monitor, setNow } = await setup();
    await addDevice(monitor, { activity: { token: "dead", startedAt: T0 }, wantsLiveActivity: false });
    pusher.invalid.add("dead");
    source.readings = [{ mgdl: 110, trend: "flat", time: T0 }];
    setNow(T0 + 30_000);
    await monitor.tick();
    expect(monitor.snapshot.devices[0]!.activity).toBeUndefined();
  });

  it("backs off for 15 minutes on a Dexcom login failure and tells the phones", async () => {
    const { source, pusher, monitor } = await setup();
    await addDevice(monitor);
    source.error = new DexcomError("Password invalid.", "AccountPasswordInvalid", true);
    const delay = await monitor.tick();
    expect(delay).toBe(15 * MIN);
    expect(pusher.ofType("alert").some((a) => JSON.stringify(a.payload).includes("Dexcom Share"))).toBe(true);
  });

  it("retries network errors quickly with backoff", async () => {
    const { source, monitor } = await setup();
    source.error = new Error("ECONNRESET");
    expect(await monitor.tick()).toBe(10_000);
    expect(await monitor.tick()).toBe(20_000);
  });
});

describe("API", () => {
  let close: (() => void) | undefined;
  afterEach(() => close?.());

  async function startApi() {
    const ctx = await setup();
    ctx.source.readings = [{ mgdl: 140, trend: "flat", time: T0 }];
    ctx.setNow(T0 + 30_000);
    await ctx.monitor.tick();
    const server = createApi({ monitor: ctx.monitor, appSecret: "s".repeat(32), now: () => T0 + 30_000 });
    await new Promise<void>((r) => server.listen(0, r));
    close = () => server.close();
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const call = (method: string, path: string, body?: unknown, secret = "s".repeat(32)) =>
      fetch(base + path, {
        method,
        headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    return { ...ctx, call };
  }

  it("rejects a wrong secret", async () => {
    const { call } = await startApi();
    expect((await call("GET", "/status", undefined, "wrong")).status).toBe(401);
  });

  it("registers a device and Live Activity, logs insulin, and reports IOB", async () => {
    const { call, pusher } = await startApi();
    expect((await call("PUT", "/devices/phone-1", { name: "Kyler", environment: "sandbox", alertToken: "abc" })).status).toBe(200);
    expect((await call("PUT", "/devices/phone-1/activity", { token: "la-token" })).status).toBe(200);
    expect(pusher.ofType("liveactivity", "la-token")).toHaveLength(1);

    expect((await call("POST", "/log/insulin", { units: 2 })).status).toBe(200);
    const status = (await (await call("GET", "/status")).json()) as { iob: number; readings: unknown[] };
    expect(status.iob).toBe(2);
    expect(status.readings).toHaveLength(1);
  });

  it("validates input", async () => {
    const { call } = await startApi();
    expect((await call("POST", "/log/insulin", { units: 500 })).status).toBe(400);
    expect((await call("PUT", "/settings", { low: 50, urgentLow: 60 })).status).toBe(400);
  });

  it("health reflects polling", async () => {
    const { call } = await startApi();
    expect((await call("GET", "/health")).status).toBe(200);
  });
});
