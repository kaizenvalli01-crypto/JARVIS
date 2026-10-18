# J.A.R.V.I.S.

A voice assistant for **Windows** and **Android** built from one Flutter codebase.
It checks **email**, **weather** and the **time**. Those work offline, and Claude
in the cloud answers everything else.

## How it decides: offline or cloud

```
 you speak ──► speech-to-text (on-device) ──► intent router (regex, offline)
                                               │
          simple time / date / weather / email │   anything else
                    ▼                          ▼
             local skills ◄── tools ──── Claude (cloud, if key set + online)
                    │                          │  network down?
                    │                          └─► local skill or offline notice
                    ▼
             text-to-speech (on-device) ──► JARVIS speaks
```

| Feature | Online | Offline |
|---|---|---|
| Time / date | device clock | ✅ same |
| Weather | live from Open-Meteo (free, no key) | last cached result, with how old it is |
| Email | live IMAP: unread count, latest senders and subjects | last cached summary |
| "Is anything urgent in my inbox?", chit-chat, follow-ups | Claude with the skills as tools | polite "I'm offline" message listing what still works |
| Speech in/out | OS engines | ✅ Windows always; Android with the offline speech pack |

Each reply bubble is tagged **on-device**, **cloud**, or **offline**, so you can see which path answered.

## Setup

1. Install Flutter (3.35+) from https://docs.flutter.dev/get-started/install
2. `flutter pub get`
3. Build:
   * **Android:** `flutter build apk --release`. The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.
     Or plug in your phone and run `flutter run`.
   * **Windows:** you need Visual Studio 2022 with the "Desktop development with C++" workload.
     Run `flutter build windows --release`. The output is in `build/windows/x64/runner/Release/`.
4. Open ⚙ **Settings** in the app:
   * **Anthropic API key:** from https://console.anthropic.com. Without one, JARVIS runs offline-only.
   * **Home city:** used for weather.
   * **Email:** IMAP server, address, and an **app password**.
     * Gmail: `imap.gmail.com` / 993. Create an app password at Google Account → Security → 2-Step Verification → App passwords.
     * Outlook/Hotmail: `outlook.office365.com` / 993.
   * **Voice language:** for example `en-GB`, `en-US` or `en-IN`.

To make Android speech recognition work offline, go to Settings → Google → Voice → Offline speech recognition and download your language. Then turn on "On-device speech recognition only" in JARVIS.

## Try saying

* "What time is it?" / "What's the date?"
* "What's the weather?" / "Weather in Mumbai" / "Will it rain today?"
* "Check my email"
* "Is there anything urgent in my inbox, and do I need an umbrella?" (cloud)
* "Start over" resets the conversation. "Stop" interrupts JARVIS.

## Privacy

* API keys and the mail password are stored in the OS keystore (Android Keystore / Windows Credential Manager).
* Only headers (sender, subject, date) are read from email, never message bodies.
* Simple requests never leave the device. Email headers are sent to Claude only when a cloud request uses the `check_email` tool.

## Code map

```
lib/
  main.dart                  UI: arc-reactor mic button, transcript, text input
  screens/settings_screen.dart
  config/settings.dart       settings + secure storage
  brain/
    jarvis.dart              routing: local / cloud / offline fallback
    intent_router.dart       offline regex intents
    skills.dart              time, weather, email (+ Claude tool definitions)
    claude_client.dart       Claude Messages API client with tool loop
  services/
    speech_service.dart      speech_to_text + flutter_tts
    weather_service.dart     Open-Meteo + cache
    mail_service.dart        IMAP via enough_mail + cache
    cache.dart
test/jarvis_test.dart        router, skills, Claude tool loop, fallback routing
```

Run the tests with `flutter test`.

## Roadmap

1. Wake word ("Jarvis") using Porcupine on Android and openWakeWord on Windows
2. Global hotkey on Windows (for example Win+J) and an Android home-screen widget
3. Streaming replies so speech starts sooner
4. More skills: calendar, reminders, music, smart home

## Get the Windows .exe without installing anything

The project has a GitHub Actions workflow (`.github/workflows/build.yml`) that builds on GitHub's own Windows and Linux machines:

1. Create an empty repository on GitHub and upload this folder to it. You can drag and drop files on the website, or use GitHub Desktop.
2. Open the repository's **Actions** tab. The **Build JARVIS** workflow runs automatically, or you can click **Run workflow**.
3. When it finishes (about 10 minutes), open the run and download the artifacts:
   * **JARVIS-windows**: unzip it and double-click `JARVIS\JARVIS.exe`. Keep the DLLs and the `data` folder next to the exe.
   * **JARVIS-android**: `JARVIS.apk`, which you can install on your phone.
