# Decisions

One entry per non-obvious choice, per deviation from `BUILD_SPEC.md`, and per dependency.
Newest section last. Phase 1 only so far.

---

## Deviations from BUILD_SPEC.md

Each of these adds to or departs from the spec. Where a deviation resolves a conflict between the
spec text and a section-2 invariant, the invariant won and the reasoning is spelled out.

### D1. `app_user` table and `monitoring_episode.reviewing_clinician_id`

**Spec position.** §4.1 lists no user entity and no reviewing-clinician column. §4.5 requires
"role claims `patient`, `clinician`, `admin`" and "clinician access scoped to episodes where they
are the reviewing professional".

**Problem.** The scoping requirement is not implementable without somewhere to hold a clinician
identity and a link from an episode to the clinician reviewing it.

**Decision.** Added `app_user` (subject, password hash, role, clinic, optional patient link) and
`monitoring_episode.reviewing_clinician_id`. A `CHECK` keeps the patient link and the role
consistent: a `patient` principal must name a patient, a clinician or admin must not.

### D2. `calibration.established_at` and `calibration.superseded_at`

**Spec position.** §4.1 gives `calibration` a status and a `superseded_by` self-FK, but no
timestamps.

**Problem.** Invariant 4 requires that "every estimate references the calibration in force **at
capture time**", and §4.7 names `test_estimate_references_calibration_in_force_at_capture_time`.
Without temporal columns the only resolvable question is "which calibration is active *now*",
which gives the wrong answer whenever a recalibration lands between capture and upload — the
session would be interpreted against a baseline that did not exist when it was recorded.

**Decision.** Added both columns. Resolution is
`established_at <= session.started_at AND (superseded_at IS NULL OR superseded_at > started_at)`,
most recent first. `CHECK` constraints keep `status`, `superseded_by_id` and `superseded_at`
mutually consistent.

### D3. `calibration_source_session` join table

**Spec position.** §4.1 records only `n_sessions` on `calibration`.

**Problem.** `n_sessions >= 3` is required as a database `CHECK`, and §4.4 is explicit that the
backend does not trust the client. With no record of *which* sessions formed the baseline, the
server would have to accept a client-supplied count and a client-supplied
`baseline_mean_ms`/`baseline_sd_ms`. A handset that can write its own baseline can make any later
session read as stable.

**Decision.** The calibration request names session ids; the server loads them, reduces each to
its trimmed-mean PTT, computes the baseline itself, and records the contributing sessions with
the PTT each contributed. `POST /v1/calibrations` has no field for a baseline value, and unknown
fields are rejected.

### D4. `synthetic BOOLEAN NOT NULL DEFAULT false` on every clinical table

**Spec position.** §4.1's column lists do not mention it; §4.6 and invariant 9 require that
"every seeded row must carry `synthetic: true` and the API must surface that flag".

**Decision.** A column on every entity table plus `synthetic` and `synthetic_notice` on every
response that carries a stored row. Real data is the default; being synthetic takes a deliberate
act. `synthetic_notice` is populated only when the flag is true, so it never becomes background
noise a reader learns to skip.

### D5. `POST /v1/auth/token` and `POST /v1/auth/refresh`

**Spec position.** §4.2's endpoint table has no auth endpoint; §4.5 mandates "OAuth2 with
short-lived JWT access tokens plus refresh".

**Decision.** Added both. OAuth2 password grant, 15-minute access tokens, 14-day refresh tokens.
The `typ` claim is checked on decode, so a refresh token presented as an access token is refused —
otherwise the long-lived token would work everywhere and the short access TTL would be decorative.

### D6. `session_nonce` table

**Spec position.** Not in §4.1. §4.2/§4.5 require single-use nonces with a TTL; §4 rules out Redis
without justification.

**Decision.** Nonces live in Postgres. Single-use has to hold across every API process, and an
in-memory store would allow the same nonce to be spent once per worker. The row is locked
`FOR UPDATE` before the used-check so two concurrent submissions cannot both pass. Not a clinical
row, so `used_at` is written on consumption and expired rows can be purged.

### D7. `trend_estimate.deviation_state`

**Spec position.** §4.1 lists direction, magnitude, confidence and `computed_at`.

**Problem.** §4.3 distinguishes `possible_deviation` from `persistent`, and only the latter
requests a cuff. Persistence depends on whether a *repeat within the window* also deviated, which
is a fact about the moment of ingest. Recomputing it on read would give different answers as
later sessions arrive.

**Decision.** Persist it. A `CHECK` ties it to `direction`, so "stable but persistent" cannot be
constructed.

### D8. `protocol_params.persistence_window_hours`

**Spec position.** §4.1 lists cuff schedule, deviation multiplier `k` and minimum beat count.
§4.3 requires "a repeat session within the configured window" but never names the setting.

**Decision.** Added the key, default 48 hours, documented in `app/config.py`. Chosen so a patient
measuring once or twice daily can realistically produce the repeat, without the pair spanning so
much time that the two sessions describe different physiological states. Invariant 10 forbids
leaving it as a literal.

### D9. `cuff_reading.source = 'photograph'` is rejected by the API

**Spec position.** §4.1 defines the enum as `(manual_entry, photograph)` with an `ocr_confidence`
column. §8 puts seven-segment OCR out of scope: "manual entry only for now".

**Decision.** The value and the column exist in the schema for completeness, and the route returns
422 for both. Accepting `photograph` would imply a capability that does not exist and would
persist rows whose `ocr_confidence` is unpopulated — invariant 9 in a small way.

### D10. Rejection reason enum

**Spec position.** §4.1 has a `rejection_reason` column; no values are enumerated anywhere.

**Decision.** Eleven values covering the device-side quality gate, the server-side plausibility
gate, the red-flag path and the no-calibration case. Every value describes a *system* condition.
None describes the patient, because a rejected session says nothing about them (invariant 6).

### D11. `cuff_reading.corrects_id`

**Spec position.** Not in §4.1's column list. Invariant 5 says "corrections are new rows
referencing the original".

**Decision.** A self-FK, so the reference is real rather than implied. Both rows stay on the
timeline; nothing is replaced.

### D12. `409` on a duplicate session id returns the stored body

§4.2 says "409 duplicate session_id — return the stored result unchanged". That is unusual — an
idempotent endpoint more commonly replays `200`/`201`. The spec is explicit, so it is implemented
exactly as written: status 409, body identical to the original response. Noted in `docs/api.md`
so a client author is not surprised.

The response is **rebuilt from the stored rows**, not replayed from a cached body, so a replay
cannot diverge from what is actually on the record.

### D13. Idempotency is checked before the nonce is spent

§4.2 gives no ordering. Checking the nonce first would mean a client retrying after a dropped
response gets 428 for a nonce it already spent successfully, making a lost response
unrecoverable. Idempotency first; the retry gets its stored result.

### D14. `Idempotency-Key` must equal `session_id`

§4.2 shows `Idempotency-Key: <session_id>` but does not say it is enforced. It is: a mismatch is
400. Otherwise a client could deduplicate two different captures under one key, or submit one
capture twice under two keys.

---

## Conflicts resolved in favour of an invariant

Section 2 says an invariant wins a conflict with the rest of the spec. Two arose.

### C1. The achieved-rate check applies to completed sessions only

**The conflict.** §4.4 lists "achieved rates below the device profile's qualified band" as a 422,
without qualifying it by status. But a session rejected for `sensor_rate_below_qualified` reports
low rates *precisely because that is why it failed*. Applying the check to it would return 422 and
**discard** the session.

**Resolution.** Invariant 3 — "rejected sessions are retained, never discarded" — wins. The rate
check gates completed sessions only. Every structural check (array length bound, PTT plausibility,
beat accounting, quality-field presence) still applies to every payload, because invariant 2 does
not bend for a rejected session.

Covered by `test_rejected_session_with_low_rates_is_still_stored`.

### C2. Supersession writes to the old calibration row

**The conflict.** Invariant 4 says recalibration "never mutates history", and invariant 5 makes
clinical records append-only — yet the same invariant 4 specifies `status active/superseded` and a
`superseded_by` self-FK, which can only be set by updating the old row.

**Resolution.** Read as: the *baseline* is immutable; the supersession bookkeeping is not. A
PL/pgSQL trigger (`tera_calibration_history_guard`) permits `status`, `superseded_by_id` and
`superseded_at` to change and rejects any change to `patient_id`, `device_profile_id`,
`reference_cuff_reading_id`, `baseline_mean_ms`, `baseline_sd_ms`, `n_sessions`, `established_at`
or `synthetic`. It also blocks `DELETE` and makes supersession one-way: a superseded calibration
cannot be reactivated, because that would let an estimate be reinterpreted against a baseline that
had already been retired.

Covered by `test_recalibration_supersedes_and_does_not_mutate`,
`test_calibration_baseline_cannot_be_mutated_at_database_level` and `test_supersession_is_one_way`.

---

## Design decisions

### Append-only enforced by database triggers, not by the absence of routes

Invariant 5 is easy to satisfy superficially — just do not write a `DELETE` route. But a
migration, a console session or a future developer's convenience helper can all issue an `UPDATE`.
`tera_append_only_guard` is attached to every clinical table and raises on `UPDATE` or `DELETE`.
`test_clinical_tables_reject_update_and_delete` is parametrised over the table list, so a table
added without a trigger fails there.

The seeder's `--reset` uses `TRUNCATE`, which is not a row-level operation and so is not caught by
the triggers. That is why `--reset` is a development-only CLI flag and is not exposed over HTTP.

### The `superseded_by_id` foreign key is `DEFERRABLE INITIALLY DEFERRED`

The partial unique index allows one active calibration per patient per device and is checked per
statement. So the old row must be marked superseded *before* the new row is inserted, which means
it briefly points at an id that does not yet exist. Deferring the FK check to commit is the only
way to satisfy both constraints. Found by the seeder failing on the recalibration step.

### The `ptt_ms` ceiling lives in a migration as well as in config

`PlausibilitySettings.max_ptt_array_length` (default 300) is what the API enforces and can be
lowered freely. `ck_session_ptt_array_length_bounded` fixes a structural ceiling of 300 in the
database. Raising the config above it requires a migration — deliberately, because widening the
channel invariant 2 exists to protect should not be an environment-variable change.
`test_ptt_array_db_ceiling_matches_config` fails if the two drift.

