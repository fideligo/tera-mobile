# The golden vector

A synthetic paired SCG/PPG capture with a known ground-truth PTT, for checking a signal-chain
implementation against the contract in `docs/decisions.md`.

It exists because there is no hardware data. Neither has the teammate implementing the real chain,
so the alternative to synthetic is nothing — and nothing means an implementation gets validated by
"it compiles and returns plausible numbers", which is exactly the failure the contract's one
prohibition is about.

**What passing this proves:** the implementation agrees with the contract — the fiducial
definition, the units, the pairing rule, the 80–400 ms drop policy, the array bound.

**What it does not prove:** anything about a human chest. Synthetic signals have clean fiducials,
no motion artefact, no perfusion variation, no baseline wander worth the name. A chain that passes
this can still fail completely on the first real capture. Both statements are true at once and
neither cancels the other.

## Files

| File | Contents |
|---|---|
| `golden_capture_accel.csv` | Accelerometer, 7000 rows. Same columns as the debug export (`accelerometerCsv`). |
| `golden_capture_frames.csv` | Camera ROI means, 1050 rows. Same columns as `framesCsv`. |
| `golden_capture_truth.csv` | The answer: `beat_index, ao_timestamp_nanos, foot_timestamp_nanos, ptt_ms`. |

The two capture files use the **exact format the developer CSV export produces**, so a real
exported capture and this fixture are interchangeable inputs to whatever you build.

Regenerate with `dart run tool/make_golden_vector.dart` from `patient/`. Output is byte-identical
on every machine and every run — the noise source is a hand-rolled LCG, not `dart:math`'s
`Random(seed)`, whose sequence is not guaranteed stable across SDK versions.

## Parameters

| | |
|---|---|
| Duration | 35 s |
| Heart rate | 72 bpm, constant |
| Beats | 41 (comfortably above the 30-beat minimum, so the vector is not sitting on the threshold) |
| Accelerometer | 200 Hz — the eligibility *minimum*, deliberately: the harder case |
| Camera | 30 fps, no dropped frames |
| Ground-truth PTT | 220 ms mean, modulated ±20 ms at 0.25 Hz (respiratory), so range is 200–240 ms |
| SCG | AO complex as a 25 Hz cosine burst under an 8 ms Gaussian envelope, on 9.81 m/s² gravity |
| PPG | Baseline 128, pulse amplitude 40, **linear upstroke** over 12% of the beat period |
| Noise | 0.01 m/s² accelerometer, 0.3 counts ROI — deterministic, small enough not to move a fiducial |
| Clock basis | `realtime == uptime` on every row: shared basis, the only case a capture may proceed on |

The upstroke is linear on purpose. Under the intersecting-tangent rule the tangent at maximum first
derivative *is* the ramp line, and it meets the pre-foot baseline exactly at the foot — so the
ground truth is genuinely recoverable rather than approximated, and the tolerance below measures
your implementation instead of the fixture's own construction error.

The PPG pulse is positive-going. Real fingertip PPG is usually inverted (more blood, less
transmitted light); sign is a convention, and the contract only cares that the foot is the onset of
the systolic upstroke.

## Expected output

For a conforming implementation, `process()` on this capture returns:

| Field | Expected |
|---|---|
| `accepted` | `true` |
| `nBeatsTotal` | 41 |
| `nBeatsUsable` | 41 — every interval is inside 80–400 ms, so the drop policy removes none |
| `pttMs.length` | 41, equal to `nBeatsUsable` |
| `pttMs` values | Within **±5 ms** of the corresponding `ptt_ms` in the truth file |
| `quality.accel_rate_hz` | ≈ 200 |
| `quality.camera_fps` | ≈ 30 |
| `quality.dropped_frame_pct` | 0 |
| `rejectionReason` | `null` |

`snr_db` and `motion_index` are **not** checked. They have no agreed formula yet — see the contract
— and inventing an expected value here would be inventing the formula by the back door.

## Tolerances, and where they come from

`golden_vector_test.dart` recovers both fiducials from the samples and checks them against the truth
file, which is what establishes that these bounds are achievable:

| | Tolerance |
|---|---|
| AO peak | ±3 ms — at 200 Hz the sample spacing is 5 ms, so this is essentially peak quantisation |
| PPG foot | ±3 ms — sub-sample, via the tangent intersection; 30 fps alone would only give ±33 ms |
| PTT | **±5 ms** — the figure to hold your implementation to |

The recovery code in that test searches a narrow window around each known answer. **It is not a
reference detector** and must not be copied as one — a real chain has no truth file to search
around. It answers one question: is the truth actually present in these samples. It is.

## If you change the fixture

Regenerate, re-run `golden_vector_test.dart`, and update the parameter and expected-output tables
above in the same commit. A fixture whose README has drifted from its bytes is worse than no
fixture, because it will be believed.
