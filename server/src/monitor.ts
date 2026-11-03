import { evaluateAlerts } from "./alerts.js";
import type { Pusher, PushRequest } from "./apns.js";
import { DexcomError } from "./dexcom.js";
import { insulinOnBoard, podStatus } from "./insulin.js";
import {
  alertNotification,
  contentState,
  liveActivityEnd,
  liveActivityStart,
  liveActivityUpdate,
  type ContentState,
} from "./payloads.js";
import { DEFAULT_TIMING, nextPollDelay, type PollTiming } from "./schedule.js";
import type { Store } from "./store.js";
import type { AlertEvent, Device, PersistedState, Reading } from "./types.js";

export interface GlucoseSource {
  latestReadings(minutes?: number, maxCount?: number): Promise<Reading[]>;
}

export interface MonitorOptions {
  source: GlucoseSource;
  pusher: Pusher;
  store: Store;
  patientName: string;
  timing?: PollTiming;
  now?: () => number;
  log?: (msg: string) => void;
}

/** Live Activities are ended by iOS after 8 hours; replace ours a little before that. */
export const ACTIVITY_RENEW_AFTER_MS = 7.5 * 3_600_000;
const START_RETRY_MS = 10 * 60_000;
const KEEP_READINGS_MS = 24 * 3_600_000;
const KEEP_LOG_MS = 7 * 24 * 3_600_000;
const AUTH_BACKOFF_MS = 15 * 60_000;
const POD_WARNING_MS = 60 * 60_000;

export class GlucoseMonitor {
  private state!: PersistedState;
  private timer: NodeJS.Timeout | undefined;
  private running = false;
  private consecutiveErrors = 0;
  /** Polling and API changes run one at a time so they never push or save conflicting state. */
  private queue: Promise<unknown> = Promise.resolve();
  private readonly timing: PollTiming;
  private readonly now: () => number;
  private readonly log: (msg: string) => void;

  /** For the /health endpoint and the app's status screen. */
  lastPollAt: number | undefined;
  lastSuccessAt: number | undefined;
  lastError: string | undefined;

  constructor(private readonly opts: MonitorOptions) {
    this.timing = opts.timing ?? DEFAULT_TIMING;
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? ((m) => console.log(m));
  }

  async init(): Promise<void> {
    this.state = await this.opts.store.load();
  }

  get snapshot(): Readonly<PersistedState> {
    return this.state;
  }

  start(): void {
    this.running = true;
    void this.loop();
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
  }

  private async loop(): Promise<void> {
    if (!this.running) return;
    let delay = this.timing.fastIntervalMs;
    try {
      delay = await this.tick();
    } catch (err) {
      // tick() handles its own errors; this is a last-resort guard so polling never stops.
      this.log(`[monitor] unexpected error: ${String(err)}`);
    }
    if (this.running) this.timer = setTimeout(() => void this.loop(), delay);
  }

