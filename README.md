# Compounder

**A life assistant that does the work, not just the tracking.** Tell it what you ate and it drafts
the meal entry. Say "starting push day" and it creates the workout and adds your sets. Ask how your
training and your mood have actually been trending and it answers from your own data — health,
wealth and mind in one app, for **Android and iOS**.

Every change stays yours to approve: the coach says what it is about to write, then waits for your
OK. Compounder grew out of [OpenFit](https://github.com/barrydeen/openfit) (lifting + macro
tracking) and expands it into one place for every area of life you want to get 1% better at.

## The four domains

### Health (from OpenFit)
- **Lifting tracker** — 300+ exercise catalog grouped by muscle group, workout sessions with
  weight/reps/warm-up set logging, rest timer, last-session placeholder seeding, most-used-first
  picker, custom exercises, e1RM (Epley) progress charts, workout summaries and history.
- **Nutrition tracker** — snap a meal photo, your vision-capable AI endpoint drafts the macros,
  you review and edit before anything is saved. Daily goal dashboard, meal history and gallery.
- **Google Health Connect (Android)** — optional, read-only import of sleep, heart rate, HRV,
  steps, distance, calories, workouts, body measurements and vitals. The coach can query all of it
  through dedicated health tools. Health Connect data stays on-device; full-history access and
  per-category permissions are user-controlled.

### Wealth
- Track accounts, assets and debts (Cash, Bank, Brokerage, Retirement, Crypto, Property, Debt).
- Live net-worth, asset and liability totals on your device. Balances are simple point-in-time
  snapshots — update them whenever you like.

### Mind
- **Mood check-ins** on a 1–5 scale with notes, check-in streak and 7-day average.
- **Meditation timer** with 3/5/10/20-minute sessions, logged on completion.
- **Thought records** — a simple CBT-style tool: the situation, the thought, a kinder/true reframe.

### Coach (bring your own AI)
- A tool-calling agent that answers questions about **all four domains** with real fetched data:
  `getWorkouts`, `getNutrition`, `getExerciseProgress`, `getNetWorth`, `getMindLog`, and write
  tools (`logMeal`, `logMood`, `startWorkout`, `addSet`) it will confirm before using.
- Works with any OpenAI-compatible endpoint you configure (Ollama, llama.cpp, LM Studio,
  LiteLLM, OpenRouter, …).
- **Setup today:** the coach needs a base URL, API key and model name entered in Settings — it is
  wired to whatever endpoint you point it at, not to a service of ours. A hosted option that works
  out of the box is planned; until then, expect to bring a key.
- Optional **daily digest notification** across workouts, meals, money and mood, scheduled
  entirely on-device (no push servers, no Google services).

## Trust and privacy

- **No accounts, no ads, no trackers.** There is nothing to sign up for, and no server of ours
  stores your life data.
- **Your data is yours to take.** Everything lives in a local SQLite database on your device, and
  you can export/import a single backup JSON file whenever you want.
- **Local-only storage** (SQLite via `sqflite` + `shared_preferences`). Health Connect is read
  on-device with Google's local API; no Google account or cloud sync is involved.
- **Two network destinations, both explicit.** (1) The AI endpoint *you* configure — meal photos
  and conversation data go only there. (2) `gateway.arcanegrowth.com`, used only for the optional
  Compounder AI subscription: device registration, purchase verification, entitlement and usage.
  The gateway never receives your database — only the coach conversation you send to Compounder AI
  (including any summarized health data you asked about) and entitlement metadata.
- **Health data is opt-in.** When you ask the coach about sleep, heart rate or recovery, summarized
  health data is sent to the AI endpoint in use — your own endpoint, or the gateway if you are on
  Compounder AI. Raw records stay in the local database and can be deleted from Settings.
- MIT-licensed, auditable Flutter source: the network surface is `lib/llm/llm.dart` (chat + vision),
  `lib/llm/routing.dart` (which endpoint is used) and `lib/subscription/gateway.dart` (subscription
  endpoints).

## Getting started

### Prerequisites

- Flutter stable (3.35+ — developed on 3.47)
- Android SDK for Android builds; Xcode on macOS for iOS builds

### Build

```bash
flutter pub get
flutter analyze
# The DST regression guards assert on ambient-zone transitions and fail loudly
# rather than passing vacuously when the runner has none. Pin the zone:
TZ=America/New_York flutter test

# Android (release APK lands in build/app/outputs/flutter-apk/)
flutter build apk --release

# iOS (run on a Mac)
flutter build ios --release
```

For signed release builds put a `android/key.properties`
(`storeFile/storePassword/keyAlias/keyPassword`) in place — it is gitignored.

Optionally bake a default AI endpoint into debug builds:

```bash
flutter run --dart-define=LLM_BASE_URL=http://192.168.0.117:4000/v1 \
            --dart-define=LLM_API_KEY=... --dart-define=LLM_MODEL=...
```

(Settings in the app always win over the compiled defaults.)

## Architecture

- **State** — one `AppStore` (`ChangeNotifier`) owns the database, cached lists and settings;
  screens read it via `provider`.
- **Data** — single `compounder.db` (exercises, workouts, sets, meals, accounts, moods,
  meditations, thought records).
- **AI** — `llm/llm.dart` (OpenAI-compatible chat + tool calling + vision meal analysis),
  `coach/agent.dart` (tool loop), `coach/tools.dart` (24 tools across all domains).
- **Domain** — pure, unit-tested math in `domain/domain.dart` (e1RM, units, wealth, mind streaks).
- **Services** — JSON backup export/import, on-device daily-notification scheduling.

```
lib/
├── main.dart            app bootstrap + theme (sage seed palette)
├── seeder.dart          exercise catalog seeding (assets/exercises.json)
├── domain/domain.dart   testable pure logic
├── data/                models + AppStore (sqflite + shared_preferences)
├── llm/                 BYO-AI chat, tool specs, vision meal drafts
├── coach/               agent tool loop + health/wealth/mind tools
├── health/              Health Connect categories, sync, analysis and local repository
├── services/            backup (JSON) + daily coach notifications
├── subscription/        Compounder AI subscription: store, gateway, entitlement
└── ui/                  shell (bottom bar: Home, Fitness, Macros, Wealth, Coach;
                          Mind is drawer-only), home, workout, picker, summary,
                          history, progress, macros, wealth, mind, coach chat,
                          settings, widgets
```

## License

MIT
