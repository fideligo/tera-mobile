# Tera — mobile

Part of **Tera**, a hybrid, cuff-referenced home blood-pressure *monitoring* system. This
repository holds the device capability profiler and the acquisition layer it is built on.

| Repository | Contents |
|---|---|
| [tera-backend](https://github.com/fideligo/tera-backend) | FastAPI + SQLAlchemy 2 + Alembic + PostgreSQL |
| **tera-mobile** (this one) | Device profiler and the `tera_capture` acquisition layer |
| [tera-web](https://github.com/fideligo/tera-web) | Clinician and patient views (Next.js) |

```
profiler/              Flutter app — answers "can this handset run Tera?"
packages/tera_capture/ Acquisition layer: Dart + Kotlin, no UI dependency
```

Android only, minSdk 26.

---

## ⚠ The capture paths have never run on real hardware

The project builds, the Kotlin compiles, the statistics are unit-tested and the permissions are
verified present in the merged release manifest — but no Android device was available while this
was written, so **the camera and sensor code has never executed**.

Budget thirty minutes with the first handset. The likely failure points are all in
`packages/tera_capture/android/`: camera session configuration rejected by a vendor HAL,
`acquireLatestImage` starving the repeating request, torch not holding for the full 60 s, or
`SENSOR_DELAY_FASTEST` being ignored by an OEM skin.

See [`profiler/README.md`](profiler/README.md) for the measurement-session runbook.

## `packages/tera_capture` — the acquisition layer, shipped first

The profiler is its first consumer. **The patient capture app will be its second.** It has no
dependency on any UI and must not gain one.

What it deliberately does **not** do — the boundary the patient app will build on:

- **Buffer retention.** Samples are streamed and dropped; nothing is written to disk.
- **Filtering.** No band-pass, no detrending, no smoothing.
- **Event detection.** No aortic-valve-opening or pulse-foot detection.
- **Beat pairing.** No SCG-to-PPG association, so **the package cannot produce a PTT value.**
- **Quality gate.** No decision about whether a capture is usable.

If any of those five appears in the package, the boundary has moved. See
[`docs/decisions.md`](docs/decisions.md).

Invariant 2 — no raw waveform leaves the handset — is structural here rather than a rule:
`CameraCaptureController.consumeFrame` reduces a frame to one `Double` and closes the `Image` in
a `finally` before returning. No frame ever reaches Dart.

## Build and run

```bash
cd profiler
flutter pub get
flutter test                    # 21 tests, no device needed
flutter build apk --release     # build/app/outputs/flutter-apk/app-release.apk (~45 MB)
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Use **release**, not debug — a debug build adds enough overhead to the per-frame path to change
the numbers being measured.

## What the profiler measures

Accelerometer achieved rate and jitter; whether rates above 200 Hz are actually delivered;
camera hardware level, `MANUAL_SENSOR`, timestamp source, YUV sizes and minimum frame duration;
sustained frame rate cold then warm with no cool-down; thermal and battery before and after each
run; clock offset across three runs; and per-frame region-of-interest processing time.

Every value is reported as a measured value **or** as `not measured` with a reason. A test
asserts that a wholly failed run produces a markdown table row containing no digit at all.

It also **verifies the clock basis** rather than trusting `SENSOR_INFO_TIMESTAMP_SOURCE`. A
handset that declares `REALTIME` but timestamps in the uptime base looks normal on every other
measure and would silently invalidate every cross-stream figure collected from it.

The profiler computes **no verdict** — it measures; the backend grades, using the bands in
`app/config.py` over in [tera-backend](https://github.com/fideligo/tera-backend).

Two practical notes for a measurement session: run the **smoke test** (20 s) first on any
handset you have not profiled before, and **do not reboot a handset immediately before
profiling it** — the two clocks will still be within 10 ms of each other and the basis check
cannot return an answer.
