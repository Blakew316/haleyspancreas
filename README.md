# Haley's Pancreas

A private iPhone companion for Haley's Dexcom G6 and Omnipod 5. It shows her glucose on the
Lock Screen, Dynamic Island (portrait and landscape on iOS 27), StandBy, Apple Watch Smart
Stack and CarPlay, and sends alerts to every phone you connect, including yours.

> **Safety.** This app shows awareness information only. Dexcom Share readings arrive about
> every 5 minutes and usually take another minute or so to reach the cloud. Keep the Dexcom
> app's own alarms on, and use the Dexcom and Omnipod 5 apps for treatment decisions. This app
> never talks to the pod.

## How it works

```
G6 transmitter ─BLE─▶ Dexcom app (Haley's phone) ─▶ Dexcom Share cloud
                                                          │  polled every 10 s while a reading is due
                                                          ▼
                                                   server/ (Node, always on)
                                                          │  Apple Push (APNs)
                              ┌───────────────────────────┼────────────────────────┐
                              ▼                           ▼                        ▼
                     Live Activity update        Alert notification       Push-to-start a new
                     (Lock Screen, Island,       (urgent low, low, high,  Live Activity before
                      Watch, CarPlay)             falling fast, no data)  iOS ends it at 8 hours
```

- **`server/`**: polls Dexcom Share, evaluates alerts, and pushes to the phones. It sleeps
  until just before each 5-minute reading is due, then checks every 10 seconds until the
  reading appears. That keeps the delay it adds to about 10 seconds without hammering Dexcom.
- **`ios/`**: SwiftUI app, plus a widget extension for the Live Activity. You log boluses,
  carbs and pod changes in the app, because Omnipod 5 doesn't share its data. Logged doses
  feed an *estimated* insulin on board. It doesn't include Omnipod 5's automatic insulin.

Alerts:

| Alert | Default | Repeats | Snoozable |
|---|---|---|---|
| Urgent low | ≤ 55 mg/dL | every 5 min | never |
| Urgent low soon | predicted ≤ 55 within 20 min | every 10 min | never |
| Low | ≤ 70 | every 15 min | yes |
| High | ≥ 250 | every 60 min | yes |
| Rising / falling fast | ≥ 3 mg/dL per min | once | yes |
| No data | 20 min without a reading | every 30 min | yes |
| Pod expiring | 1 h before 72 h | once | — |
| Dexcom sign-in failed | — | every 15 min | — |

You can change the thresholds in the app's Settings.

## What you need

- A Mac with **Xcode 26 or later** (Xcode 27 for the iOS 27 SDK), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A paid **Apple Developer Program** membership ($99/year). Push notifications and Live
  Activity push updates don't work with a free Apple ID.
