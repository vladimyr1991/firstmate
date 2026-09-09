# Voice input for Herdr agent panes

Hold one key chord, speak, release: a local whisper.cpp transcription is typed into the composer of the focused Herdr agent pane, and you press Enter.
Nothing is recorded while the chord is not held, no audio leaves the machine, and no audio file outlives its transcription.
The feature is off until you create `config/voice`; a home without that file behaves exactly as before, and nothing is installed, downloaded, or started on its behalf.
`bin/fm-voice.sh --help` is the single owner of the configuration keys, subcommands, exit codes, and the exact safety mechanics; this guide covers what you see and decide as the operator.
[configuration.md](configuration.md) "Voice input (config/voice)" owns where the feature sits among the home's other opt-in files and what session start reports while it is enabled.

## Enabling it

1. Create `config/voice` in the firstmate home; an empty file enables the defaults (`ctrl+alt+space`, Russian, the quantized large-v3-turbo weights).
2. Run `bin/fm-voice.sh doctor`; it names each missing piece with its install step, and the session-start digest relays the same lines while the file exists.
3. Install whisper.cpp with `brew install whisper-cpp`, or approve it when session start offers the install.
   The Homebrew bottle is required; on an older macOS where Homebrew compiles from source, `xcode-select --install` is the first fix when the build fails.
4. Run `bin/fm-voice.sh install-model` to download the weights (about 574 MB, checksum-verified before use); `--full` fetches the full-precision file (about 1.6 GB) instead.
   Every download prints its URL, size, and destination and waits for a typed `yes`.
5. Run `bin/fm-voice.sh build` once to compile the small daemon with the Command Line Tools `swiftc` (about a minute).
6. Run `bin/fm-voice.sh start` in any Herdr pane and leave it in the foreground there; it prints `ready: hold ctrl+alt+space to talk`.
   Automatic start at session start is a deliberate follow-up, not part of this version: something that listens to the microphone is started by you, on purpose.

## What the first run shows

macOS attributes microphone use to the terminal app hosting Herdr, not to firstmate.
If that app has never been asked, the standard microphone dialog appears at `start`, never on the first key press; denying it exits with a hint naming System Settings > Privacy & Security > Microphone.
No Accessibility or Input Monitoring grant is requested: the chord is observed through a plain global hot key, which is also why it must be a modifier plus a key.
A bare modifier, or the Fn/Globe key, would need Input Monitoring and is refused rather than approximated.

## Using it

- Focus an agent pane, hold the chord, speak, release.
  You hear a short cue on press and on release, the daemon pane prints `recording` then `transcribing (N.N s)`, and macOS shows its orange microphone indicator only while the chord is held.
- Within a few seconds the text appears in that pane's composer.
  Read it, fix a word if the model misheard one, and press Enter yourself.
  The transcript is never submitted for you: a wrong phrase sent to a working agent costs its turn, while an extra keystroke costs nothing.
- Pause briefly between separate items in a long request.
  Whisper decodes in 30-second windows, and a sentence that straddles a window boundary with no pause can be dropped or garbled; the composer shows you the result before anything is sent.
- Recording stops on its own at the configured cap (120 s by default) and proceeds as a release.

## When nothing is typed

- The focused pane is not an agent pane, the agent is waiting on an approval or question dialog, its state is unknown, or no single pane is focused: the daemon pane says why, the transcript is copied to the clipboard, and nothing is typed anywhere.
  Another pane is never picked for you.
- Silence, a press shorter than half a second, or a recording below the level threshold: `nothing heard`, and whisper does not run.
  Whisper invents text on silence, so a level gate runs before it and a short list of its known silence phrases is checked after it.
  That list is compared only against the whole transcript; it never removes a phrase from something you actually said.
- A second press while a transcription is still running is ignored with a `busy` cue.
- `bin/fm-voice.sh stop` ends the daemon; `bin/fm-voice.sh status` reports `off`, `not ready`, `ready`, or `running`.

## Privacy

- Audio is written only under your per-user temporary directory, in a fresh directory readable by you alone, and deleted as soon as the transcription finishes, on every path including a killed transcription; the daemon also removes any leftover on start and exit.
  Nothing is ever written under `data/`, `state/`, `projects/`, or the repository, and no audio path is printed.
- Transcription runs locally; the model has no network access.
  The only network use is the one-time model download.
- A refused delivery leaves the transcript on the clipboard until you copy something else.
- `config/voice` is per machine and is not inherited by second mates; a second mate never runs the daemon.

## Turning it off

Run `bin/fm-voice.sh stop` first, then delete `config/voice`; the home is immediately back to its pre-voice behavior.
The order matters: once `config/voice` is gone every subcommand including `stop` exits 2, so a daemon still running would keep the hot key.
The compiled daemon and the downloaded weights stay under `~/.cache/firstmate/voice/` (or `$XDG_CACHE_HOME/firstmate/voice/`); remove that directory to reclaim the space.

## Known limits and follow-ups

- Hot-key delivery is verified on the operator's own machine, not by automated tests: run `start`, hold the chord for two seconds while another app is frontmost, and confirm the `recording` and `transcribing` lines appear.
  If they do not, the hold-to-talk design cannot work on that setup, and a Herdr key binding that toggles recording is the documented alternative.
- Secure Input (a password field in front) can keep the chord from being delivered.
- Two Herdr sessions are not supported; the CLI addresses the default socket only.
- Follow-ups, deliberately not in this version: starting the daemon under session-start supervision, a resident whisper server to save the per-utterance model load, and a direct-submit option.