### One interval per usable beat, enforced

`len(ptt_ms) == n_beats_usable` is a hard check. A mismatch means the array and the counts describe
different things and there is no safe way to guess which is right.

### The quality term in the confidence heuristic takes the worst limb, not the average

Averaging SNR, motion and dropped-frame scores would let a good SNR hide a capture ruined by
movement. `min()` is the escalation-biased choice (invariant 7). The whole formula is capped
strictly below 1.0 so no response can be read as certainty, and it is labelled a heuristic in the
response itself (`confidence_notice`).

### Persistence requires the same direction

§4.3 says persistent means "a repeat session within the configured window also deviates". A
session reading high followed by one reading low is instability, not a trend, and requesting a
cuff on that pairing would train the patient to ignore the request. Covered by
`test_opposite_direction_repeat_is_not_persistent`.

### A zero-variance baseline is refused

Three or more calibration sessions with identical session PTT means the device is not resolving
real variation. A baseline with zero spread would make every later session read as an infinite
deviation. Invariant 7: escalate rather than record a reference that cannot mean anything.

### All user-facing copy lives in `app/services/language.py`

Invariant 6 is about what the system *says*. Keeping every badge, action message, interpretation
and rejection explanation in one module means `test_no_diagnostic_or_medication_advice_language`
can enumerate all of them against a deny-list, rather than hoping a reviewer notices a sentence
added inline in a route later. The deny-list catches the obvious failures; the real protection is
that the copy is in one reviewable place.

### Logs are scrubbed by a formatter, not by convention

`RedactingJsonFormatter` matches field names against a deny-list, including as substrings, and
redacts recursively through nested structures. A developer who writes
`extra={"systolic_mmhg": 148}` gets `[redacted]`, not a leak. §4.5's rule is enforced rather than
documented.

### Cross-tenant access returns 404, not 403

A patient probing another patient's episode id, or a clinician who is not the reviewer, gets 404.
403 would confirm the id names a real episode — a small but free disclosure about someone else.

### Timeline record types are pairwise disjoint

§4.2 requires estimates and cuff readings to be "distinct types with distinct field sets". The
badges are named differently too (`cuff_badge` vs `estimate_badge`) so neither can be substituted
for the other. Three field sets are shared deliberately and are documented in
`app/schemas/timeline.py`: structural fields every timeline item has, `session_id` on the two
session-derived types, and the common shape of the three event types.

### The clinician summary is appended on every generation

Rather than updating a single row's `viewed_at`. Each `GET .../summary` inserts a
`clinician_summary` row with the rendered contents, and `viewed_at` is set only when a clinician is
the caller. The result is a record of what was actually on screen and when, which is both
append-only and more useful than the latest rendering alone. `delivered_at` stays null —
notification delivery is out of scope (§8).

### `received_at` is settable by the seeder and by nothing else

`ingest.submit()` takes an optional `received_at` so a demonstration episode has upload times
matching its capture times. The HTTP route never passes it: a client must not be able to backdate
when the server received something.

### seed-demo goes through the real ingest path

`app/cli/seed_demo.py` calls `ingest.submit()` for every session, so the seeded episode exercises
the same plausibility gate, calibration resolution and deviation engine as a real device. A seeder
that wrote `trend_estimate` rows directly would prove nothing about the system.

The PTT model is documented in the module: a baseline around 250 ms, a stable stretch, one
engineered deviation → repeat → cuff-confirmation sequence, a settled lower level afterwards, and
a recalibration that re-anchors to it. Every number is illustrative and every row is
`synthetic=true`. They are not measurements and must not be cited as evidence of anything.

### `replay` uses only public endpoints

Token, nonce, submit — the same three calls a handset makes, with `X-Session-Nonce` and
`Idempotency-Key`. It resolves `episode_id` and `device_profile_id` through `GET /v1/episodes`,
the timeline and `GET /v1/sessions/{id}` when they are not supplied, and refuses to guess when
more than one episode is visible. Keys beginning with `_` are stripped from the sample files
before posting, because the API forbids unknown fields and the samples carry inline notes.

---

### The seeded rejection rate is conservative on purpose

`DEFAULT_REJECTION_RATE = 0.32`, configurable with `tera-seed-demo --rejection-rate`.

The MVP's ~80% usable target is stated for **controlled seated conditions**. The seeded episode
is not that: it is a 52-year-old self-administering at home, unsupervised, holding a phone
against their sternum with one hand and a fingertip on the lens with the other, twice a day for
four weeks. Carrying the controlled-conditions figure into that setting would be assuming away
the hardest part of the problem, and a demo showing near-perfect acquisition invites exactly the
question we cannot answer.

Reasons are weighted toward the two failure modes that dominate unsupervised capture — the
patient moving (`excessive_motion`, `posture_unstable`) and sensor/lens contact being wrong
(`poor_signal_quality`, `insufficient_beats`) — which together account for ~70% of rejections.

Two consequences worth stating plainly:

- **The rate is engineered, not emergent.** Failures are drawn per attempt as retries clustered
  around a scheduled slot, which is realistic, but the draw is stochastic and on the fixed seed
  lands around 23%. A demo whose headline yield moves with the random seed is not one to stand
  behind, so `_top_up_rejections` makes the shortfall up deterministically and the CLI reports
  both the target and the achieved figure.
- **The reason distribution is therefore not purely `REJECTION_WEIGHTS`.** The top-up also
  guarantees every reason appears at least once, because the clinician summary's per-reason
  breakdown needs something to break down.

None of it is a measured acquisition yield. No acquisition study has been run, and the CLI says
so on the way out (invariant 9).

---

## Bugs found while building

### `fileConfig` in `alembic/env.py` was disabling every application logger

`logging.config.fileConfig` defaults to `disable_existing_loggers=True`. Every `app.*` logger is
created at module import time by `get_logger(__name__)`, so running a migration in the same
process as the API silenced application logging completely. Found by
`test_logs_contain_no_clinical_values` capturing nothing at all. Fixed with
`disable_existing_loggers=False`.

### `logging.LoggerAdapter` was discarding all structured context

`LoggerAdapter.process()` overwrites `kwargs["extra"]` with the adapter's own dict, so every
`extra={...}` passed by a call site was dropped and the "structured logs" contained only a
message. `get_logger` now returns a plain `Logger`.

### Postgres puts the whole failing row in the exception message, before the `[SQL:` marker

The scrubber originally truncated an exception message at SQLAlchemy's `[SQL:` / `[parameters:`
markers. But Postgres prepends its own line first:

```
new row for relation "cuff_reading" violates check constraint "ck_cuff_systolic_above_diastolic"
DETAIL:  Failing row contains (bd2cfbf5-…, 113, 187, 133, manual_entry, …).
[SQL: INSERT INTO cuff_reading (…) VALUES (…)]
[parameters: {'sys': 113, 'dia': 187, 'pulse': 133}]
```

`DETAIL:` carries every column of the offending row as positional values and comes *first*, so
truncating at `[SQL:` left the entire clinical record in place. Found by
`test_database_integrity_error_does_not_leak_bound_parameters`, which provokes a genuine CHECK
violation rather than simulating one — and asserts the raw driver message *does* contain the
values before asserting the scrubbed one does not, so the test fails loudly if the leak vector
ever disappears and the scrubber becomes dead code.

`DETAIL:`, `HINT:` and `CONTEXT:` are now truncation markers alongside the SQLAlchemy ones. The
useful part — the name of the constraint that failed — precedes all of them and survives.

### `CLINICAL_TABLES` and the migration's trigger list had drifted apart

`calibration_source_session` had an append-only trigger in the migration but was missing from
`app.models.CLINICAL_TABLES`, so nothing tested it.
`test_clinical_tables_match_the_migrations_trigger_list` now loads the migration module and
compares the two lists directly.

### The parametrised append-only test was passing vacuously

`test_clinical_tables_reject_update_and_delete` asserted only that a trigger existed in
`pg_trigger`. Row-level `BEFORE UPDATE OR DELETE` triggers do not fire against an empty table,
and the tables were empty. It now runs on a fixture that populates every clinical table, issues
a real `UPDATE` and a real `DELETE` against each, asserts both raise, and asserts the row
count is unchanged — plus a guard that fails if any table is empty when the test runs, so it
cannot silently return to proving nothing.

---

## Deliberate limitations

### Rate limiting is per-process

`FixedWindowRateLimiter` holds counters in process memory, so with N API workers the effective
ceiling is N times the configured one. Acceptable for a single-instance demo, not acceptable for
production. §4 asks for Redis to be justified before adding it, and a shared counter store is that
justification if this ever runs multi-instance — the limiter interface is deliberately narrow so
swapping the backing store touches one class.

### Refresh tokens are not revocable

There is no server-side denylist, so a leaked refresh token stays valid for its 14-day TTL. Out of
scope for Phase 1; the fix is a `jti` denylist table checked on refresh.

### The device eligibility bands are engineering thresholds, not validated benchmarks

`DeviceEligibilitySettings` is reasoned from the measurement requirement — the PTT differences
being tracked are milliseconds to tens of milliseconds, so sampling interval and clock stability
have to sit well below that. None of it has been validated against hardware. Phase 3's profiler
produces the measured numbers, and invariant 9 forbids inventing them in the meantime.
`app/config.py` states plainly which of its defaults are cited and which are design choices.

### No `TODO` comments

Per §7. Everything not built is listed here or in §8's out-of-scope list.

---

## Dependencies

Each with the one-line justification §7 asks for.

| Package | Why |
|---|---|
| `fastapi` | Mandated stack. |
| `uvicorn[standard]` | ASGI server for local runs and the Compose `api` service. |
| `sqlalchemy` | Mandated stack. |
| `alembic` | Mandated stack. |
| `psycopg[binary]` | Postgres driver; psycopg3 is the current generation and ships wheels. |
| `pydantic` | Mandated stack. |
| `pydantic-settings` | Env-var settings binding, so no threshold is ever a literal in code (invariant 10). |
| `pyjwt` | JWT access and refresh tokens (§4.5); no server-side session store needed. |
| `bcrypt` | Password hashing. Used directly rather than through `passlib`, which is one fewer dependency and has been unmaintained since 2020. |
| `python-multipart` | Required by FastAPI to parse the OAuth2 form-encoded token request. |
| `httpx` | `replay` posts through the real HTTP API; also the test client transport. |
| `typer` | Argument parsing for the two mandated CLIs. |
| `pytest`, `pytest-asyncio`, `anyio` | Mandated test runner and the transport its client needs. |