- **Dexcom Share turned on** in Haley's Dexcom G6 app (Menu → Share → set up at least one follower).
- Somewhere to run the server 24/7. The instructions below use [Fly.io](https://fly.io) (a few dollars a month).

## 1. Create the Apple push key

1. developer.apple.com → Certificates, IDs & Profiles → **Identifiers** → register an App ID
   such as `com.yourname.haleyspancreas`. Enable **Push Notifications**. Also register
   `com.yourname.haleyspancreas.widgets`.
2. **Keys** → **+** → enable **Apple Push Notifications service (APNs)** → download
   `AuthKey_XXXXXXXXXX.p8`. You can only download it once. Note the **Key ID**.
3. Your **Team ID** is shown under Membership.

## 2. Deploy the server

Run these from the **main project folder** (the one with `Dockerfile` and `fly.toml` in it, not
`server/`). Fly.io builds the server from the `Dockerfile` on its own computers, so you don't need
Docker installed.

Pick a unique name for the server (replace `yourname`):

```bash
APP=haleys-pancreas-yourname
```

```bash
fly apps create $APP && sed -i '' "s/^app = .*/app = \"$APP\"/" fly.toml
```

```bash
fly volumes create hp_data --size 1 --region iad --yes
```

Make the app secret first and keep it (you'll type it into the app):

```bash
openssl rand -hex 32
```

```bash
fly secrets set \
  APP_SECRET="paste-the-secret-here" \
  DEXCOM_USERNAME="haley's dexcom username" \
  DEXCOM_PASSWORD="haley's dexcom password" \
  APNS_KEY_ID="XXXXXXXXXX" \
  APNS_TEAM_ID="YYYYYYYYYY" \
  APNS_BUNDLE_ID="com.yourname.haleyspancreas" \
  APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
```

```bash
fly deploy --ha=false
```

`--ha=false` keeps it to exactly one machine, so alerts aren't sent twice.

Check it's running: `https://<your-app>.fly.dev/health` returns `{"ok":true}` once Dexcom
Share has been reached. Point a free uptime monitor (e.g. UptimeRobot or healthchecks.io) at
`/health`. Then you'll hear about it if the server itself goes down, because a server that is
down can't send its own alerts.

To run locally instead: in `server/`, `cp .env.example .env`, fill it in, then `npm ci && npm run build && node --env-file=.env dist/index.js`. Or with Docker from the main folder: `docker build -t haleys-pancreas . && docker run --env-file server/.env -p 8080:8080 -v hp_data:/data haleys-pancreas`.

### Alerts without an Apple Developer account: Pushover

If the app isn't signed with your own paid Apple Developer account, the server can't send Apple
push notifications to it. It can still send every glucose alert through
[Pushover](https://pushover.net), a notification app (about $5 once per person after a 30-day trial):

1. Install **Pushover** from the App Store on each iPhone and create an account. Your **User Key**
   is shown on pushover.net after you sign in.
2. On pushover.net, **Create an Application/API Token** (name it "Haley's Pancreas") and copy the token.
3. In the Pushover app: Settings → turn on **Critical Alerts**, so urgent lows sound even on
   silent and in Focus modes.
4. Give the server the token and the user keys (comma-separated, no spaces):
   ```bash
   fly secrets set PUSHOVER_APP_TOKEN='your-app-token' PUSHOVER_USER_KEYS='your-user-key,haleys-user-key'
   ```

Urgent lows use Pushover's emergency priority: they repeat every minute for up to 30 minutes until
someone taps **Acknowledge**. Lows are high priority, and everything else is normal. "Send a test
alert" in the app also goes to Pushover.

## 3. Build the iPhone app

1. In `ios/project.yml`, set `BASE_BUNDLE_ID` to the App ID from step 1 and `DEVELOPMENT_TEAM`
   to your Team ID.
2. Generate the project and open it:
   ```bash
   cd ios && xcodegen generate && open HaleysPancreas.xcodeproj
   ```
3. Plug in the iPhone, choose it as the run destination, and press **Run**. The first time,
   enable Developer Mode on the phone (Settings → Privacy & Security → Developer Mode).
4. In the app, enter the server address (`https://<your-app>.fly.dev`) and the `APP_SECRET`.
   Allow notifications, then turn on **Live Activity**.
5. Repeat on each phone that should get alerts (Haley's and yours).

The app reads which Apple push servers to use (sandbox or production) from its signing profile
and tells the server, so this works the same for Xcode, sideloaded and TestFlight installs.
TestFlight is the easiest way to keep the app installed long term.

### Or: install the prebuilt IPA

Every push to GitHub builds an **unsigned** `HaleysPancreas-unsigned.ipa` on GitHub's Mac
servers (Actions → Build → Artifacts). An iPhone only runs apps signed for it, so the IPA has to
be signed during install by a sideloading tool such as [Sideloadly](https://sideloadly.io)
(Mac or Windows):

1. Install Sideloadly on the MacBook, plug in the iPhone with a cable, and unlock it.
2. Drag `HaleysPancreas-unsigned.ipa` into Sideloadly, enter your Apple ID, and press **Start**.
3. On the iPhone, turn on Settings → Privacy & Security → **Developer Mode** (it restarts). Then
   go to Settings → General → VPN & Device Management and trust your Apple ID.

What works depends on the Apple ID you sign with:

| Signed with | Expires | Push alerts and background Live Activity updates |
|---|---|---|
| Free Apple ID | after 7 days; re-sign weekly | **No.** Apple doesn't allow push notifications with free signing. The Live Activity only updates while the app is open. |
| Paid Apple Developer account | after 1 year | Only if the provisioning profile includes Push Notifications. Building from Xcode (above) or TestFlight is the reliable way to get them. |

Because alerts are the point of this app, use a paid account and install from Xcode or
TestFlight for everyday use. The IPA is handy for a quick look at the app.

### Turning on Apple push (with your own developer account)

Once the app is built and installed from Xcode with your own team (above), give the server your
Apple push key so it can update the Live Activity and send alerts while the app is closed:

1. developer.apple.com → Certificates, IDs & Profiles → **Keys → +** → tick **Apple Push
   Notifications service (APNs)** → Register → **Download** the `AuthKey_XXXXXXXXXX.p8` file.
2. From the main project folder (replace the Key ID, Team ID and file path):
   ```bash
   fly secrets set APNS_KEY_ID='XXXXXXXXXX' APNS_TEAM_ID='YOURTEAMID' APNS_BUNDLE_ID='com.kyler.haleyspancreas' APNS_PRIVATE_KEY="$(cat ~/Downloads/AuthKey_XXXXXXXXXX.p8)"
   ```
   `APNS_BUNDLE_ID` must match `BASE_BUNDLE_ID` in `ios/project.yml`.

If Pushover is also set up, it then only sends urgent lows (it repeats until acknowledged and can
sound through silent mode); Apple push handles everything else, so alerts don't arrive twice.

## 4. Critical alerts (recommended)

Critical alerts play even when the phone is on silent or in a Focus mode. Apple grants them to
health apps on request: <https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/>.
Once approved, uncomment `com.apple.developer.usernotifications.critical-alerts` in
`ios/project.yml`, regenerate, and rebuild. Until then, low alerts arrive as time-sensitive
notifications.

## Notes

- Dexcom Share has no public documentation. If Dexcom changes it, the server raises a "can't
  reach Dexcom Share" warning in the app, and the Live Activity greys out after 11 minutes
  without a new reading.
- Haley's Dexcom password stays on the server as a secret. Phones only hold the app secret.
- The server keeps 24 hours of readings and 7 days of logs in `/data/state.json`.
