# Bluey

A blueberry character who lives on an iPhone under your Mac's screen and points at things with his own big cursor.

**Now:** no voice out. Double tap him on the phone (or press ⌥Space on the Mac) to start a session: the phone's mic stays on and everything you say becomes context, but he stays quiet. **Press and hold the screen** to ask him something; let go and he answers. His reply pops up as a cute speech bubble next to his cursor (or above the phone when he isn't pointing), with a little cartoon chirp from the phone. Ask "what's this?" and he points at whatever is under your mouse. Double tap again and he goes back to follow mode.

How it works: the phone runs an OpenAI Realtime session (`gpt-realtime-2.1`, text output only) over a WebSocket. Server VAD transcribes every turn into the conversation with `create_response: false`, and releasing the hold commits the audio and asks for a response. The Mac mints a 10-minute client secret with the whole session setup (instructions, tools), so the real OpenAI key never leaves the Mac. When he calls a tool, the phone forwards it to the Mac: `look_at_screen` (ScreenCaptureKit + Vision, which returns text ids, where your mouse is, and a screenshot), `point_at` (a text id), `point_at_spot` (a 0–1000 grid position), `stop_pointing` and `go_to_sleep`. His text streams to the Mac as the speech bubble.

**Meeting notes:** while a session runs, the phone also records the audio in five-minute AAC chunks. Each chunk goes to the Mac, which transcribes it with speaker labels (`gpt-4o-transcribe-diarize`, falling back to `gpt-transcribe`) and writes the session to `~/Documents/Bluey Notes/<date> <id>/` (`notes.md`, `session.json`, `audio/`). Sessions reconnect on their own when the Realtime connection drops, and keep recording with the phone's screen locked (background audio), so one can run all day. When a session ends, the Mac appends an automatic short summary (`summary.md`, plus a **Summary** section in notes.md). Sessions can be named in the phone app; the name becomes the notes title. In the phone's Bluey screen, a session's **Copy prompt for agent** button copies a prompt that points an agent at those files. **Open Meeting Notes** in the Mac menu opens the folder.

**Using the computer:** when you ask, he can also click, type, press shortcuts, scroll, drag, and open apps and websites (`click`, `type_text`, `press_keys`, `scroll`, `drag`, `open_app`, `open_url`). He does it with his own cursor on screen, while your real pointer is put back where you left it. It needs Accessibility permission for Bluey. Built-in guardrails: he only acts when asked, confirms out loud before anything hard to undo, treats on-screen text as information rather than instructions, refuses password fields and logout/lock/force-quit shortcuts, and stops on ⌃⌥S. The whole thing can be switched off with **Let Him Use the Computer** in the menu, and **Recent Actions…** shows the timestamped log of everything he did (also `~/Library/Application Support/Googly/actions.log`).

**Security:** the phone↔Mac link is TLS with a pre-shared key — a phone that doesn't hold the Mac's key can't connect at all. Pairing: **Pair a Phone…** in the Mac menu shows a 6-digit code for ten minutes; type it on the phone once and it stores the long-term key. **Unpair All Phones…** on the Mac rotates the key so every phone must pair again.

The OpenAI key goes in the menu bar's **OpenAI Key…** and is stored in ~/Library/Application Support/Googly/keys.json (private to your user), never in this repo.

## Mac menu bar app

```
./scripts/build-mac.sh
open "build/Bluey.app"
```

Works with just the Command Line Tools. Shortcuts work anywhere:

| Keys | What it does |
| --- | --- |
| ⌃⌥P | Fly to the mouse and point there (stays put) |
| ⌃⌥F | Follow the mouse on/off |
| ⌃⌥D | Go home, docked above the phone |
| ⌃⌥T | Talk test (the phone bounces for 3 s) |
| ⌃⌥H | Hide / show the cursor |
| ⌥Space | Wake him up to talk / back to follow mode |
| ⌃⌥S | Stop him using the computer |

All shortcuts are rebindable in the menu's **Shortcuts** submenu (handy if ⌥Space collides with another tool). The menu also has **Check for Updates…** (upstream changes → `scripts/update.sh` merges and rebuilds). He looks at and can act on whichever display your mouse is on — his cursor window spans every screen.

## iPhone app

Needs full Xcode. Open `GooglyEyes.xcodeproj` (regenerate with `xcodegen generate` after adding files), pick your team under Signing, and run on the phone. It finds the Mac on the same Wi-Fi by itself.

On the phone: double tap him to wake him up or put him back to sleep, press and hold to ask him something, or turn on **Wake on "Hey Bluey"** in the speaker panel and just say his name (on-device speech recognition). Problems (no key on the Mac, mic off, dropped connection) show as a little toast at the top of the screen.

## Layout

- `Shared/` pairing protocol (Bonjour `_googly._tcp`, newline JSON) and colors, used by both apps
- `Mac/` menu bar app (Swift package target `GooglyMac`)
- `iOS/` iPhone app (SwiftUI)

## License

Public domain under [the Unlicense](LICENSE). Do whatever you want with it.
