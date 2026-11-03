import fs from "node:fs";
import { createApi } from "./api.js";
import { ApnsClient, LoggingPusher, type Pusher } from "./apns.js";
import { DexcomShareClient, type DexcomRegion } from "./dexcom.js";
import { GlucoseMonitor } from "./monitor.js";
import { DEFAULT_TIMING } from "./schedule.js";
import { FileStore } from "./store.js";

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required environment variable ${name}. See server/.env.example.`);
    process.exit(1);
  }
  return v;
}

function apnsPrivateKey(): string | undefined {
  if (process.env.APNS_PRIVATE_KEY) return process.env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n");
  if (process.env.APNS_KEY_PATH) return fs.readFileSync(process.env.APNS_KEY_PATH, "utf8");
  return undefined;
}

async function main() {
  const appSecret = required("APP_SECRET");
  if (appSecret.length < 24) {
    console.error("APP_SECRET must be at least 24 characters. Generate one with: openssl rand -hex 32");
    process.exit(1);
  }

  const region = (process.env.DEXCOM_REGION ?? "us") as DexcomRegion;
  if (!["us", "ous", "jp"].includes(region)) {
    console.error("DEXCOM_REGION must be us, ous or jp");
    process.exit(1);
  }

  const source = new DexcomShareClient({
    username: required("DEXCOM_USERNAME"),
    password: required("DEXCOM_PASSWORD"),
    region,
  });

  let pusher: Pusher;
  const key = apnsPrivateKey();
  if (key && process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID && process.env.APNS_BUNDLE_ID) {
    pusher = new ApnsClient({
      keyId: process.env.APNS_KEY_ID,
      teamId: process.env.APNS_TEAM_ID,
      privateKey: key,
      bundleId: process.env.APNS_BUNDLE_ID,
    });
  } else {
    console.warn("APNs is not configured, so pushes are only logged. Set APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID and APNS_PRIVATE_KEY.");
    pusher = new LoggingPusher();
  }

  const fastSeconds = Number(process.env.POLL_INTERVAL_SECONDS ?? 10);
  const monitor = new GlucoseMonitor({
    source,
    pusher,
    store: new FileStore(process.env.DATA_DIR ?? "./data"),
    patientName: process.env.PATIENT_NAME ?? "Haley",
    timing: { ...DEFAULT_TIMING, fastIntervalMs: Math.max(5, fastSeconds) * 1000 },
  });
  await monitor.init();
  monitor.start();

  const port = Number(process.env.PORT ?? 8080);
  const server = createApi({ monitor, appSecret });
  server.listen(port, () => console.log(`Listening on :${port}`));

  const shutdown = () => {
    console.log("Shutting down");
    monitor.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5_000).unref();
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