  private exclusive<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.queue.catch(() => undefined).then(fn);
    this.queue = run;
    return run;
  }

  /** One polling cycle. Returns how long to wait before the next one. */
  tick(): Promise<number> {
    return this.exclusive(() => this.tickInner());
  }

  private async tickInner(): Promise<number> {
    const now = this.now();
    this.lastPollAt = now;
    const previousLatest = this.state.readings[0]?.time;
    let delay: number;

    try {
      // Fetch a full day on the first poll, then only the last few readings.
      const fetched = previousLatest === undefined
        ? await this.opts.source.latestReadings(1440, 288)
        : await this.opts.source.latestReadings(30, 6);
      this.mergeReadings(fetched, now);
      this.lastSuccessAt = now;
      this.lastError = undefined;
      this.consecutiveErrors = 0;
      delay = nextPollDelay(this.now(), this.state.readings[0]?.time, this.timing);
    } catch (err) {
      this.consecutiveErrors += 1;
      this.lastError = err instanceof Error ? err.message : String(err);
      this.log(`[monitor] Dexcom Share error: ${this.lastError}`);
      if (err instanceof DexcomError && err.isAuthFailure) {
        // Retrying a bad password quickly gets the Dexcom account locked.
        await this.sendAlerts([
          {
            kind: "dexcomLogin",
            title: "Can't sign in to Dexcom Share",
            body: `${this.lastError} Check the Dexcom username and password on the server.`,
            level: "timeSensitive",
          },
        ]);
        delay = AUTH_BACKOFF_MS;
      } else {
        delay = Math.min(this.timing.fastIntervalMs * 2 ** (this.consecutiveErrors - 1), 60_000);
      }
    }

    const hasNewReading = this.state.readings[0]?.time !== previousLatest;
    const events = this.evaluate(now);
    await this.pushLiveActivities(hasNewReading || events.length > 0, events);
    await this.sendAlerts(events);
    await this.persist();
    return delay;
  }

  private mergeReadings(fetched: Reading[], now: number): void {
    const byTime = new Map<number, Reading>();
    for (const r of this.state.readings) byTime.set(r.time, r);
    for (const r of fetched) byTime.set(r.time, r);
    this.state.readings = [...byTime.values()]
      .filter((r) => now - r.time <= KEEP_READINGS_MS)
      .sort((a, b) => b.time - a.time);
  }

  private evaluate(now: number): AlertEvent[] {
    const result = evaluateAlerts({
      readings: this.state.readings,
      settings: this.state.settings,
      state: this.state.alertState,
      now,
      patientName: this.opts.patientName,
    });
    this.state.alertState = result.state;
    const events = result.events;

    const pod = podStatus(this.state.podChanges);
    if (pod && now >= pod.expiresAt - POD_WARNING_MS && now < pod.graceEndsAt && this.state.lastPodAlertFor !== pod.id) {
      this.state.lastPodAlertFor = pod.id;
      const minutes = Math.round((pod.expiresAt - now) / 60_000);
      events.push({
        kind: "podExpiring",
        title: "Pod expiring",
        body: minutes > 0 ? `The pod expires in about ${minutes} min.` : "The pod has expired. Change it soon.",
        level: "timeSensitive",
      });
    }
    return events;
  }

  currentContent(): ContentState | undefined {
    const now = this.now();
    return contentState({
      readings: this.state.readings,
      settings: this.state.settings,
      iob: insulinOnBoard(this.state.insulin, now),
      podExpiresAt: podStatus(this.state.podChanges)?.expiresAt,
    });
  }

  /** Sends the latest reading to every running Live Activity, and starts or renews them as needed. */
  async pushLiveActivities(sendUpdates = true, events: AlertEvent[] = []): Promise<void> {
    const content = this.currentContent();
    if (!content) return;
    const now = this.now();
    // Expand the Dynamic Island for the most important alert in this cycle.
    const headline = events.find((e) => e.level === "critical") ?? events[0];

    await Promise.all(
      this.state.devices.map(async (device) => {
        const needsRenewal = device.activity && now - device.activity.startedAt >= ACTIVITY_RENEW_AFTER_MS;
        const canStart =
          device.wantsLiveActivity &&
          device.pushToStartToken &&
          (device.lastStartAttempt === undefined || now - device.lastStartAttempt >= START_RETRY_MS);

        if (device.activity && needsRenewal && canStart) {
          await this.push(device, {
            deviceToken: device.activity.token,
            environment: device.environment,
            pushType: "liveactivity",
            priority: 10,
            payload: liveActivityEnd(now),
          });
          device.activity = undefined;
        }

        if (device.activity) {
          if (sendUpdates) {
            const result = await this.push(device, {
              deviceToken: device.activity.token,
              environment: device.environment,
              pushType: "liveactivity",
              priority: 10,
              payload: liveActivityUpdate(content, now, headline),
            });
            if (result.tokenInvalid) device.activity = undefined;
          }
        } else if (canStart && device.pushToStartToken) {
          // The new activity's token arrives when the app registers it (iOS wakes the app briefly).
          device.lastStartAttempt = now;
          const result = await this.push(device, {
            deviceToken: device.pushToStartToken,
            environment: device.environment,
            pushType: "liveactivity",
            priority: 10,
            payload: liveActivityStart(content, this.opts.patientName, now),
          });
          if (result.tokenInvalid) device.pushToStartToken = undefined;
        }
      }),
    );
  }

  async sendAlerts(events: AlertEvent[]): Promise<void> {
    if (events.length === 0) return;
    for (const e of events) this.log(`[alert] ${e.kind}: ${e.title}`);
    await Promise.all(
      this.state.devices
        .filter((d) => d.alertsEnabled && d.alertToken)
        .flatMap((device) =>
          events.map(async (event) => {
            const result = await this.push(device, {
              deviceToken: device.alertToken!,
              environment: device.environment,
              pushType: "alert",
              priority: 10,
              payload: alertNotification(event),
              // Keep retrying delivery for 10 minutes if the phone is offline.
              expiration: Math.floor(this.now() / 1000) + 600,
            });
            if (result.tokenInvalid) device.alertToken = undefined;
          }),
        ),
    );
  }

  private async push(device: Device, req: PushRequest) {
    const result = await this.opts.pusher.send(req);
    if (result.status !== 200) {
      this.log(`[push] ${req.pushType} to ${device.name} failed: ${result.status} ${result.reason ?? ""}`);
    }
    return result;
  }

  async persist(): Promise<void> {
    const now = this.now();
    this.state.insulin = this.state.insulin.filter((e) => now - e.time <= KEEP_LOG_MS);
    this.state.carbs = this.state.carbs.filter((e) => now - e.time <= KEEP_LOG_MS);
    this.state.podChanges = [...this.state.podChanges].sort((a, b) => b.time - a.time).slice(0, 10);
    try {
      await this.opts.store.save(this.state);
    } catch (err) {
      this.log(`[monitor] could not save state: ${String(err)}`);
    }
  }

  /** Lets the API change state, then pushes the new IOB/pod values to Live Activities. */
  mutate(fn: (state: PersistedState) => void, opts: { refreshActivities?: boolean } = {}): Promise<void> {
    return this.exclusive(async () => {
      fn(this.state);
      if (opts.refreshActivities) await this.pushLiveActivities(true);
      await this.persist();
    });
  }

  /** Sends a test notification to one device, or all of them. */
  testAlert(deviceId?: string): Promise<void> {
    return this.exclusive(async () => {
      const devices = this.state.devices.filter((d) => !deviceId || d.id === deviceId);
      const event: AlertEvent = {
        kind: "low",
        title: "Test alert",
        body: "If you can see this, glucose alerts will reach this phone.",
        level: "critical",
      };
      await Promise.all(
        devices
          .filter((d) => d.alertToken)
          .map((d) =>
            this.push(d, {
              deviceToken: d.alertToken!,
              environment: d.environment,
              pushType: "alert",
              priority: 10,
              payload: alertNotification(event),
            }),
          ),
      );
    });
  }
}
