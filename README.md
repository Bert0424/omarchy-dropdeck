# Dropdeck

A 16-pad soundboard for live streams and podcasts on [Omarchy](https://omarchy.org),
with a one-toggle virtual mic that mixes your pads into your voice for
**Restream Studio** or **OBS**.

- **Dropdown** — click the 🔊 pill in the bar for a compact grid.
- **Tile** — a real floating/tileable window you can keep pinned on screen
  while recording:
  ```
  omarchy-shell shell summon bert.dropdeck '{}'
  ```
  (`omarchy-shell shell hide bert.dropdeck` / `toggle` work the same way.
  Bind a key to the summon command if you want a hotkey for it.)

Both surfaces show the same 16 pads — assigning or clearing a sound in one
updates the other immediately.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` (the plugin system).
- PipeWire with the PulseAudio shim — `pw-play`, `pw-record`, `pactl`
  (all ship with `pipewire` / `pipewire-pulse`). Stream mode also uses
  `module-null-sink`, `module-loopback` and `module-remap-source`, which
  are part of a stock PipeWire install.
- `ffmpeg` only if you want to convert an unsupported clip (see below).

## Install

```bash
omarchy plugin add https://github.com/Bert0424/omarchy-dropdeck.git
omarchy plugin enable bert.dropdeck
```

`add` clones the repo into `~/.config/omarchy/plugins/bert.dropdeck/`; it
lands **disabled** so you can read the code first. `enable` puts the 🔊 pill
on the right side of the bar. Later:

```bash
omarchy plugin update bert.dropdeck   # fast-forward pull, shows a diff first
omarchy plugin remove bert.dropdeck
```

**Turn Stream mode off before you remove the plugin.** `omarchy plugin
remove` just deletes files — it can't run teardown — so removing while Stream
mode is live would strand the virtual-mic PipeWire modules until you restart
PipeWire or log out. The plugin tears them down on shell exit / reload as a
safety net, but toggling off first is the clean path.

> Like every Omarchy plugin, this runs as unsandboxed code inside
> `omarchy-shell`. Only add repos whose code you're willing to run.

## What it does to your system

Full disclosure, since it runs unsandboxed:

- **Runs** `pw-play` (pad playback), `pactl` (queries inputs; in Stream mode
  loads/unloads PipeWire modules), and `omarchy-notification-send` (errors).
  All are invoked as argument vectors, never through a shell.
- **Stream mode** loads `module-null-sink` ×2, `module-loopback` ×3 and one
  `module-remap-source`, and tears every one of them down again when you
  toggle Stream mode off (module ids are tracked in a state file for exact
  cleanup). Nothing is left behind.
- **Writes** exactly one file: `~/.local/state/omarchy/dropdeck-pads.json`
  (pad assignments + your mic choice). Stream mode also writes a scratch file
  of module ids in the same directory, removed on toggle-off.
- **No network access.** No telemetry. Never asks for elevated privileges or
  your password. Nothing written outside `~/.local/state/omarchy/`. Your audio
  files are only ever read, by `pw-play`.

## Assigning sounds

Click the pencil icon to enter edit mode, then click any pad to pick an
audio file. Click the pencil again to leave edit mode. In edit mode,
assigned pads show a small × to clear them.

Outside edit mode, clicking a pad plays it; clicking a pad that's already
playing stops it. "⏹" stops everything at once.

**Supported formats**: wav, mp3, ogg, opus, flac, aiff (playback is via
`pw-play`, which decodes these directly). **m4a/aac is not supported** —
it'll fail with a notification rather than play. Convert it once:
`ffmpeg -i clip.m4a clip.ogg`.

Recommended source files: short (1–4s) wav or mp3 clips work best — they
start instantly with no decode lag, which matters when you're hitting a pad
live mid-sentence. ogg/opus are fine too and smaller if you're hoarding a
big library. Normalize volume across clips if you can (e.g. `ffmpeg-normalize`
or just eyeballing peaks) so one pad doesn't blast louder than the rest.

Royalty-free libraries safe to use on a public stream (stingers, laugh
tracks, buzzers, airhorns):
- **Mixkit** (mixkit.co/free-sound-effects) — no attribution required
- **Pixabay** (pixabay.com/sound-effects) — no attribution required
- **Freesound.org** — huge, but check each clip's license
- **Zapsplat** — free with a (free) account
- **YouTube Audio Library** — has a sound-effects tab, cleared for streaming

Avoid clips ripped from TV/movies/games on a monetized or public stream —
that's what gets a VOD muted or a copyright strike.

## Getting the pads into Restream

Restream Studio (browser-based) only sees whatever audio device you hand it
as your "microphone" — it can't reach into PipeWire directly. Flip
**Stream mode** on before you go live and the plugin builds a real virtual
microphone that mixes your mic with the pads:

1. Pick the mic that feeds the mix. The tile has a **Mic** dropdown under the
   Stream mode switch — leave it on "System default mic" to follow whatever's
   default, or pin a specific device (e.g. your USB mic for streaming while
   the laptop mic stays default for calls). The choice is saved. Changing it
   while live rebuilds the mix in place; the plugin also re-applies it after a
   shell restart.
2. Toggle Stream mode on (in either the dropdown or the tile).
3. In Restream Studio's mic picker, choose **"Dropdeck-Mic"**. It's a
   normal-looking input device (not a "Monitor of…" entry — those are hidden
   by browsers, which is why a raw null-sink monitor won't show up).
4. You'll still hear your own pads locally through your normal speakers/
   headphones — that's a separate loopback, not a monitor of your mic.

Turn Stream mode off when you're done to tear the virtual devices back down.
If Restream doesn't show the new device right away, close and reopen its mic
dropdown (browsers cache the device list per permission grant).

### OBS

Same idea, and OBS is less fussy than a browser — it lists every PipeWire
source, monitors included. You still want **Stream mode on** (the pad sink
and the mix only exist while it is). Two ways:

- **One source, mixed:** add an *Audio Input Capture* on **Dropdeck-Mic**
  and you're done — mic + pads, same as Restream. Don't also add your raw mic
  as a separate source or your voice doubles.
- **Separate faders:** keep your existing OBS mic source (with whatever noise
  suppression / EQ you already run on it) and add a second *Audio Input
  Capture* on **Monitor of Dropdeck-Pads** for the pads alone — its own
  fader and filters. Ignore Dropdeck-Mic in this setup.

Either way, "Desktop Audio" in OBS should stay off, or you'll also capture
the local pad monitor and double the pads.

## Files

- `Service.qml` — pad state, playback, stream-mode control (kind `service`,
  loaded once at shell startup so it survives either surface being closed).
- `BarWidget.qml` / `BarPopup.qml` — the bar pill and its dropdown.
- `Tile.qml` — the standalone floating window (kind `panel`).
- `Board.qml` — the 4×4 grid + stream-mode card + mic picker, shared by
  both surfaces.
- `scripts/stream-mode.sh` — PipeWire setup/teardown: the `dropdeck_pads`
  sink pads play into, a `dropdeck_bus` mix sink fed by mic + pads, and a
  `module-remap-source` that re-publishes the mix as the `dropdeck_mic`
  microphone apps can pick. Graph diagram at the top of the file.

Pad assignments and the mic choice persist in
`${XDG_STATE_HOME:-~/.local/state}/omarchy/dropdeck-pads.json`.

## License

MIT — see [LICENSE](LICENSE).
