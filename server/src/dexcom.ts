import type { Reading, Trend } from "./types.js";

/**
 * Client for Dexcom Share, the service the Dexcom Follow app uses.
 *
 * This API is not officially documented. The endpoints and application IDs below are
 * the ones used by long-running open-source projects (pydexcom, Nightscout share2nightscout-bridge).
 * Dexcom can change them at any time, which is why the server raises an alert when it
 * cannot reach Share.
 */

export type DexcomRegion = "us" | "ous" | "jp";

const BASE_URLS: Record<DexcomRegion, string> = {
  us: "https://share2.dexcom.com/ShareWebServices/Services",
  ous: "https://shareous1.dexcom.com/ShareWebServices/Services",
  jp: "https://share.dexcom.jp/ShareWebServices/Services",
};

const APPLICATION_IDS: Record<DexcomRegion, string> = {
  us: "d89443d2-327c-4a6f-89e5-496bbb0317db",
  ous: "d89443d2-327c-4a6f-89e5-496bbb0317db",
  jp: "d8665ade-9673-4e27-9ff6-92db4ce13d13",
};

const NULL_UUID = "00000000-0000-0000-0000-000000000000";

const TREND_BY_NAME: Record<string, Trend> = {
  none: "none",
  doubleup: "doubleUp",
  singleup: "singleUp",
  fortyfiveup: "fortyFiveUp",
  flat: "flat",
  fortyfivedown: "fortyFiveDown",
  singledown: "singleDown",
  doubledown: "doubleDown",
  notcomputable: "notComputable",
  rateoutofrange: "rateOutOfRange",
};

/** Older Share responses use numbers 0-9 for the trend. */
const TREND_BY_NUMBER: Trend[] = [
  "none",
  "doubleUp",
  "singleUp",
  "fortyFiveUp",
  "flat",
  "fortyFiveDown",
  "singleDown",
  "doubleDown",
  "notComputable",
  "rateOutOfRange",
];

export class DexcomError extends Error {
  constructor(
    message: string,
    /** Dexcom error code, e.g. AccountPasswordInvalid, SessionNotValid. */
    readonly code: string | undefined,
    /** True when retrying with the same credentials will not help. */
    readonly isAuthFailure: boolean,
  ) {
    super(message);
    this.name = "DexcomError";
  }
}

export function parseTrend(raw: unknown): Trend {
  if (typeof raw === "number") return TREND_BY_NUMBER[raw] ?? "none";
  if (typeof raw === "string") return TREND_BY_NAME[raw.toLowerCase()] ?? "none";
  return "none";
}

/** Parses Share's "Date(1691455258000)" or "Date(1691455258000-0400)" into ms since epoch. */
export function parseShareDate(raw: unknown): number | undefined {
  if (typeof raw !== "string") return undefined;
  const match = /Date\((\d+)/.exec(raw);
  return match?.[1] ? Number(match[1]) : undefined;
}

export function parseReadings(body: unknown): Reading[] {
  if (!Array.isArray(body)) return [];
  const readings: Reading[] = [];
  for (const item of body) {
    if (typeof item !== "object" || item === null) continue;
    const r = item as Record<string, unknown>;
    const time = parseShareDate(r.WT) ?? parseShareDate(r.ST) ?? parseShareDate(r.DT);
    const mgdl = typeof r.Value === "number" ? r.Value : Number(r.Value);
    if (time === undefined || !Number.isFinite(mgdl) || mgdl <= 0) continue;
    readings.push({ mgdl, trend: parseTrend(r.Trend), time });
  }
  // Newest first.
  return readings.sort((a, b) => b.time - a.time);
}

const AUTH_FAILURE_CODES = new Set([
  "AccountPasswordInvalid",
  "SSO_AuthenticateAccountNotFound",
  "SSO_AuthenticatePasswordInvalid",
  "SSO_AuthenticateMaxAttemptsExceeded",
  "SSO_InternalError",
]);

const SESSION_EXPIRED_CODES = new Set(["SessionIdNotFound", "SessionNotValid"]);

export interface DexcomShareOptions {
  username: string;
  password: string;
  region?: DexcomRegion;
  fetch?: typeof fetch;
  /** Request timeout in ms. */
  timeoutMs?: number;
}

export class DexcomShareClient {
  private sessionId: string | undefined;
  private accountId: string | undefined;
  private readonly base: string;
  private readonly applicationId: string;
  private readonly fetchImpl: typeof fetch;
  private readonly timeoutMs: number;

  constructor(private readonly options: DexcomShareOptions) {
    const region = options.region ?? "us";
    this.base = BASE_URLS[region];
    this.applicationId = APPLICATION_IDS[region];
    this.fetchImpl = options.fetch ?? fetch;
    this.timeoutMs = options.timeoutMs ?? 10_000;
  }

  /** Returns the latest readings, newest first. Logs in (or back in) as needed. */
  async latestReadings(minutes = 180, maxCount = 36): Promise<Reading[]> {
    if (!this.sessionId) await this.login();
    try {
      return await this.readGlucose(minutes, maxCount);
    } catch (err) {
      if (err instanceof DexcomError && err.code && SESSION_EXPIRED_CODES.has(err.code)) {
        this.sessionId = undefined;
        await this.login();
        return await this.readGlucose(minutes, maxCount);
      }
      throw err;
    }
  }

  private async readGlucose(minutes: number, maxCount: number): Promise<Reading[]> {
    const url =
      `${this.base}/Publisher/ReadPublisherLatestGlucoseValues` +
      `?sessionId=${encodeURIComponent(this.sessionId ?? "")}&minutes=${minutes}&maxCount=${maxCount}`;
    const body = await this.post(url, undefined);
    return parseReadings(body);
  }

  private async login(): Promise<void> {
    if (!this.accountId) {
      const accountId = await this.post(`${this.base}/General/AuthenticatePublisherAccount`, {
        accountName: this.options.username,
        password: this.options.password,
        applicationId: this.applicationId,
      });
      if (typeof accountId !== "string" || accountId === NULL_UUID) {
        throw new DexcomError("Dexcom did not return an account ID.", undefined, true);
      }
      this.accountId = accountId;
    }
    const sessionId = await this.post(`${this.base}/General/LoginPublisherAccountById`, {
      accountId: this.accountId,
      password: this.options.password,
      applicationId: this.applicationId,
    });
    if (typeof sessionId !== "string" || sessionId === NULL_UUID) {
      this.accountId = undefined;
      throw new DexcomError("Dexcom did not return a session ID.", undefined, true);
    }
    this.sessionId = sessionId;
  }

  private async post(url: string, json: unknown): Promise<unknown> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res: Response;
    try {
      res = await this.fetchImpl(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "User-Agent": "Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0",
        },
        body: json === undefined ? undefined : JSON.stringify(json),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }
    const text = await res.text();
    let body: unknown;
    try {
      body = text ? JSON.parse(text) : undefined;
    } catch {
      body = text;
    }
    if (!res.ok) {
      const code =
        typeof body === "object" && body !== null && "Code" in body
          ? String((body as { Code: unknown }).Code)
          : undefined;
      const message =
        typeof body === "object" && body !== null && "Message" in body
          ? String((body as { Message: unknown }).Message)
          : `Dexcom Share returned HTTP ${res.status}`;
      throw new DexcomError(message, code, code !== undefined && AUTH_FAILURE_CODES.has(code));
    }
    return body;
  }
}