No Redis. No component library. No ORM plugins.

---

## Phase 2 — Dashboard

Scoped slice: palette and design system, plus the clinician episode summary and the patient
timeline. The other three screens in BUILD_SPEC 5.3 are not built yet.

### The three record types are distinguished by form, not by hue

BUILD_SPEC 5.2 asks for them to be unmistakable at a glance without reading labels. Colour alone
cannot do that — it fails in greyscale, in bright sunlight on a phone, and for a reader with a
colour-vision difference — and colour is forbidden from carrying clinical meaning anyway (5.1).
So the distinction is structural:

| Type | Form |
|---|---|
| Cuff reading | Solid `--brand` fill, white text, 3.25rem numerals, unit stated |
| Trend estimate | Outlined, no fill, **no numerals in the value area at all** |
| Rejected session | Dashed border, 0.78 opacity, reason text, retry affordance |

Fill / outline / dash is legible as three different things before a single word is read.

### Contrast was measured, not assumed

BUILD_SPEC 5.4 asks specifically about `--muted` on `--surface`. Measured ratios are in a
comment at the top of `dashboard/app/globals.css`. `--muted` on `--surface` is **5.29:1** —
passes AA at every text size, fails AAA — so it is used as-is for body-sized secondary text and
`--color-ink-800` (7.89:1) is used below 14px. `--color-ink-500` is 2.96:1 and is restricted to
borders and rules; it must never carry text.

### "No numerals at all" is scoped to the value area

BUILD_SPEC 5.2 says a trend estimate shows "no numerals at all". Taken absolutely that would
also forbid the timestamp, which would make the record unreadable. The rule is applied to the
**value area** — the region a patient reads as "the result" — which contains a direction arrow,
a sentence and a three-step signal meter, and not one digit. The timestamp sits in the footer in
small secondary text where it is unmistakably a date.

Two consequences follow:

- `magnitude_sd` is available on the object and is **not rendered** in the patient view. Showing
  it would put a number exactly where a patient expects a blood pressure.
- Confidence is a three-step meter labelled "limited / moderate / strong signal", not a
  percentage. The wording stays about the signal, never about the patient.

The clinician view *does* show `magnitude_sd`, because a clinician needs to know how far outside
baseline a session fell. It is labelled "2.6 SD / of this patient's own baseline" and carries the
estimate badge. BUILD_SPEC 5.4 forbids rendering it as though it were mmHg, not rendering it.

### Warning treatment uses the ink ramp, never a hue

The palette has no red and no green and none may be added. System-state attention — stale cuff
reading, no active calibration, unsynchronised sessions, a rejected session — is carried by a
3px `--ink` left rule on an `--ink-100` field (`.system-flag`), plus dashed borders and reduced
opacity. Nothing in the interface uses colour to say a physiological value is good or bad.

### TypeScript enforces the record-type separation

`TimelineItem` is a discriminated union on `record_type`. Reaching for `systolic_mmhg` on a
`TimelineTrendEstimate` is a compile error rather than a runtime `undefined` rendering as a
blank where a number should be, and the `switch` in the timeline page is exhaustive so a new
record type added to the API fails the build instead of silently not rendering.

### No mock data layer, and a broken page does not look like an empty one

BUILD_SPEC 5 requires running against the seeded backend. There are no fixtures in the project.
When the API is unreachable the page renders `ApiErrorNotice`, which says so explicitly and
states that no records are shown because none could be read — not because none exist. An empty
timeline and a broken timeline must not look the same.

### Dashboard authentication is demo-only

Server components obtain tokens with the password grant using the seeded demo accounts from
`dashboard/.env.local`, cached in module scope until a minute before expiry. Credentials never
reach the browser (`server-only` import guard). A real deployment needs a login flow with a
per-user session and a clinician who authenticates as themselves; this slice is about the record
treatments, and building a login screen would not have tested any of them.

### No charts in this slice

A trend chart is not among the requirements for either screen, and a time series of
`magnitude_sd` is the single easiest way to make an estimate look like a blood-pressure chart.
Deferred until the record treatments have been reviewed.

---

## Phase 3 — Device capability profiler

### The capture layer is a separate package, and this is what it does not do

`packages/tera_capture/` is a Flutter **plugin** — Dart *and* Kotlin — with no dependency on any
UI. The profiler is its first consumer. The patient capture app will be its second.

A DEVIATION from BUILD_SPEC §3's layout, which lists only `profiler/`. The reason: the profiler
is not a throwaway tool, it is the acquisition layer shipped first because it has a deadline.
Welding the camera and sensor code to the profiler's UI would mean writing it twice.

**What the capture package does, and only this:**

| | |
|---|---|
| `configure` / `start` / `stop` | Open and close the accelerometer and the rear camera |
| Accelerometer stream | Timestamped samples, in the sensor's own time base |
| Frame stream | One region-of-interest mean per frame, with its processing time |
| Achieved-rate reporting | Mean rate, interval SD, p99 interval, dropped estimate |
| Device context | Thermal status, battery level and charging state |
| Clock offset | Realtime vs uptime, with a precision flag |

**What it deliberately does NOT do.** This is the boundary the patient app will build on, and
naming it is what stops the profiler quietly growing into the patient app:

- **Buffer retention.** Samples are streamed and dropped. Nothing is kept and nothing is written
  to disk, because invariant 2 says raw sample buffers are never persisted. A consumer that
  needs a window holds it in memory and is responsible for not writing it anywhere.
- **Filtering.** No band-pass, no detrending, no smoothing, no resampling. The streams are what
  the hardware reported.
- **Event detection.** No aortic-valve-opening detection in the accelerometer trace. No foot- or
  peak-detection in the intensity series.
- **Beat pairing.** No association of an SCG event with a PPG event, and therefore no
  transit-time interval. **The package cannot produce a PTT value**, which is the strongest form
  invariant 2 can take at this layer.
- **Quality gate.** No decision about whether a capture is usable. The profiler grades a
  *handset*; the gate grades a *session*. Different question, different code.

If any of those five appears in `packages/tera_capture/`, the boundary has moved and this entry
is a lie. Put them in the consumer.

### Invariant 2 is structural in the Kotlin, not a rule

`CameraCaptureController.consumeFrame` reduces a frame to one `Double` and closes the `Image` in
a `finally` before returning. There is no reference to frame data outside that method, and no
type on the channel that could carry one. A future developer cannot persist a frame from Dart,
because a frame never reaches Dart.

### Every profiler value is a `Measurement`, not a number

BUILD_SPEC 6.2: "Report measured values only. If a measurement fails, say so — never substitute
an estimate or a plausible-looking number."

`Measurement<T>` is either `ok(value)` or `failed(reason)`. There is no default, no nullable
double that renders as `0.0`, and `requireValue` throws rather than yielding a zero. The
markdown row prints `not measured` in the cell.

The failure this guards against is not a crash. It is a run where the camera never opened and
the report shows `0.0 fps` — a figure a reader takes at face value and pastes into the
proposal's device table. `profiler/test/measurement_honesty_test.dart` asserts that a wholly
failed run produces a markdown row containing **no digit at all**.

Two consequences worth stating:

- `RateStatistics.fromTimestamps` returns null for fewer than three samples, and null for
  non-monotonic timestamps. Skipping a bad sample would hide a stream that is not what it
  claims to be.
- The upload to `POST /v1/device-profiles` **refuses** when any field the API requires could not
  be measured, and says which. The API has no way to record "not measured" for those fields, and
  a placeholder would put an invented number into a clinical record (invariant 9).

### The clock basis is measured, not believed

`SENSOR_INFO_TIMESTAMP_SOURCE` is a **declaration**, and `SensorEvent.timestamp` is *documented*
as `elapsedRealtimeNanos`. Neither is universally honoured.

The failure this guards against is invisible by every other measure. A handset that declares
`REALTIME` but timestamps frames in the uptime base has a correct frame rate, correct jitter,
correct intervals — and every cross-stream alignment computed from it is wrong by however long
the device has spent asleep since boot. Hours, typically. Nothing in the rest of the profile
would show it.

So every sample from both streams carries `elapsedRealtimeNanos` and `uptimeNanos`, read back to
back at delivery, before any other work in the callback. A timestamp must sit a plausible
pipeline latency behind whichever clock it is expressed in (−5 ms to +500 ms) and implausibly
far behind the other. `ClockBasisVerification` reports `realtime`, `uptime`, `indeterminate` or
`neither`.

- **`indeterminate`** when the two clocks differ by less than 10 ms — a freshly booted device
  that has not slept. Not a failure, just not an answer, and the verdict says to leave the
  handset idle and re-run.
- **`neither`** is a real finding: the timestamps are in some third base and nothing can be
  aligned against them until it is identified.

The accelerometer is checked the same way even though it declares nothing, because
`CrossStreamClockCheck` — do the two streams share a base — is the question that actually
decides whether a transit time is measurable at all. It has its own column in the markdown
table, since a handset that fails it cannot produce a PTT whatever its frame rate says.

Cost: two vDSO clock reads and two extra longs per sample, on both streams equally, so the
cold/warm comparison is unaffected. The analysis reuses the samples the two 60 s runs already
produced rather than adding a stage.

### Smoke mode is a different type, not a flag

`runSmoke()` returns a `SmokeReport`, not a `ProfileResult`. There is no conversion between them
and no `smoke: true` field on a shared type.

Five seconds of camera is not a sustained-rate measurement and never becomes one. A boolean flag
would rely on every export path remembering to check it; a separate type means the code that
builds the device eligibility table is structurally unable to accept smoke output. The report
shows observed numbers — that is what makes the debugging loop fast — under a header saying they
are not measurement data.

### `confidence_ceiling` is bounded, unlike every other threshold

