import type { AlertEvent, AlertKind } from "./types.js";

/**
 * Sends glucose alerts through Pushover (pushover.net), a notification app for iPhone.
 *
 * This works without an Apple Developer account: Pushover's own app receives the alert.
 * Urgent lows use Pushover's emergency priority, which repeats every minute until someone
 * acknowledges it and can sound as an iOS critical alert (enable "Critical Alerts" in the
 * Pushover app settings).
 */

export interface PushoverConfig {
  /** API token of the application created at pushover.net/apps/build. */
  appToken: string;
  /** User or group keys to notify (shown on the pushover.net dashboard after signing in). */
  userKeys: string[];
  /**
   * Only send urgent lows (and tests). Used when Apple push works too, so other alerts
   * don't arrive twice while Pushover stays the loudest backup for the alerts that matter most.
   */
  urgentOnly?: boolean;
}

const EMERGENCY: ReadonlySet<AlertKind> = new Set(["urgentLow", "urgentLowSoon"]);

/** Pushover priorities: 2 = emergency (repeats until acknowledged), 1 = high (bypasses quiet hours), 0 = normal. */
export function pushoverPriority(event: AlertEvent): 0 | 1 | 2 {
  if (EMERGENCY.has(event.kind)) return 2;
  if (event.level === "critical") return 1;
  return 0;
}

export function pushoverParams(event: AlertEvent, userKey: string, appToken: string): URLSearchParams {
  const priority = pushoverPriority(event);
  const params = new URLSearchParams({
    token: appToken,
    user: userKey,
    title: event.title,
    message: event.body,
    priority: String(priority),
  });
  if (priority === 2) {
    // Repeat every 60 seconds for up to 30 minutes, until someone taps Acknowledge.
    params.set("retry", "60");
    params.set("expire", "1800");
    params.set("sound", "persistent");
  }
  return params;
}

export class PushoverNotifier {
  private readonly fetchImpl: typeof fetch;

  constructor(
    private readonly config: PushoverConfig,
    fetchImpl?: typeof fetch,
    private readonly log: (msg: string) => void = (m) => console.log(m),
  ) {
    this.fetchImpl = fetchImpl ?? fetch;
  }

  async send(event: AlertEvent): Promise<void> {
    if (this.config.urgentOnly && !event.test && !EMERGENCY.has(event.kind)) return;
    await Promise.all(
      this.config.userKeys.map(async (user) => {
        try {
          const res = await this.fetchImpl("https://api.pushover.net/1/messages.json", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: pushoverParams(event, user, this.config.appToken),
            signal: AbortSignal.timeout(10_000),
          });
          if (!res.ok) this.log(`[pushover] ${event.kind} failed: HTTP ${res.status} ${await res.text()}`);
        } catch (err) {
          this.log(`[pushover] ${event.kind} failed: ${String(err)}`);
        }
      }),
    );
  }
}
