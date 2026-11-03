# Signed build

`HaleysPancreas-signed.ipa` is signed (ad hoc, production push) for **one iPhone only**
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
- The Live Activity extension has no provisioning profile of its own. If the install fails with
  a message about `GlucoseWidgets.appex`, the signing service needs to sign the extension too.
