> **Old build.** This IPA was signed through KravaSign before the developer account existed.
> Build from Xcode with your own team instead (README section 3); it supports Apple push.

# Signed build

`HaleysPancreas-signed.ipa` is the Liquid Glass redesign (commit 9f7ea1a), signed (ad hoc, production push) for **one iPhone only**
(UDID ending `…0A32401C`), valid until 2027-10-31. It will not install on any other phone.

Install from a Mac with the iPhone plugged in and unlocked:

```bash
xcrun devicectl list devices
```

```bash
xcrun devicectl device install app --device <identifier-from-the-list> release/HaleysPancreas-signed.ipa
```

Notes:
- The signing certificate belongs to another developer account, so the server can't send push
  notifications to this build (the push key has to come from the account that signed it).
  Readings show while the app is open.
- It uses the same app ID, profile and entitlements as the copy already on the phone, so it installs
  as an update: the server connection and settings are kept.