`CONFIDENCE_CEILING_LIMIT = 0.95`, enforced at config validation, env-var path included.

Every other clinical threshold is tunable because a clinic may legitimately disagree with the
default. This one is not. Raising it toward 1.0 would not change what the number *is* — a blunt
ordering of sessions by how much usable signal they produced — but it would change what it
*looks like*, and a reader who sees 0.99 reads certainty into a heuristic that cannot support
it. That is invariant 6 by the back door: not a diagnosis, but a claim of accuracy the method
does not have. Lowering it is always allowed; there is no floor on modesty.

A model validator also rejects a floor above the ceiling, weights that do not sum to 1.0, and an
inverted SNR range. Each would still produce numbers that look like confidences, which is
exactly why they fail at startup rather than degrading quietly.

### The profiler does not compute a verdict

It measures; the backend grades. The eligibility bands live in `backend/app/config.py`, so
changing a threshold does not mean reflashing eight handsets. The upload response shows the
backend's verdict, labelled as the backend's.

### The warm camera run has no cool-down

BUILD_SPEC 6.4 asks for the repeat "immediately". `ProfileRunner` starts the second 60 s run
directly after the first with no pause and no teardown delay beyond closing the session. Any
gap would let the device recover and hide the throttling the run exists to find.

### Rates are measured, never requested

`SENSOR_DELAY_FASTEST` with `maxReportLatencyUs = 0` (batching off, or delivery arrives in
bursts and the timing means nothing), and the fastest advertised AE target FPS range for the
camera. What is *reported* is computed from `SensorEvent.timestamp` and `Image.timestamp` —
hardware timestamps, never the time a callback happened to run, which in a garbage-collected
runtime measures the runtime.

### `HIGH_SAMPLING_RATE_SENSORS` is declared in the plugin, not the app

So the patient app inherits it by depending on the plugin rather than by remembering. Verified
present in the profiler's merged release manifest. Below API 31 the permission does not exist
and no cap applies, so it is reported as granted — which is the truthful answer to the question
the field actually asks ("are rates above 200 Hz available to this app").

### `uptimeNanos` needs API 31; below it the offset is millisecond-resolved

`ClockOffsetSample.uptimeHasNanosecondPrecision` is false on those devices and the UI says so. A
millisecond is the same order as the effect being measured, so hiding the limitation would be
worse than the limitation.

### No `path_provider`, no `share_plus`

Export writes to the app-specific external files directory, resolved directly. One fewer
dependency to install on eight borrowed handsets in a hurry. `http` is the only non-Flutter
dependency, and only for the optional upload.

---

## The signal-processing contract (for whoever implements the real chain)

`packages/tera_capture` stops at acquisition. `patient/lib/signal/signal_pipeline.dart` is the
seam where beat detection, beat pairing and PTT derivation arrive. This section is the contract
in full, so it can be implemented without reading the Flutter code.

### Input — one capture, both streams recorded concurrently over the same window

| Field | Type | Units | Notes |
|---|---|---|---|
| `accelerometer.samples[].timestampNanos` | int | ns | The sensor's own base, from `SensorEvent.timestamp`. Never arrival time. |
| `accelerometer.samples[].x/y/z` | double | m/s² | Sternum-mounted. The SCG signal. |
| `frames.samples[].timestampNanos` | int | ns | Hardware timestamp, in the base `SENSOR_INFO_TIMESTAMP_SOURCE` declares. |
| `frames.samples[].roiMean` | double | 0–255 | Mean luminance over a centred ROI, one per frame. The PPG signal. **Frames themselves never cross this boundary** (invariant 2). |
| `frames.samples[].frameNumber` | int | — | For dropped-frame accounting. |
| `clockBasis` | `CrossStreamClockCheck` | — | The time-base relationship between the two streams, measured rather than trusted. Shape given in full below. |

A capture is **60 seconds** (`sessionDuration`, `patient/lib/ui/capture_screen.dart`). Both streams
run concurrently for that whole window.

**Use the accelerometer's vector magnitude**, `sqrt(x² + y² + z²)`, not a single axis. The phone's
orientation on the sternum is whatever the patient managed, so no axis reliably carries the
dorsoventral component. Magnitude is orientation-independent; it includes gravity as a ~9.81 m/s²
DC term, which the band-pass removes. A dorsoventral-axis implementation gives a cleaner AO complex
and is a legitimate override *if* orientation can be constrained — in which case the new rule gets
written here first.

### The clock basis, in full

`CrossStreamClockCheck` (`packages/tera_capture/lib/src/clock_basis.dart`), so this can be
implemented without opening it:

| Field | Type | Notes |
|---|---|---|
| `camera` | `ClockBasisVerification?` | Null when the camera side could not be determined. |
| `accelerometer` | `ClockBasisVerification?` | Null when the accelerometer side could not be determined. |
| `sharedBasis` | `bool?` (derived) | `true` both streams verified onto the same base; `false` verified onto different bases; **`null` at least one side inconclusive**. |
| `verdict` | `String` (derived) | Human-readable, for the profiler report. Not for logic. |

`ClockBasisVerification` carries `observed` (the base actually measured, not the one declared) and
`clockSeparationMillis` (`double`, ms) — the realtime-minus-uptime separation, i.e. how long the
handset has slept since boot.

**Acquisition does not reconcile the two streams. It measures and reports, and that is all.**

So the rule for the implementer is a rejection rule, not a correction rule:

- `sharedBasis == true` — proceed. Timestamps are directly comparable.
- `sharedBasis == false` — **reject with `clock_unstable`.** Do not apply `clockSeparationMillis`
  as a correction. Below API 31 that offset is only millisecond-resolved, and PTT is carried in
  10–50 ms shifts: correcting with it would convert a known-bad capture into a confident number
  with unbounded error. Invariant 7 says escalate when ambiguous, and this is ambiguous.
- `sharedBasis == null` — **reject with `clock_unstable`.** A relationship that could not be
  established is not a basis for a PTT. This is deliberately the same outcome as `false` but a
  distinct input case: "different bases" and "could not tell" are different facts, and the log
  should say which.

`clockSeparationMillis` exists for diagnostics and for the profiler's device report. It is not an
input to a clinical capture.

### The fiducial points — what PTT is measured between

The single most consequential definition here, and the one most likely to be assumed rather than
read. Two implementations that disagree on fiducials produce datasets that are each internally
consistent and mutually incomparable, and the disagreement stays invisible until calibration
baselines refuse to line up.

**PTT is measured from the SCG aortic-valve-opening (AO) peak to the PPG foot of the same cardiac
cycle.** This matches the proposal's own "pulse arrival" language, its PhysioNet PAT analysis, and
the "pulse-foot detection" component already named in its pre-existing-work table.

The detection rule, not just the physiology:

1. **Band-pass both streams.** SCG 10–50 Hz, which is where the AO complex lives; PPG 0.5–8 Hz.
   These bands are the conventional starting values, not figures derived from the proposal — the
   implementer confirms them against real data and records any change here.
2. **Segment cycles** from the PPG, which is the more periodic of the two: successive systolic
   upstrokes bound each cycle.
3. **AO peak** is the maximum positive peak of the band-passed SCG magnitude within the systolic
   window of that cycle.
4. **PPG foot** is located by the **intersecting-tangent method**: the intersection of the tangent
   at the point of maximum first derivative of the upstroke with the horizontal line through the
   preceding diastolic minimum. Chosen over the plain minimum because it is markedly less sensitive
   to baseline wander, which fingertip PPG has in quantity.
5. **Pair** each AO peak with the first PPG foot following it. `ptt = t_foot - t_AO`.

The teammate implementing the real chain may override any of this. **If he does, he writes the new
definition into this document before he writes the code** — never leaves it implicit in an
algorithm.

### Output — `SignalResult`, mapping onto the session payload in BUILD_SPEC 4.2

| Field | Type | Units | Notes |
|---|---|---|---|
| `accepted` | bool | — | The gate decision. |
| `pttMs` | `List<double>` | **ms** | One interval per usable beat, **already filtered to 80–400** by the pipeline (see the accept/reject boundary). Empty when rejected. |
| `nBeatsTotal` | int | — | Beats detected. |
| `nBeatsUsable` | int | — | Beats surviving the gate. Must equal `pttMs.length` and must not exceed `nBeatsTotal`; the backend enforces both. |
| `quality.accel_rate_hz` | double | Hz | Achieved, not requested. |
| `quality.camera_fps` | double | fps | Achieved. |
| `quality.dropped_frame_pct` | double | 0–100 | |
| `quality.snr_db` | double | dB | |
| `quality.motion_index` | double | 0–1 | 0 still, 1 unusable. |
| `quality.clock_offset_ms` | double? | ms | Optional. |
| `rejectionReason` | enum | — | Required when `accepted` is false; the constructor asserts it. |

### The accept/reject boundary

Reject when the signal does not support a number. The proposal specifies dual-estimator
agreement — time-domain peak detection against frequency-domain spectral estimation — with
rejection when the two disagree beyond tolerance. **Rejecting is a correct output, not a failure
of the implementation.** The system declining to produce a number when the signal does not
support one is the designed behaviour.

**Out-of-range intervals are dropped by the pipeline, not passed through.** A paired interval
outside 80–400 ms is discarded and excluded from `nBeatsUsable`; it still counts in `nBeatsTotal`,
because the beat was detected. If the surviving count then falls below the minimum, reject the
session with `insufficient_beats`.

The backend's 80–400 ms gate stays exactly as it is, as defence in depth — but it is no longer the
primary filter, and the pipeline must not rely on it. The reason is asymmetric cost: the backend
gate rejects the **whole session** if one interval is out of range, so passing a single bad pair
upward throws away fifty-nine good seconds of capture. Losing one bad pair beats losing the
session.

**The minimum is a stated threshold, not the implementer's judgement.** The backend's
`min_usable_beats` is **30** (`backend/app/config.py`, with the reasoning: a 60 s capture at 60 bpm
gives ~60 beats, so 30 means at least half the capture survived). It is overridable per episode via
`monitoring_episode.protocol_params.min_beat_count`. The handset mirrors it as a constant and
cross-checks it against the backend — see the threshold cross-check below.

### Constants

Everything the implementer would otherwise have to guess, in one place.

