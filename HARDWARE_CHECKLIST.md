# Getting Tera onto a physical phone

For doing this alone, under time pressure, with a phone that has never run this app. Work top to
bottom. Each step says what success looks like, what failure looks like, and what to do about it.

Nothing below has been done on hardware. The build command is verified; everything from step 5 on
is untested by anyone, which is the reason for the checklist.

## Before you leave the desk

**Find the laptop's LAN address.**

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' }
```

On this machine that is **192.168.1.2** on the `Wi-Fi` interface.

There is also a `vEthernet (WSL)` address — **172.21.208.1** here. **Do not use it.** It is a
virtual adapter visible only to the laptop, and a phone can never reach it. It looks exactly as
plausible as the real one. This is the single easiest way to lose twenty minutes.

## 1. Backend up

```bash
cd tera-backend && docker compose up -d
curl http://localhost:8000/health          # {"status":"ok"}
```

**Fails:** containers not running. `docker compose logs api`. The DB must be healthy before the
API starts; on a cold boot give it ten seconds.

## 2. Backend reachable *from the phone*

Not from the laptop — from the phone. Open a browser on the handset and go to:

```
http://192.168.1.2:8000/health
```

**Success:** `{"status":"ok"}` in the phone's browser. Do not proceed until you see this. Every
later failure is indistinguishable from this one, and this one is free to test.

**Fails, spinner then timeout:** almost always one of three things, in order of likelihood.

- **Windows Firewall** is blocking inbound 8000. Allow it, or, quicker under pressure, turn the
  private-network firewall off for the duration of the demo and back on after.
- **Client isolation** on the network. Common on university and conference Wi-Fi, and you cannot
  fix it from either device. **Use a phone hotspot instead** — connect the laptop to the phone's
  hotspot, then re-run the `Get-NetIPAddress` step, because the laptop's address will have
  changed.
- **Wrong address.** See the WSL warning above.

Docker already publishes on `0.0.0.0:8000`, so the container side needs nothing.

## 3. Build the APK

Verified working — this exact command produced a 45.6 MB APK in about four minutes:

```bash
cd tera-mobile/patient
flutter build apk --release \
  --dart-define=TERA_API_URL=http://192.168.1.2:8000 \
  --dart-define=TERA_DEBUG_CAPTURE=false
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.

**Both defines matter.**

- `TERA_API_URL` — substitute the address from step 2. Without it the app falls back to
  `10.0.2.2:8000`, which is the host as seen from an *emulator* and is unreachable from a handset.
  The symptom is a sign-in that fails with a network error and no hint that the URL is wrong.
- `TERA_DEBUG_CAPTURE` — `false` or absent for anything a judge or patient touches. `true`
  compiles in the raw CSV export of the accelerometer and camera series. The flag is compile-time
  so that an unflagged build cannot reach that code at all; passing `true` here would put it in the
  APK you hand over.

**Fails:** if Gradle cannot resolve dependencies, you are offline — the first release build needs
the network even though the app does not.

## 4. Install

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

**Fails, "app not installed" or a Play Protect warning:** the release build is signed with the
**debug keystore** (`android/app/build.gradle.kts` still has the Flutter template's TODO). It
installs fine, but Play Protect may warn. Allow it, or install over USB with `adb`, which does not
prompt. Do not spend time creating a release keystore on the day.

**Fails, INSTALL_FAILED_UPDATE_INCOMPATIBLE:** a debug build of the same package is already there.
`adb uninstall id.tera.tera_patient` first.

## 5. Sign in

Credentials are the seeded demo accounts: `demo.patient@tera.invalid`, password from
`TERA_DEMO_PATIENT_PASSWORD` in `tera-backend/backend/.env`.

**Success:** the home screen, with "Signed in as demo.patient@tera.invalid".

**Fails with a network error:** go back to step 2. It is the URL or the firewall, not the app.

**Fails with invalid credentials:** the demo users live in the `tera_pgdata` Docker volume. If the
volume was recreated, re-run `tera-seed-demo` from `tera-backend/backend` with the venv active.

## 6. Triage

"Start a spot check" now opens the symptom triage screen first.

**Success:** five checkboxes, and "None of these — continue" moves on.

**Worth doing once deliberately:** tick "Chest pain", and confirm you get the emergency screen with
no measurement offered. Then **turn off Wi-Fi and mobile data and do it again** — the instruction
must appear exactly the same, with a footnote saying the record could not be reached. That is
invariant 8's actual claim and it is a strong thing to show a judge.

## 7. Eligibility — the real gate

This is the step most likely to end the demo, and nothing before it tells you whether it will pass.

**Success:** "This phone is a good fit" (at or above 500 Hz) or "This phone can be used" (200–500
Hz, provisional). Both proceed.

**Fails, "This phone cannot be used":**

- *No torch.* Nothing to be done — the method needs the camera light. Different handset.
- *Below 200 Hz.* The accelerometer is measured, not requested, over six seconds. There is no
  override and adding one would be wrong. **Different handset.**

**Fails, "Could not check this phone":** the probe itself failed, which is not the same as failing
it. Close other apps and retry; something else may have had the camera.

**If you have several phones, test this step on all of them before the day.** It is exactly what
`profiler/` was built to answer, and running it costs six seconds per handset.

## 8. Capture

A 60-second recording. Camera permission is requested here, with an explanation first.

**Fails, permission denied:** the plugin requests `CAMERA` at runtime (targetSdk 36 requires it)
and the merged release manifest carries `CAMERA` and `HIGH_SAMPLING_RATE_SENSORS`, both verified
in the built APK. If the dialog never appears, the app was launched without an attached activity —
relaunch it rather than debugging.

## 9. The result — expect a rejection

**The session will be rejected.** `UnimplementedSignalPipeline` rejects every capture with
`signal_processing_unavailable`, by design, because the signal chain does not exist yet and
returning plausible numbers instead would put invented data into a patient's clinical record.

This is a correct outcome, and to an unbriefed judge it looks like a broken app. **You have to
narrate it.** Roughly: the acquisition layer and the whole flow are built; the beat-detection stage
is not; and the system is built to decline rather than to invent, which is why the rejection reason
says "not implemented" rather than "poor signal" — those are deliberately different values.

**Fails to submit at all:** if you get a network error here rather than a rejection, the phone
reached sign-in but not the session endpoint. That is unusual and worth reading the error text.

## 10. See it in the web timeline

```bash
cd tera-web/dashboard && npm run dev
```

Sign in as `demo.clinician@tera.invalid`, open the episode, and the capture you just took is at the
top of the patient timeline as a dashed "Spot check not usable" row.

That completes the chain: phone, capture, submit, visible in the clinician's view.

---

## If eligibility fails and you have no other handset

**Record a cuff reading instead.** Home screen → "Record a cuff reading" → type the numbers →
confirm → save.

This is worth knowing in advance, because it is the one handset-to-backend path that **does not
touch the camera, the accelerometer, or the eligibility gate**. It proves phone → API → database →
web timeline end to end on a handset that cannot pass step 7, and it puts a solid filled row with
real mmHg into the timeline next to the outlined estimates — which is invariant 1's whole argument,
visible in one screen.

It is a weaker demo than a capture. It is a much stronger demo than a phone that got stuck at
step 7.
