# Tera device profiler

Answers one question: **can this handset run Tera?** Its output fills the device eligibility
table in the proposal and decides which phones the demo runs on.

It is not the patient app and must not grow into one. All sensor and camera work lives in
[`packages/tera_capture`](../packages/tera_capture); this app is a thin consumer of it.

---

## ⚠ Read this before the measurement session

**The capture paths have never run on real hardware.** The project builds, the Kotlin compiles,
the statistics are unit-tested, and the permissions are verified present in the merged release
manifest — but no Android device was available while this was written, so the camera and sensor
code has never executed.

Budget **thirty minutes with the first handset** before you start collecting results. The things
most likely to need a fix are all in `packages/tera_capture/android/`:

- camera session configuration rejected by a specific vendor's HAL
- `acquireLatestImage` starving the repeating request on a slow device
- torch not staying on for the full 60 s under `TEMPLATE_RECORD`
- `SENSOR_DELAY_FASTEST` being ignored without a foreground service on some OEM skins

If a run fails, the log says which step and why. That is the whole point of the design — nothing
falls back to a plausible number.

**Use the smoke test for that half hour.** About 20 seconds, 5 s per stage, exercises every code
path and prints pass/fail per stage. Its numbers are indicative and cannot reach the results
table — `SmokeReport` is a separate type with no route to a markdown row or the upload.

---

## The check that decides whether the day's data is worth anything

`SENSOR_INFO_TIMESTAMP_SOURCE` is a *declaration*, and `SensorEvent.timestamp` is *documented*
as `elapsedRealtimeNanos`. Neither is universally honoured.

A handset that declares `REALTIME` but timestamps frames in the uptime base looks completely
normal — right frame rate, right jitter, right intervals — and every cross-stream alignment
computed from it is out by however long the device has been asleep since boot. Hours, usually.

So the profiler measures the basis rather than believing it, on both streams, and reports
whether they **share** one. That last figure is the one that decides whether a transit time is
measurable on the handset at all; it has its own column in the markdown table.

Three outcomes need action:

| Result | What it means |
|---|---|
| `NO — different bases` | The handset cannot place SCG and PPG on one timeline without correcting for the deep-sleep offset. Record it; do not quietly use its numbers. |
| `matches NEITHER clock` | Timestamps are in some third base. Investigate before trusting anything from this device. |
| `could not be determined` | The two clocks are within 10 ms of each other — a freshly booted handset. **Leave it unplugged and idle for a few minutes, then re-run.** |

The last one is worth planning around: if you reboot a handset immediately before profiling it,
this check cannot return an answer.

---

## Build and install

```bash
cd profiler
flutter pub get
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk   (~45 MB)

adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Signed with the debug key: the tool is side-loaded onto borrowed handsets and never distributed.
On some handsets you will need to allow installation from unknown sources.

To iterate on a connected device: `flutter run --release`. Use release, not debug — a debug build
adds enough overhead to the per-frame path to change the numbers being measured.

## Running one handset

Tap **Smoke test** first on any handset you have not profiled before — 20 seconds, and it tells
you whether the full run will get anywhere.

The full run takes **about three and a half minutes** and cannot be paused.

1. Launch **Tera Profiler**, grant camera permission when asked.
2. Put the handset flat on a table. Tap **Run profile**.
3. Accelerometer run, 60 s — leave it still.
4. When the log says the camera run is starting, **cover the rear lens completely with a
   fingertip**. The torch comes on. Keep it there.
5. The second camera run starts **immediately**, no cool-down. Keep the fingertip in place. This
   is the run that shows thermal throttling.
6. **Do not lock the screen or switch apps.** Either one stops the camera and fails the run.

Then: **Copy markdown row** (goes straight into the proposal table), **Save JSON to file**, or
both. Files land in `/storage/emulated/0/Android/data/id.tera.tera_profiler/files/`, one per run,
named by handset and timestamp — collect them over USB at the end of the day.

### For consistency across handsets

- Same room, same ambient temperature, handsets not just off a charger.
- Note the starting battery level; the results record it, but a handset at 8% may throttle for
  reasons unrelated to the camera.
- Run each handset **once cold**. A second run on an already-warm device measures something
  different, and mixing the two makes the table meaningless.

## What is measured

| # | Measurement | BUILD_SPEC |
|---|---|---|
| 1 | Accelerometer achieved rate, interval SD, dropped estimate — 60 s, batching disabled | 6.1 |
| 2 | Whether rates above 200 Hz were actually delivered, and whether the permission is held | 6.2 |
| 3 | Hardware level, `MANUAL_SENSOR`, timestamp source, YUV sizes, min frame duration | 6.3 |
| 4 | Sustained fps cold, then warm; dropped %, p99 inter-frame interval | 6.4 |
| 5 | Thermal status and battery before and after every run | 6.5 |
| 6 | Clock offset across three runs, with its spread | 6.6 |
| 7 | Per-frame ROI processing time, mean and p99 | 6.7 |
| + | Clock **basis** of both streams, verified against the declaration, and whether they share one | see above |

Every one is reported as a measured value **or** as `not measured` with a reason. There are no
zeros standing in for failures — `flutter test` asserts that a wholly failed run produces a
markdown row containing no digit at all.

The profiler computes **no verdict**. It measures; the backend grades, using the bands in
`backend/app/config.py`. Changing a threshold does not mean reflashing handsets.

## Optional upload

If a Tera backend is reachable, the results view can `POST /v1/device-profiles` and show the
verdict it returns. It refuses to upload when any field the API requires could not be measured,
and says which — the API cannot record "not measured", and a placeholder would put an invented
number into a clinical record.

## Tests

```bash
cd profiler && flutter test      # 21 tests, no device needed
cd ../packages/tera_capture && flutter analyze
```