| Constant | Value | Where it lives |
|---|---|---|
| Capture duration | 60 s | `sessionDuration`, `capture_screen.dart` |
| Minimum usable beats | 30 | backend `min_usable_beats`; mirrored on the handset |
| Plausible PTT range | 80–400 ms | backend `ptt_min_ms` / `ptt_max_ms`; mirrored on the handset |
| Maximum interval count | 300 | backend `max_ptt_array_length` (invariant 2 bound) |
| Accelerometer input | vector magnitude | this document, above |
| SCG band-pass | 10–50 Hz | starting value; implementer confirms and records |
| PPG band-pass | 0.5–8 Hz | starting value; implementer confirms and records |
| Dual-estimator tolerance | see below | handset constant |

**Dual-estimator tolerance.** The time-domain mean heart rate (from detected beat intervals) and
the frequency-domain estimate (spectral peak of the band-passed PPG) must agree within the
tolerance or the session is rejected with `poor_signal_quality`. It stays a **handset constant** for
now rather than backend configuration, because it gates a decision made before anything is
submitted. Treat the initial value as an engineering choice pending validation against real
captures, in the same register as `min_usable_beats` — and record the validated figure here once
there is hardware data to set it from.

### `snr_db` and `motion_index` are not yet defined

Both fields are required by the payload and **neither has an agreed formula.** Defining them
without real captures to test against would mean inventing a number and then treating it as
established, which is the one thing this document exists to prevent.

So, explicitly: **the implementer defines the formula for these two and records it here when the
real chain is implemented.** Until that happens, **the backend must not gate on their absolute
values.** They are carried, stored and displayed; they are not thresholds. The stub reports
`snr_db: 0.0` and `motion_index: 1.0` — both at their worst — rather than inventing something
favourable.

### Error contract

**`process()` does not throw for any signal-related reason.** A signal that cannot be turned into
intervals is a *return value*: `accepted: false` with the reason that names the actual cause. Bad
signal is an expected outcome of this system, not an exception.

A throw therefore means a genuine fault — a bug, or a condition the implementation did not
anticipate. The caller catches it, records the session as rejected with
`signal_processing_unavailable`, and logs an incident. Invariant 3 says the session is retained
either way.

That reuses the stub's reason, and the ambiguity is resolvable from the data rather than by
convention: `model_version` distinguishes the two cases. `tera-patient-0.1.0-nosignal` means the
chain was absent by design; any other version emitting `signal_processing_unavailable` means the
chain was present and failed. Nobody has to remember which.

A null or inconclusive `clockBasis` is **not** a fault and must not throw — it is
`clock_unstable`, as set out above.

### The golden vector

There is no hardware data, so there is a **synthetic paired recording with a known ground-truth
PTT** committed alongside the tests, and the expected output is documented with it. It exists so an
implementation can be checked against something other than "it compiles and returns plausible
numbers" — which is precisely the failure mode the prohibition below warns about.

See `patient/test/fixtures/README.md` for the fixture, its parameters and the tolerance an
implementation is expected to meet. Synthetic is not real data and does not prove the chain works
on a chest; it does prove the chain agrees with the contract on this page.

### The one prohibition

**Never return plausible values that were not derived.** Every number here becomes a row in a
patient's clinical record and a line in a clinician's summary. A fabricated interval becomes a
genuine trend in the backend and an estimate on a patient's screen, indistinguishable downstream
from a measured one. That is exactly what the estimate-versus-measurement separation exists to
prevent.

### Why the stub rejects everything

`UnimplementedSignalPipeline` returns `accepted: false` with reason
`signal_processing_unavailable` for every session. That value is deliberately **not** a
signal-quality reason: a judge, a teammate or a clinician must be able to tell "the signal was
bad" from "this part of the system does not exist yet", and collapsing the two would make an
unfinished component look like a working one that happened to reject.

Sessions are still submitted and still stored, so the flow is demonstrably complete end to end,
and rejected sessions are already designed to be visible in the timeline and the clinician
summary (invariant 3) — nothing is hidden. `model_version` is `tera-patient-0.1.0-nosignal`, so
every row carries its own provenance without anyone having to remember it.

The quality block is genuinely measured: rates and dropped frames come from the capture that
just happened. `snr_db` and `motion_index` cannot be computed without the signal chain and are
reported at their worst rather than invented favourably.

**Paired backend change:** `signal_processing_unavailable` is added to the `rejection_reason`
enum by an additive migration. Additive because Postgres enum values cannot be dropped without
rewriting the type; the downgrade is a documented no-op, as in `0003`.

### The threshold cross-check

Several thresholds exist in two places at once: 200/500 Hz eligibility bands, the 30-beat minimum,
the 80–400 ms range. The backend holds them as pydantic-settings, environment-overridable. The
handset holds them as compile-time Dart constants, because it must decide before it can talk to
anything. They agree today by hand, and nothing kept them agreeing.

That is a live failure mode, not a theoretical one: set a backend override at a venue and the two
halves disagree silently, with the handset admitting captures the backend then rejects.

**The check compares verdicts, not numbers.** The handset grades the device and then submits the
measured figures; the backend independently grades the same figures and returns
`qualified_status` plus per-measurement `findings`, each carrying the `threshold` it applied. If
the two verdicts differ, a threshold has drifted — whatever the numbers are.

Comparing verdicts rather than parsing `finding.threshold` is deliberate. That field is prose
(`">= 500 Hz target, >= 200 Hz minimum"`), built for a human reading a device report. A Dart regex
over it would be a second place for the two halves to disagree, and it would fail silently the
first time someone rewords the string. The verdict is a value both sides compute from the same
inputs, so comparing it detects drift with nothing to parse.

On mismatch the app logs loudly, including the backend's `threshold` prose so a human sees the
actual numbers, and continues — the backend's grading is authoritative for what it stores, and
blocking the patient over a configuration disagreement would be the wrong trade. See
`patient/lib/capture/threshold_crosscheck.dart`.

---

## Invariant 8 on the handset: the half that had to work offline was the half that was missing

The invariant says a red flag produces an immediate instruction to seek emergency care, with no
measurement offered and no estimate displayed, and that **the path must not depend on network
availability** — the handset shows it locally, the API call is a record.

The backend half shipped in Phase 1: `POST /v1/events` accepts a `red_flag` event and echoes an
`emergency_instruction`, with a passing named test. The handset had no symptom entry, no triage and
no emergency screen. So the only half that was built was the half the invariant does not rely on,
and the invariant table said "enforced" because it named the endpoint.

**Triage runs first, before the eligibility probe.** Putting it after would make someone reporting
chest pain sit through six seconds of sensor measurement, and the eligibility screen can itself end
in "this phone cannot be used" — which would swallow the report entirely.

**Any single flag terminates.** No severity weighting, no combination waved through. Invariant 7: a
false alarm costs a wasted trip, a false reassurance can cost much more.

**Offline is structural, not a behaviour to remember.** `SymptomTriage.decide` is a pure function
of the selection — no `ApiClient` in the signature, no clock, no IO — and `emergencyInstruction` is
a compile-time constant. There is no path from selecting a flag to showing the instruction that can
touch a socket. The emergency screen paints, and only then does a post-frame callback attempt the
record.

**The instruction is duplicated rather than fetched.** It is a verbatim copy of
`ACTION_SEEK_EMERGENCY_CARE` from the backend's `language.py`, asserted by a test so a change there
fails here. Fetching it would make the one path that must survive a dead network depend on that
network, which is the exact thing the invariant forbids. The backend's copy is the record of what
was shown; the handset's is what is shown.

**`RedFlagRecorder` never throws and its result never changes what the patient sees.** A failure is
reported as a quiet footnote — "this phone could not reach your clinic's record just now, that does
not change the advice above" — stated rather than apologised for. A patient who may be having a
cardiac event is not shown a network error and is not made to wait on a retry.

**The screen does not interpret.** Invariant 6 forbids diagnosis and reassurance alike, and the
temptation here runs in both directions. A test asserts the copy contains no "heart attack", no
"stroke", no "probably", no "may be nothing". It says what to do and stops. `PopScope` prevents
swiping back into a measurement.

## Cuff readings are entered on the handset, and confirmation is a type

Appendix C of the proposal puts manual cuff confirmation on the live-demo critical path, and it
could not be done from the phone at all. The backend has always accepted `POST /v1/cuff-readings`;
nothing on the handset called it. That also meant the calibration loop — the thing that makes
PTT-as-change legitimate — could not be demonstrated from the device that does the capturing.

**Manual entry only.** `source` is always `manual_entry`. Seven-segment OCR from a photograph is
out of scope (BUILD_SPEC 8), the backend refuses both `source = 'photograph'` and any
`ocr_confidence`, and the app never sends either. The screen says so in words, so a judge does not
have to infer the absence of a feature from its absence.

**Confirmation is enforced by the type system, not by a flag.** `user_confirmed_at` is NOT NULL in
the schema, so an unconfirmed reading is not representable — but "not representable" is only true
if the client cannot construct one. `ConfirmedCuffReading` has a private constructor and is
produced solely by `DraftCuffReading.confirm()`; `CuffReadingSubmitter.submit` accepts nothing
else. There is no path from a text field to the API that does not pass through a person saying yes,
and that is a property of the code rather than of the screen flow, which somebody could otherwise
reorder.

`confirm()` throws on a draft that does not validate, so an invalid reading cannot be confirmed
into existence by a caller that forgot to check first.

The reason for the weight: a mistyped blood pressure is not an ordinary typo. It becomes the
reference every later estimate is measured against, the table is append-only, and a correction is a
new row rather than an edit. Confirming costs a tap.

**The confirm screen shows the numerals at display size.** A 15pt echo of what was just typed
confirms nothing — the thing being checked against the cuff display is the digits. This is the one
place in the patient app where large numerals are right, and it is exactly the case invariant 1
reserves them for: a cuff measurement, not an estimate.

**Bounds are mirrored, and they are data-entry filters rather than clinical thresholds.** 50–300,
30–200, 25–250 and "systolic above diastolic" match `check_cuff_reading` field for field so an
obvious slip is caught while the cuff is still in front of the patient. A value inside the range is
not "normal" and one at the edge is not an alarm; the app says nothing about what the numbers mean
(invariant 6). A test asserts the constants against the backend's values so a rebanding fails
loudly rather than drifting.

