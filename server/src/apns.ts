import crypto from "node:crypto";
import http2 from "node:http2";
import type { ApnsEnvironment } from "./types.js";

/**
 * Minimal Apple Push Notification service client: token (.p8) auth over HTTP/2,
 * with no third-party dependencies.
 */

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  /** Contents of the AuthKey_XXXX.p8 file. */
  privateKey: string;
  bundleId: string;
}

export type PushType = "alert" | "liveactivity";

export interface PushRequest {
  deviceToken: string;
  environment: ApnsEnvironment;
  pushType: PushType;
  /** 10 = deliver now, 5 = when convenient. */
  priority: 10 | 5;
  payload: unknown;
  /** Unix seconds after which APNs should drop the push. 0 = try once. */
  expiration?: number;
  collapseId?: string;
}

export interface PushResult {
  status: number;
  reason?: string;
  /** The token is dead and should be forgotten. */
  tokenInvalid: boolean;
}

export interface Pusher {
  send(req: PushRequest): Promise<PushResult>;
}

const HOSTS: Record<ApnsEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

const INVALID_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"]);

function base64url(input: Buffer | string): string {
  return Buffer.from(input).toString("base64url");
}

export function createProviderToken(config: Pick<ApnsConfig, "keyId" | "teamId" | "privateKey">, nowSec: number): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: nowSec }));
  const signingInput = `${header}.${claims}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: config.privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

export class ApnsClient implements Pusher {
  private token: { value: string; issuedAt: number } | undefined;
  private readonly sessions = new Map<ApnsEnvironment, http2.ClientHttp2Session>();

  constructor(private readonly config: ApnsConfig) {}

  private providerToken(): string {
    const nowSec = Math.floor(Date.now() / 1000);
    // Apple rejects tokens older than an hour and throttles refreshing more than every 20 minutes.
    if (!this.token || nowSec - this.token.issuedAt > 45 * 60) {
      this.token = { value: createProviderToken(this.config, nowSec), issuedAt: nowSec };
    }
    return this.token.value;
  }

  private session(env: ApnsEnvironment): http2.ClientHttp2Session {
    const existing = this.sessions.get(env);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = http2.connect(HOSTS[env]);
    const forget = () => {
      if (this.sessions.get(env) === session) this.sessions.delete(env);
    };
    session.on("error", forget);
    session.on("close", forget);
    session.on("goaway", forget);
    session.setTimeout(60 * 60_000, () => session.close());
    this.sessions.set(env, session);
    return session;
  }

  send(req: PushRequest): Promise<PushResult> {
    const topic = req.pushType === "liveactivity" ? `${this.config.bundleId}.push-type.liveactivity` : this.config.bundleId;
    const headers: http2.OutgoingHttpHeaders = {
      ":method": "POST",
      ":path": `/3/device/${req.deviceToken}`,
      authorization: `bearer ${this.providerToken()}`,
      "apns-topic": topic,
      "apns-push-type": req.pushType,
      "apns-priority": String(req.priority),
      "content-type": "application/json",
    };
    if (req.expiration !== undefined) headers["apns-expiration"] = String(req.expiration);
    if (req.collapseId) headers["apns-collapse-id"] = req.collapseId;

    return new Promise((resolve) => {
      let settled = false;
      const done = (result: PushResult) => {
        if (!settled) {
          settled = true;
          resolve(result);
        }
      };
      let stream: http2.ClientHttp2Stream;
      try {
        stream = this.session(req.environment).request(headers);
      } catch (err) {
        done({ status: 0, reason: String(err), tokenInvalid: false });
        return;
      }
      let status = 0;
      let body = "";
      stream.setTimeout(10_000, () => {
        stream.close(http2.constants.NGHTTP2_CANCEL);
        done({ status: 0, reason: "timeout", tokenInvalid: false });
      });
      stream.on("response", (h) => {
        status = Number(h[":status"] ?? 0);
      });
      stream.setEncoding("utf8");
      stream.on("data", (chunk: string) => {
        body += chunk;
      });
      stream.on("end", () => {
        let reason: string | undefined;
        try {
          reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined;
        } catch {
          reason = body || undefined;
        }
        done({
          status,
          reason,
          tokenInvalid: status === 410 || (reason !== undefined && INVALID_TOKEN_REASONS.has(reason)),
        });
      });
      stream.on("error", (err) => done({ status: 0, reason: String(err), tokenInvalid: false }));
      stream.end(JSON.stringify(req.payload));
    });
  }

  close(): void {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}

/** Used when APNs is not configured, so the server still runs (e.g. while testing the API). */
export class LoggingPusher implements Pusher {
  async send(req: PushRequest): Promise<PushResult> {
    console.log(`[push:dry-run] ${req.pushType} -> ${req.deviceToken.slice(0, 8)}…`, JSON.stringify(req.payload));
    return { status: 200, tokenInvalid: false };
  }
}
