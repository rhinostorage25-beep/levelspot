# LevelSpot — build & run

Native iOS app (Swift/SwiftUI, iOS 17+) + Supabase backend. This tree was authored and
logic-verified on Windows; **compiling and running the app needs a Mac with Xcode** (16+;
building with the current SDK also gets Liquid Glass adoption for free per the platform
strategy doc).

## What's already verified vs. what isn't

**Verified (ran on this machine):**
- The levelling maths — corner derivation, ramp-step snapping, tolerance bands, the AL-KO
  track divergence — via a mirrored JavaScript harness running the exact vectors that are
  embedded in `LevelSpotCore/Tests`. 11/11 pass, including planarity and the
  standard-vs-AL-KO recommendation split (V8).
- The data pipeline: `scripts/gen-seed.js` (Node) generates both the Postgres seed and the
  app's bundled `vehicle_reference.json` from the researched CSVs in `../Data/`, with a
  guard that refuses presets pointing at unconfirmed track data.

**Not yet verified (needs the Mac steps below):**
- Swift compilation and the SwiftUI screens. The code is written conservatively against
  iOS 17 APIs, but nothing here has been through a compiler yet — expect a small round of
  fix-ups on first build, which is normal.

## Mac quickstart

```bash
brew install xcodegen
cd Code
xcodegen generate          # produces LevelSpot.xcodeproj from project.yml
open LevelSpot.xcodeproj   # select the LevelSpot scheme, pick a simulator, Run
```

Run the core test suite (this is the cross-platform contract — the Kotlin port must pass
the same vectors):

```bash
cd LevelSpotCore && swift test
```

No Mac to hand? `ci/ios-build.yml` is a ready GitHub Actions workflow that compiles the app
and runs the core tests on a macOS runner — push this tree to a GitHub repo and it verifies
every commit without local Apple hardware.

## Supabase setup (once)

1. Create a project at supabase.com (free tier fine to start; budget the Pro tier before
   real users — free pauses after inactivity).
2. SQL editor → run `supabase/migrations/001_schema.sql`, then `002_seed_reference.sql`.
3. Secrets for the reg lookup (Dashboard → Edge Functions → Secrets, or CLI):
   `MOT_CLIENT_ID`, `MOT_CLIENT_SECRET`, `MOT_TENANT_ID`, `MOT_API_KEY`
   — these are the DVSA MOT History API credentials. They must never appear in this repo,
   in Dropbox, or in the app. Reminder: the DVSA key **expires after 90 days of non-use**.
4. Deploy the function: `supabase functions deploy mot-lookup`.
5. Put the project URL + anon key into `LevelSpot/Services/SupabaseAPI.swift`
   (`SupabaseConfig`). Until then the app runs fully offline and the reg lookup shows its
   designed "occasionally unavailable" state.

## Regenerating reference data

Edit the CSVs in `../Data/`, then:

```bash
node scripts/gen-seed.js
```

Re-run the SQL seed in Supabase and rebuild the app (the JSON is bundled).

## Deliberate v1 boundaries (all flagged in-code)

- **Spare-device pairing is simulated** (labelled in the UI). Real BLE transport is build
  step 5, after the single-device flow proves out. GATT shape documented in
  `../platform-strategy-2026-07.md`.
- **Pro purchase is a local placeholder** — swap for StoreKit 2 + server receipt
  verification into `user_entitlements` before release. Server-side RLS already enforces
  the Pro data split regardless of what the client claims.
- **Cross-device sync not wired** (schema + RLS are live; `PitchRecord.synced` marks the
  upload queue). No account is needed for anything in v1, matching the brief.
- **Sun/view capture UI** isn't in the save flow yet — columns and gating exist end to end.
- Preset dimension fallbacks: T5 uses T6 figures, Transit Custom preset uses gen-2 figures
  (gen-1 track still TBC in `../Data/van_dimensions_README_v2.md`) — both surface the
  ESTIMATED tag, which is exactly what it exists for.