**Timestamps are UTC.** `DateTime.now().toUtc()`, asserted in a test — a handset in WIB filing a
reading eight hours out would corrupt the ordering the whole timeline depends on.

`resolveEpisode()` was split out of `SessionContextResolver.resolve()` for this. A cuff reading
needs an episode and nothing else; registering a device profile to file a number the patient read
off a cuff would attach a handset measurement to a record the handset did not take.

## The patient app registers its own device profile

A session payload references a `device_profile_id`, and nothing else creates one for a patient
handset: the profiler is a separate utility that a patient does not run, and there is no endpoint
that lists a patient's existing profiles — only `GET /v1/device-profiles/{id}`.

So the app registers the handset itself, the first time a spot check is taken, and caches the id.

**It measures all five figures rather than defaulting the ones the eligibility gate does not
need.** `DeviceProfileCreate` deliberately has no optional measurements (invariant 9): a figure
that could not be measured must fail the submission, not arrive as a plausible substitute. The
eligibility probe only needs the accelerometer rate, so `DeviceMeasurer` additionally measures the
camera rate and the clock-offset spread, from the same package the profiler uses, and the payload
mirrors the profiler's exactly — a handset registered by either route grades identically.

The camera probe runs under the same `CaptureConfig` as a real capture. A rate measured with
auto-exposure running is not the rate the method will see, so measuring under different settings
would register a figure the handset never delivers during a spot check.

Two smaller choices:

- **The open episode, not the first.** A closed episode is a finished course of monitoring, and
  appending to it misfiles the reading in a way that looks correct afterwards.
- **The stored `qualified_status` is what counts**, not the app's own grading of the same
  numbers. The app grades to decide whether to let the patient proceed; the backend's verdict is
  what every session references.

A clinician account resolves to no patient and is told so directly, rather than being allowed to
fall through to an empty episode list, which would read as a missing record.

---

## Surface hierarchy in the patient app

`lib/ui/tokens.dart` mirrors the web client's rework — mint is the page, white is the panel, brand
is the app bar and primary actions. The full argument, the measured table and the reproducing
script live in the tera-web repo's `docs/decisions.md`; the short version is the one measurement
that drives it:

**A white panel on the mint page is 1.08:1.** Mint and white are near-identical in luminance, so a
panel is not a panel because of its fill — it is a panel because of its border. `panelDecoration()`
is the single place that treatment is defined, and it uses `ink500` (#718392, 3.62:1 on mint,
3.92:1 on paper) because `ink200` at 1.23:1 cannot hold an edge on mint.

`TeraColors.paper` exists so a bare `Colors.white` is auditable. After the sweep there is no
`Colors.white` anywhere in `lib/` outside the token file.

The app bar moved from ink to brand, and `systemFlagDecoration()` moved from an ink rule on
`ink100` to a muted rule on `muted100` — the rule carries the meaning, the fill is a hint at
1.25:1 and is not asked to be more.

---

## Raw CSV export — a documented exception to invariant 2, not a repeal

The signal chain cannot be written against summary statistics. It needs the raw accelerometer and
ROI series from a real handset, and until now nothing kept them: the profiler reduced each
recording to statistics and dropped it, and the patient app never wrote one down.

So both apps can now write the two series to CSV, **in a developer build only**.

### What is unchanged

Invariant 2 is a property of the *clinical path*, and that path is untouched. The API accepts one
derived interval per beat and nothing deeper; there is no field for a waveform, and no code added
here goes near a submission. `tera_capture` still reduces each camera frame to one number inside
the platform layer, so there is no image data to export even deliberately.

### The terms, which are printed in the UI at the point of use

- **Own or teammate handsets only. Never a patient's.**
- **Purely local.** There is no network path from the export. The profiler's upload sends a device
  profile — model, rates, hardware level, clock spread — and never a sample.
- **Delete after analysis.** App-specific external storage clears on uninstall, but that is a
  backstop, not the plan.

### Why a compile-time flag rather than a runtime toggle

`kDebugCaptureEnabled` comes from `--dart-define=TERA_DEBUG_CAPTURE`. In a build that did not pass
it, the guard is a constant `false`, the branch is tree-shaken, and no sequence of taps reaches
the export. A runtime switch would leave the capability in every shipped build, one mis-set
boolean away from writing a patient's raw waveform to disk. That difference is worth more than the
convenience of toggling it.

### Two smaller choices

- **The profiler retains nothing new.** Each recording is serialised inside the scope that already
  held it and dropped immediately after, so the memory profile of a run is unchanged.
- **A failed export never fails a profiling run.** Sixty seconds of measurement on a borrowed
  handset is the point; the CSV is a bonus, and losing it quietly beats losing the run.

### Where the serialiser lives

`packages/tera_capture/lib/src/debug_csv.dart` — pure functions from a recording to a string. No
file IO, no retention, no network. **This does not move the package boundary:** the five things
the package deliberately does not do are buffer retention, filtering, event detection, beat
pairing and the quality gate, and a CSV formatter is none of them. File IO and the flag live in
the applications, because those are the parts with consequences.

`frame_number` is exported rather than a row index, so a dropped frame stays visible as a gap
instead of silently closing up — otherwise the achieved rate would look perfect offline. There is
a test for exactly that.

---

## Brand carries meaning, neutrals carry structure (patient app)

`lib/ui/tokens.dart` follows the web client's rework: page is a light neutral (`#F7F8F9`), panels
are white, and a nine-step neutral scale mixed from Deep Space Blue does the structural work. The
full argument and the measured table live in the tera-web repo's `docs/decisions.md`; both clients
are measured by the same script so they cannot drift apart silently.

Two things specific to this app.

**Wine Plum is system state only.** `systemFlagDecoration()` is plum: a rejected session, an
unqualified handset, a failed sign-in, an unreachable API. The new `attentionDecoration()` is for
things that describe the *patient* — no hue at all, weight and an ink rule. A deviation is
physiological and never gets plum. The debug-export panel moved to `attentionDecoration()` too: a
developer affordance is not a system fault and plum overstated it.

**The type is a step larger than the web client throughout**, because the persona is a 52-year-old
with hypertension holding a phone against their sternum, often in poor light. `TeraText` is
30/21/17/15/12 against the web's 28/18/15/13/11, buttons have a 52dp minimum height, and there is
no small grey text on a light ground: supporting copy is `neutral700` at 15px, never a lighter
step at a smaller size. Several 12px and 13px `muted` strings were exactly that and were raised.

## Seeing the patient app

`patient/tool/screenshots.ps1` pulls a screencap from an attached emulator or handset into
`patient/screenshots/` (git-ignored). It deliberately does not drive the app through its screens —
there is no reliable way to do that from adb without a UI-automation harness, and one is not worth
adding. Take a shot, tap to the next screen, take another. The value is in looking.

Note for anyone reproducing: `adb` is not on `PATH` on the development machine. It lives at
`%LOCALAPPDATA%\Android\Sdk\platform-toolsdb.exe`.

---

## Environment notes

The Compose Postgres publishes on host port **5434**, not 5432 or 5433 — both were already taken
by other Postgres instances on the development machine. Change it in `docker-compose.yml` and
`backend/.env` together if that does not suit.

## Context intake, and the pregnancy hard stop

The B2C pivot removes the clinic. Nobody enrols the patient, nobody reviews their history, and
nobody notices the method being applied to someone it was never validated on. The intake form is
the only place that information can come from, so it is also the only place a contraindication can
be caught.

**Rules are pure Dart.** `ContextIntakeSafety.evaluate` is a function of the intake alone — no
network, no clock. A contraindication that needed a server would fail open on a bad connection, and
open is the expensive direction.

**Stored locally, never sent.** There is no endpoint for this. `POST /v1/events` takes a bounded
free-form payload, but medication names and a pregnancy answer are exactly the clinical content the
logging deny-list exists to keep out of the system, and inventing an endpoint is not a routine
decision. Secure storage on the handset, and the gate reads it from there.

**Only `pregnant == yes` blocks.**

- `prefer_not_to_say` does **not** block. Blocking a declined answer makes declining functionally
  identical to saying yes and coerces a disclosure the patient chose not to make. It is stored as
  what it is, three-valued, rather than collapsed to a boolean.
- `known_arrhythmia` is recorded and shown but does not gate. It degrades beat detection rather
  than invalidating the method, and the signal chain's own quality gate is where a capture too
  irregular to use gets rejected.
- **An unanswered intake does not block either.** The form is not a precondition for opening the
  app. This is the weakest point in the layer: an unanswered pregnancy question is exactly the
  ambiguity invariant 7 says to escalate on, and the honest reading is that the gate only protects
  patients who answer. Revisit before this reaches anyone real.

**The gate is applied twice.** The intake screen shows the hard stop dialog, and the home screen
disables the spot-check button from the stored answer. A patient who backs out of the dialog lands
on the home screen, and one enabled button there would be one tap from the flow the block exists to
prevent.

The block copy names the limitation and refers on. A test rejects "pre-eclampsia", "dangerous",
"normal" and the rest — invariant 6 applies here as everywhere, and it caught a first draft of this
message that said Tera could not tell "a normal change" from one that matters.

## OCR-first cuff entry, and why an OCR reading is still `manual_entry`

Photographing the tensimeter is now the first offer on the cuff screen, with typing beside it.
Both routes end at a person confirming the numerals, and the submit call is reachable only from a
confirm stage.

**The extractor is a mock.** `MockCuffOcrExtractor` returns 152/96, pulse 74, confidence 0.88 after
a second. There is no model, no image and no camera. It exists so the confirmation UX can be built
and judged before a real extractor exists.

**The mock marks itself.** `CuffOcrReading.simulated` is set inside the mock and is not a
constructor parameter a caller could set to false — a mock that can claim not to be one eventually
will. The suggestion screen shows a system-flag panel saying no photograph was taken. Invariant 9
applies to a placeholder exactly as it does to the seeder.

**Confidence is displayed and never acted on.** There is deliberately no threshold above which the
app saves without asking. A confident misread of a seven-segment display is the whole failure mode
here: an 8 read as a 6 looks precisely as confident as an 8 read as an 8. The screen says so —
"that is not a check on whether the numbers are right, only you can do that".

**An OCR-assisted reading is submitted as `manual_entry`, and this is not a workaround for D9.** It
is the same reasoning D9 refuses `photograph` for. `photograph` asserts that the *system* read the
display and stands behind the value; nothing in this build does. What actually happened is that a
person read numerals off a device and confirmed them, which is what `manual_entry` means. No
`ocr_confidence` is sent, and the type-level gate from the manual path is unchanged — a suggestion
carries no confirmation of its own and has to pass through `DraftCuffReading.confirm()`.

**An implausible suggestion routes to Edit rather than to an error.** Swapped numbers are what a
misread display most often produces, so "Correct, save" on a 96/152 suggestion drops into the form
pre-filled with the reason shown, rather than into a dead end.

Widget tests assert `_requests == 0` at every point before an explicit confirmation, so "nothing
reaches the API without a person saying yes" is checked rather than described.

## The intake now reaches the server, and the gate still does not depend on it

`POST /v1/patient-context` is the durable record. Without it the intake vanished on uninstall and
the server could not see a contraindication it is expected to respect.

**Local first, unconditionally.** `ContextIntakeStore.write` happens before the upload is
attempted, because `ContextIntakeSafety` reads the local copy. A contraindication that needed a
network call would fail open on a bad connection, and open is the expensive direction. A patient
who reported pregnancy is blocked whether or not the server heard about it — asserted.

**`PatientContextSubmitter` never throws, never blocks and never gates.** Same shape as
`RedFlagRecorder`, for the same reason.

**The wire shape is flat.** `last_clinic_systolic_mmhg`, `last_clinic_diastolic_mmhg`,
`last_clinic_taken_on`, rather than the nested `last_clinic_bp` the local JSON uses. The backend
keeps those three in their own columns so a CHECK can hold them together; matching that here keeps
the mapping in one place rather than two. Blank medication rows the form leaves behind are dropped
on the way out.

A failed upload is stated rather than apologised for: saved on this phone, not yet in your account,
save again when you are back online. The earlier copy — "these answers stay on this phone, Tera
does not send them anywhere" — was true when written and is not any more; it is gone from both the
form and the home screen.

## The signal chain is ported to Dart, and runs on the handset

The ML team delivered `tera_ptt.py` with a FastAPI wrapper: raw SCG and PPG arrays posted to a
server, `contract.py` saying "Send raw samples. Do not pre-filter on the phone." A 30 s capture is
about 25,000 floats.

**That architecture is refused, not adopted.** Invariant 2 says raw waveform never leaves the
handset, and it is a regulatory claim in the pitch — structural PDP compliance, not a preference.
Sending the buffers would have destroyed it. The algorithm moves to the phone instead.

### What made the port feasible

`tera_ptt.py` ships a **scipy-free fallback** — an FFT brick-wall band-pass, an FFT Hilbert
transform, and a simple peak finder — for environments without scipy. That, not the Butterworth
`sosfiltfilt` path, is the port target. Reproducing `sosfiltfilt` in Dart faithfully enough to keep
the team's swept thresholds valid would not have been credible; reproducing three numpy functions
is.

`lib/capture/dsp/fft.dart` implements arbitrary-length DFT via Bluestein's chirp-z, because
zero-padding 6000 samples to 8192 would move every frequency bin and therefore every filter edge
and every spectral heart rate. `signal_ops.dart` reproduces numpy's conventions where they are easy
to get subtly wrong: `convolve(mode='same')` offsets, `gradient` edges, `percentile` interpolation,
`std` ddof.

### How it is known to be right

`test/fixtures/ptt_reference_vectors.json` is generated by running the ML team's own Python with
**scipy blocked**, and `test/ptt_reference_test.dart` pins the Dart against it: SCG beat times and
PPG foot times to the microsecond, every paired interval, median, SD, IQR, pair yield, and every
quality-gate verdict, across a clean seated capture, a motion-corrupted one and one too short. All
match. The generator is `tool/` adjacent and reproducible.

### Reversal: the chest-normal axis, not the vector magnitude

An earlier entry in this file specified `sqrt(x^2+y^2+z^2)` on the grounds that phone orientation
is unknown. **The ML team is right and that was wrong.** Gravity is about 9.81 m/s2 and the cardiac
signature about 0.02, so a magnitude is dominated by gravity and reduces to the projection onto
whichever way gravity points — and it destroys the sign that separates valve opening from closing.
The pipeline now reads `z`. Their handoff also describes backend axis selection across x, y and z;
that is not ported, so a handset held at a large angle will fail the gate rather than recover. It
is recorded as a gap, not silently dropped.

### `snr_db` and `motion_index` now have definitions

Both were reported at their worst while there was no chain to define them against. `snr_db` is
`20*log10(median PTT / SD)` — how well resolved the measurement is — and `motion_index` is the
fraction of detected beats that failed to pair, which is what motion actually produces. **Both are
heuristics, labelled as such here**, not validated figures, and the backend does not gate on their
absolute values.

### What the gate maps onto

Four checks, cheapest first, unchanged from the reference: paired-beat count, per-sensor
dual-estimator agreement, **cross-sensor chest-vs-finger agreement** (the check a single-sensor
product cannot run), then pair yield and PTT stability. `sensorsDisagree` and `pttTooVariable` map
to `excessive_motion`; the two dual-estimator failures to `poor_signal_quality`; count and yield to
`insufficient_beats`. Every reason names something the *device* could not do.

`signal_processing_unavailable` now means a **fault in the chain**, not its absence — a throw from
`process()`. `model_version` moves to `tera-patient-0.2.0-ptt-dart-r1` so a row can be traced to
the algorithm that produced it, and a test asserts it no longer says `nosignal`.

## The rhythm model runs in pure Dart, because a Random Forest cannot be a `.tflite`

`ml/MODEL_HANDOFF.md` section 1 states it directly: TFLite converts TensorFlow/Keras models only,
and the artefact is a **scikit-learn Random Forest**, so there is no `.tflite` to scaffold against.
The ML team prepared two on-device routes instead — `model.onnx` via `onnxruntime`, and
`model_trees.json` for "evaluasi pohon murni di Dart (tanpa dependensi runtime)".

**The second route is taken.** A decision tree is an `if` ladder, so a 400-tree forest needs no
inference runtime, no native library and no new dependency — which also means nothing new to
install, sign or debug the day before a deadline. `lib/capture/dsp/rhythm_model.dart` walks the
trees and averages.

**The 37 MB asset is not bundled.** `RhythmForest.fromJson` takes decoded JSON, so wiring it to a
real asset is a deliberate act with a build-size cost attached. The handoff's own recommendation
stands: "Leave `rhythm_model` unset and everything works... A missing flag costs nothing. A false
'irregular rhythm' on a healthy volunteer in front of a judge costs a lot."

**The operating point comes from the file.** `model_trees.json` ships 0.10024, which is the
sensitivity-0.90 point the model was validated at. A 0.5 default is not a conservative version of
that, it is a different model, so the fallback is flagged rather than applied quietly.

**The feature order is enforced, not assumed.** Wrong order gives a confident answer from the wrong
columns with no error anywhere, so a reordered or wrong-length `features` list is a `FormatException`
at load. Tested both ways.

**Too few intervals returns null, not "regular".** Fewer than eight usable RR intervals means the
question was not asked. Reporting a negative would be an answer the data does not support.

The 10 HRV features are pinned against the ML team's own `_hrv_features` by
`test/fixtures/hrv_reference.json`, generated from their Python. The tree walker is pinned against
a two-tree forest small enough to verify by reading it, because the real one is 37 MB.

**Not yet wired into the capture flow.** The chain produces SCG beat times and the model consumes
them, but nothing calls it: with the model off by default and no asset bundled, wiring it would add
a branch that is dead in every build we ship this week.

## The master flow: routes from the PM spec, decisions in one pure file

Section 32's route tree is reproduced verbatim rather than renamed to Dart taste. It is the
contract between design, the backend spec and this app, and a route that reads differently here is
a route somebody has to translate in their head every time.

**The state machine is pure and lives away from the widgets.** `routing/check_session.dart` holds
sections 31 and 38 as functions of their inputs, with `now` passed in. These are product rules with
a written specification; spread across four `Navigator.push` call sites they could not be read
against that specification or tested without pumping a UI. Every transition returns state *and*
route together, so a caller cannot advance the machine without navigating or navigate without
advancing it.

**The seven-day gap is tested at its boundary**, not near it: 6d23h does not trigger a refresh,
exactly 7d does, because the rule is `>=`. It is a prototype product rule, not a clinical
calibration expiry, and the constant's name and comment say so. The copy follows the spec's
instruction: "your BP reference needs a refresh", never "your calibration expired".

**A not-eligible device is never asked for a BP reference.** It has no sensor trend to reference
against, so the number would have no consumer. Asserted across all three reference states.

**An unchecked device is treated as not eligible.** The BP-only path works everywhere and blocks
nobody; assuming eligibility would walk a patient into a capture their phone cannot perform. The
same reasoning makes `couldNotCheck` route to DEV-03 — "we could not tell" is not "your phone
works".

**Invariant 8 stays in front of `startCheck`.** The spec's state machine begins at the BP reference
or the pre-check. Red-flag triage is a navigation step before it rather than a state inside it, so
the machine still matches the spec exactly while a patient reporting chest pain is not walked
through a reference flow first.

**ONB-02 is not a stub.** The spec's Measurement Safety screen asks the pregnancy and rhythm
questions, which is what `ContextIntakeScreen` already does — including the hard stop and the
`/v1/patient-context` upload. The route points at the real screen. Likewise `check/bp-input`,
`bp-scan` and `bp-confirm` all resolve to `CuffReadingScreen`, which already carries scan, manual
entry and the explicit confirmation step; three routes onto one screen beats three copies of a
confirmation gate.

**Capture attempts are counted on the way out of the gate.** A retry that never reaches it cannot
inflate the count, and a rejected attempt always does.

Stubs are deliberately ugly — Scaffold, title, one line, one button — and each names the spec
section it stands for. A stub that looks finished gets left alone.

## Session submission, CTX-01 and the PHR

**The payload rides beside the session, not inside it.** `CheckPayload` carries the signal result,
the capture time and the context through `CheckArgs`; `CheckSession` stays a pure state machine
with no capture or API types in it. Previously nothing carried the pipeline output past the capture
screen, so `ProcessingScreen` had nothing to submit and no session ever reached the API through the
new flow.

**A rejected session is carried too.** Invariant 3 keeps it, so processing needs it whether the
gate passed or not.

**BP-only submits nothing at processing.** The confirmed reading *is* the measurement and
`CuffReadingScreen` already filed it; there is no second thing to send. Asserted by a test that
counts zero requests.

**403 is not an error to retry.** It is the server-side contraindication gate, so it gets its own
wording and no retry button. Network failures and 5xx do get one. Both are asserted.

### CTX-01 goes through `/v1/events`

`POST /v1/sessions` sets `extra="forbid"`, so a context object cannot ride along without changing
the schema invariant 2 is expressed in — not a place for a casual free-form addition.
`/v1/events` already has the right shape: an episode, a time, and a payload bounded at 32 keys
precisely so it cannot become a data channel. Five keys fit.

The event type is `symptom`: the only contextual type the enum offers, with the medication answer
carried as a field rather than as a second event. **It is filed even when nothing was reported** —
"nothing different today" is an input to the intervention matrix, and a day with no context
recorded is not the same fact as a day recorded as unremarkable.

Filed at the context screen rather than at submission, so it survives a capture that never
completes. Best effort throughout: losing the context must not lose the reading.

**The contextual symptoms are deliberately not the red-flag list**, and a test asserts no overlap.
Red flags terminate the session before capture, locally and offline. Anything appearing in both
places would be a red flag arriving too late to act on.

### The PHR is local, and derives nothing

ONB-01 and ONB-03 are real forms now. `/v1/patient-context` already carries the ONB-02 answers but
has no columns for date of birth, sex, height, weight or a hypertension flag, and adding them is a
backend change rather than a routine one — so this half stays in secure storage on the handset.

**No BMI is computed anywhere**, asserted. The spec forbids it directly and invariant 6 forbids the
class of thing. Height and weight are stored and never combined. The bounds on them are sanity
checks for a slipped decimal point, not clinical thresholds, and a value inside them is not a
judgement about anybody.

`DeviceMeasurements` is injectable on `ProcessingScreen` so the submission path and its error
handling can be tested without a camera; everything downstream of that seam is the real path.

## Wiring the flow to the new endpoints (PM spec 17, 24, 28, 30, 36)

**The PHR posts to `/v1/profile`, local copy first.** Onboarding has to work on a bad connection,
and a form that will not advance because a request failed strands a patient at step one of three.
Each screen sends only the fields it collected: the endpoint treats an absent field as "unchanged",
so sending the whole profile from a screen that filled half of it would push nulls over the rest.

**CTX-01 moved from `/v1/events` to `/v1/check-sessions/{id}/context`**, which is a typed table with
closed symptom codes and lets the backend tell a context record from a reported symptom without
inspecting a payload.

That changed *when* it is filed. The route needs a session id and the session does not exist until
the check is submitted, so the context now rides in the flow's payload and is filed by processing.
The cost is that a capture that never completes loses its context; the gain is that the context
that survives is typed and attached to the thing it describes.

**BP-only still uses the event fallback**, because a confirmed cuff reading is not a
`measurement_session` and there is no id to attach to. **This is a gap, not a design** — the two
modes should file context the same way once a BP-only check gets a session of its own.

### Hardware failure is a position problem, not an error

`DeviceMeasurementFailure` no longer falls into the generic error panel. It routes through
`CheckFlow.afterSensorCapture` as a retryable reject, which means SIG-02 with a "Try again" and the
**same attempt counter as a rejected capture** — so three failures end at SIG-03 rather than
looping. A patient whose phone could not be measured can act on that by repositioning; a patient
staring at a stack trace cannot.

**BP-only never touches the hardware.** Processing returns before any measurement is attempted,
which is what keeps a not-eligible handset off the camera path entirely rather than relying on it
to fail gracefully.

### The insight screen composes no copy

`InsightScreen` lays out what the backend returns and writes no sentences of its own. Composing
copy on the handset would put a second, unreviewed voice in front of a patient, and it would drift
from the server's the moment either changed. Codes come from the rule engine, sentences from
`language.py`, layout from here.

## The check session is opened at the start, and the event fallback is gone

`POST /v1/check-sessions` is called before the first screen that collects anything, in **both**
modes. That is what PRE-01 and CTX-01 attach to: a sensor capture does not exist until capture is
over, and for a BP-only check it never exists at all.

Consequences worth naming:

- **CTX-01's episode-scoped event fallback is deleted.** There is always somewhere typed to put it
  now, so the two modes file context the same way. The gap recorded in the previous entry is
  closed.
- **The insight is fetched against the check session, not the capture.** A BP-only check has the
  first and never the second, which is why its insight screen used to say "did not produce a
  result".

**Opening throws; everything after it swallows.** `CheckSessionClient.open` is the one call in this
flow that does not degrade quietly, because everything downstream attaches to the id it returns — a
flow that continued without one would collect PRE-01 and CTX-01 into nothing, which is the exact
failure this change exists to remove. `submitPreconditions` does swallow: the readiness decision has
already been made locally and the flow has already branched on it, so losing the upload loses a
record rather than a gate.

**`is_ready` is not sent.** The server derives it from the five answers, so the handset cannot
declare itself ready while reporting a confounder. Asserted.

If opening fails — most often the contraindication gate now refusing at the door — the flow still
runs and the answers are still collected locally. They simply have nothing to attach to, and
processing reports that rather than pretending otherwise.

## The auth screens are built, and sign-in now navigates

The sign-up route had been a `FlowStubScreen` reading "Self-registration posts to
/v1/auth/register-patient" — a sentence describing a feature instead of the feature. It is now a
real form, and the sign-in screen it pairs with was finished at the same time. The "bare-bones UI"
convention is lifted for these two screens only: they are the first thing anyone sees.

**Sign-in used to authenticate and then stay put.** `AuthController` notifies on sign-*out* and
`main.dart` listens for it to unwind to login; the successful direction had no counterpart, so
tapping Login stored tokens, set `signedIn`, and left the patient looking at the same form. Both
screens now navigate, and neither decides where to: they call `TeraFlow.resumeRouteAfterAuth`,
which reloads the stored flow state and returns `AppFlowState.resumeRoute` — AUTH-00's table, the
same one the splash uses. Three callers, one routing table.

**Sign-up signs the patient in.** `/v1/auth/register-patient` returns tokens with the account, and
its own docstring says why: bouncing someone to a login form for credentials they typed thirty
seconds ago is a round trip that exists only to make the app feel like a clinic system.

### The name is collected and never transmitted

The form asks for a name because a product that greets you by an email address is not a consumer
product. The request body carries `subject` and `password` and nothing else, asserted in two tests
— one at the client, one through the screen.

There is nowhere to send it. The endpoint generates `TERA-<hex>` as the pseudonym and its docstring
records the reason: BUILD_SPEC 4.1 has no name field, and deriving one from the sign-up details
would put an identity into a clinical record sideways. So the name lives in `PhrProfile.displayName`
on the handset, behind the same Keystore as the tokens, and `PhrSubmitter.patchFor` is a per-section
allow-list that cannot carry it to `/v1/profile` by accident.

It is used: Home greeted "Good Morning, Sir Arif" from a string literal, with a hardcoded 'A' in the
avatar. Both now come from the profile, and the greeting follows the clock — a constant "Good
Morning" is wrong for two thirds of the day, and the exhibition is in the afternoon.

### A new account does not inherit the handset's setup

`TeraFlow.beginNewAccount` resets the onboarding step and the BP reference and **keeps** the device
eligibility. Onboarding answers belong to the account; the torch and the accelerometer belong to the
phone. Without this, registering a second account on a handset whose first account had finished
onboarding would land the new patient on Home, looking at a record built from someone else's
answers.

### The local writes cannot fail or stall the sign-up

By the time they run, the account exists on the server. A Keystore write that throws or wedges must
not leave a patient watching a spinner in front of an account that has already been created — there
is no way on except killing the app, and the second attempt answers 409. So the pair is wrapped in
one five-second budget and swallowed, with the flow-state write first because it is the one with
routing consequences. The name is a greeting.

### Validation duplicates the backend's bounds on purpose

`minPasswordLength = 12` and `maxPasswordBytes = 72` mirror `MIN_PASSWORD_LENGTH` and bcrypt's
limit. The form has to state the rule before the request is made, and a client that guesses shorter
turns a field error into a 422 whose `detail` is a list of field objects — a JSON dump in front of a
patient. 409, 422 and 429 each map to a sentence instead; 429 is reachable, at five sign-ups per
address per hour.

Sign-in validates presence only. An account created before a minimum changed still has to be able
to get in.

### Two colour notes

The sign-in button carried a raw `0xFF001F3F` with a `// Navy blue` comment — a navy that was not a
token and therefore not in the palette. The auth primary action is `TeraColors.ink`, Deep Space
Blue, which is the palette's navy and measures 13.57:1 against paper. Failures use the system-flag
treatment, because a refused request is something the *system* did; the snack bar is ink rather than
plum, since a full-bleed plum bar reads as an alarm and this app does not raise those.

**"Continue with Google" is gone.** It was an `onPressed: () {}` — there is no OAuth provider on the
backend and no plan for one. A dead button on the first screen is worse than no button, and it is
the kind of thing a judge taps first.

### Testing note: the Keystore hangs, it does not throw

Inside the fake-async zone a `testWidgets` body runs in, a real platform-channel call never gets an
answer — the request goes to an engine that is not there and the `await` never completes. It does
not throw, so no `catch` helps. `auth_flow_test.dart` installs an in-memory mock handler on
`plugins.it_nomads.com/flutter_secure_storage` so the router's real `SecurePhrProfileStore` is what
the tests exercise. Landing on DEV-01 also rules out `pumpAndSettle`: its probe indicator never
stops spinning, so those tests pump a bounded number of frames instead.
