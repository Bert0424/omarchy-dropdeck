import QtQuick
import Quickshell
import Quickshell.Io

// Headless Dropdeck brain: pad assignments, playback, and the
// PipeWire "stream mode" toggle. Loaded once at shell startup (kind
// "service"), independent of whether the bar dropdown or the tile is
// open, so pad state and stream-mode status stay put either way.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Best-effort: if this service is torn down (shell quit, plugin reload, or
  // `omarchy plugin remove`) while stream mode is up, take the virtual-mic
  // graph down with it rather than leaving orphaned PipeWire modules. Detached
  // so it outlives us. (The modules are runtime-only and also clear on the
  // next PipeWire restart, so this is a tidy-up, not the only safety net.)
  Component.onDestruction: {
    if (streamModeOn)
      Quickshell.execDetached(["bash", streamScript, "off"])
  }

  readonly property int padCount: 16

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string padsPath: stateDir + "/dropdeck-pads.json"

  // pw-play wants a filesystem path, not a file:// URL.
  function localPath(relativeOrUrl) {
    var url = Qt.resolvedUrl(relativeOrUrl).toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  readonly property string streamScript: localPath("scripts/stream-mode.sh")
  readonly property string padsSinkName: "dropdeck_pads"

  function defaultPad(i) {
    return { path: "", label: "Pad " + (i + 1) }
  }

  // Any label that ends up on screen (pad names, device descriptions) goes
  // through here first: strip characters that a Text element could treat as
  // markup or that break layout, collapse whitespace, and clamp the length.
  // Belt-and-braces with textFormat: PlainText on the Text elements.
  function sanitizeLabel(s) {
    var t = String(s === undefined || s === null ? "" : s)
    t = t.replace(/[\x00-\x1f\x7f]/g, " ").replace(/[<>]/g, "").replace(/\s+/g, " ").trim()
    return t.length > maxLabelChars ? t.slice(0, maxLabelChars) : t
  }
  function defaultPads() {
    var out = []
    for (var i = 0; i < padCount; i++) out.push(defaultPad(i))
    return out
  }

  property var pads: defaultPads()
  // Mirrors each player Process's running state, index-aligned with pads.
  // Rebuilt wholesale (never mutated in place) so bindings that read it react.
  property var playing: new Array(padCount).fill(false)
  // Set right before we deliberately kill a pad's process, so its onExited
  // handler can tell "we stopped it" apart from "pw-play couldn't open the
  // file" and only notify on the latter.
  property var expectedStop: new Array(padCount).fill(false)

  property real masterVolume: 1.0
  // streamModeOn  — the real PipeWire state, from `stream-mode.sh status`.
  // streamModeDesired — what the user last asked for. The switch binds to this
  //   so the knob throws the instant it's clicked instead of waiting ~1s for
  //   the script; it's reconciled back to streamModeOn once the script returns
  //   and by the background poller, so an external change (another shell, a
  //   crash, toggling from a terminal) heals on its own without a manual flip.
  property bool streamModeOn: false
  property bool streamModeDesired: false
  property bool streamModeBusy: false

  // Which real mic feeds the stream mix. "" means "whatever's the system
  // default when stream mode is switched on". A specific PipeWire source name
  // pins that mic regardless of the system default — the point of this is a
  // USB mic for streaming while the laptop mic stays the default for calls.
  property string micSource: ""
  // [{ value: <pipewire source name>, label: <human description> }], the real
  // (non-monitor, non-virtual) input devices, refreshed by refreshInputSources().
  property var inputSources: []

  property bool initialized: false
  property bool padsFileLoaded: false
  property string loadedPadsText: ""
  // Bounded read, same reasoning as every other plugin's state file: a huge
  // or symlinked file can never be pulled whole into the shell, and anything
  // hitting the cap is treated as corrupt rather than silently truncated.
  readonly property int maxStateBytes: 65536
  // Cap on the `pactl list sources` JSON we'll pull in — plenty for a real
  // device list, small enough that a pathological graph can't balloon memory.
  readonly property int maxSourcesBytes: 262144
  // A pad label / device description longer than this, or one carrying markup
  // or control characters, is clamped before it ever reaches a Text element.
  readonly property int maxLabelChars: 96

  function setPlaying(i, value) {
    var next = playing.slice()
    next[i] = value
    playing = next
  }

  function padAt(i) {
    return (i >= 0 && i < pads.length && pads[i]) ? pads[i] : defaultPad(i)
  }

  function play(i) {
    if (i < 0 || i >= padCount) return
    var pad = padAt(i)
    if (!pad.path) return
    var proc = players.objectAt(i)
    if (!proc) return
    // Click again while it's already going: stop it, like any soundboard pad.
    if (proc.running) {
      proc.running = false
      return
    }
    var cmd = ["pw-play", "--volume", root.masterVolume.toFixed(2)]
    if (root.streamModeOn) {
      cmd.push("--target")
      cmd.push(root.padsSinkName)
    }
    // "--" so a pad path can never be read as a pw-play option, even if the
    // state file was hand-edited to a value starting with "-".
    cmd.push("--")
    cmd.push(pad.path)
    setExpectedStop(i, false)
    proc.command = cmd
    proc.running = true
  }

  function setExpectedStop(i, value) {
    var next = expectedStop.slice()
    next[i] = value
    expectedStop = next
  }

  function stop(i) {
    var proc = players.objectAt(i)
    if (proc && proc.running) {
      setExpectedStop(i, true)
      proc.running = false
    }
  }

  function playFailed(i, exitCode) {
    if (exitCode === 0 || expectedStop[i]) return
    var pad = padAt(i)
    notify("Dropdeck", "Couldn't play “" + pad.label + "” — check the file still exists and is a supported format (wav/mp3/ogg/opus/flac).")
  }

  function stopAll() {
    for (var i = 0; i < padCount; i++) stop(i)
  }

  function assign(i, path) {
    if (i < 0 || i >= padCount || !path) return
    var next = pads.slice()
    var current = padAt(i)
    var label = current.label
    if (!label || label === defaultPad(i).label) {
      var base = path.split("/").pop().replace(/\.[^./]+$/, "")
      if (base) label = base
    }
    next[i] = { path: path, label: sanitizeLabel(label) || defaultPad(i).label }
    pads = next
    flushPads()
  }

  function setLabel(i, label) {
    if (i < 0 || i >= padCount) return
    var next = pads.slice()
    var current = padAt(i)
    next[i] = { path: current.path, label: sanitizeLabel(label) || defaultPad(i).label }
    pads = next
    flushPads()
  }

  function clearPad(i) {
    if (i < 0 || i >= padCount) return
    stop(i)
    var next = pads.slice()
    next[i] = defaultPad(i)
    pads = next
    flushPads()
  }

  function setMasterVolume(v) {
    masterVolume = Math.max(0, Math.min(1, v))
  }

  function toggleStreamMode() {
    if (streamModeBusy) return
    streamModeBusy = true
    streamModeDesired = !streamModeOn
    var cmd = ["bash", root.streamScript, streamModeDesired ? "on" : "off"]
    if (streamModeDesired && micSource) cmd.push(micSource)
    streamToggleProc.command = cmd
    streamToggleProc.running = true
  }

  // Change which mic feeds the mix. Persists the choice and, if stream mode is
  // already live, rebuilds the graph in place ("restart") so the new mic takes
  // over without a visible off/on flicker on the switch.
  function setMicSource(name) {
    var next = (name === undefined || name === null) ? "" : String(name)
    if (next === micSource) return
    micSource = next
    flushPads()
    rebuildStreamMode()
  }

  // Re-read the real state from PipeWire and fold it back into both the
  // authoritative flag and the switch's optimistic one. Skipped while a
  // toggle is in flight so the poll never fights the knob mid-throw.
  function refreshStreamMode() {
    if (streamModeBusy || streamStatusProc.running) return
    streamStatusProc.running = true
  }

  // Enumerate real input devices for the mic picker. Cheap; the poller runs it
  // so a freshly plugged-in USB mic shows up within a few seconds.
  function refreshInputSources() {
    if (!sourcesProc.running) sourcesProc.running = true
  }

  function parseInputSources(txt) {
    if (!txt || txt.length >= maxSourcesBytes) return  // truncated/oversized: keep the current list
    try {
      var arr = JSON.parse(txt)
      if (!Array.isArray(arr)) return
      var out = []
      for (var i = 0; i < arr.length && out.length < 64; i++) {
        var s = arr[i]
        var cls = (s.properties && s.properties["media.class"]) || ""
        var mon = s.monitor_source
        var isMonitor = mon !== undefined && mon !== null && mon !== "" && mon !== "n/a"
        if (cls === "Audio/Source" && !isMonitor && String(s.name).indexOf("omarchy_") !== 0)
          out.push({ value: String(s.name), label: sanitizeLabel(s.description || s.name) })
      }
      inputSources = out
    } catch (error) {
      console.warn("bert.dropdeck: source list parse failed (" + error + ")")
    }
  }

  function notify(title, body) {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "dropdeck",
      "-u", "normal",
      title,
      body
    ])
  }

  // --- playback processes, one per pad so retriggering a pad only stops
  // that pad and "stop all" can hit every pad without guessing PIDs. ------
  Instantiator {
    id: players
    model: root.padCount
    delegate: Process {
      id: proc
      required property int index
      onRunningChanged: root.setPlaying(index, running)
      onExited: function(exitCode) { root.playFailed(index, exitCode) }
    }
  }

  // --- stream mode processes ----------------------------------------------
  Process {
    id: streamStatusProc
    command: ["bash", root.streamScript, "status"]
    stdout: StdioCollector {
      id: streamStatusOut
      waitForEnd: true
      onStreamFinished: {
        if (root.streamModeBusy) return
        root.streamModeOn = streamStatusOut.text.trim() === "on"
        root.streamModeDesired = root.streamModeOn
        // First reading after load: if stream mode is already up (it survives
        // a shell restart) but a mic is pinned, the running graph may still be
        // on whatever was default when it was built. Rebuild once so it honors
        // the saved choice.
        if (!root.streamStatusChecked) {
          root.streamStatusChecked = true
          if (root.streamModeOn && root.micSource !== "")
            root.rebuildStreamMode()
        }
      }
    }
  }
  property bool streamStatusChecked: false

  function rebuildStreamMode() {
    if (!streamModeOn || streamModeBusy) return
    streamModeBusy = true
    var cmd = ["bash", root.streamScript, "restart"]
    if (micSource) cmd.push(micSource)
    streamToggleProc.command = cmd
    streamToggleProc.running = true
  }

  // Enumerates real input devices (pactl -f json). Feeds the mic picker.
  // `timeout` guards against a wedged pactl; `head -c` caps the JSON we'll
  // ever pull into the shell (a truncated blob just fails JSON.parse and the
  // old list is kept).
  Process {
    id: sourcesProc
    command: ["bash", "-c",
      'exec timeout 5 pactl -f json list sources | head -c "$1"',
      "dropdeck", String(root.maxSourcesBytes)]
    stdout: StdioCollector {
      id: sourcesOut
      waitForEnd: true
      onStreamFinished: root.parseInputSources(sourcesOut.text)
    }
  }

  // Keeps the switch honest: if stream mode gets turned on or off outside
  // this surface, the knob catches up within one interval instead of lying
  // until the next manual toggle. Also refreshes the mic list so a
  // hot-plugged USB mic appears in the picker without any manual poke.
  Timer {
    id: streamStatusPoll
    interval: 4000
    repeat: true
    running: root.initialized
    onTriggered: {
      root.refreshStreamMode()
      root.refreshInputSources()
    }
  }

  Process {
    id: streamToggleProc
    stdout: StdioCollector {
      id: streamToggleOut
      waitForEnd: true
      onStreamFinished: {
        var result = streamToggleOut.text.trim()
        root.streamModeOn = result === "on"
        root.streamModeDesired = root.streamModeOn
        root.streamModeBusy = false
        root.notify("Dropdeck", root.streamModeOn
          ? "Stream mode on — pick “Dropdeck-Mic” as your mic in Restream."
          : "Stream mode off.")
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.streamModeBusy = false
        root.streamModeDesired = root.streamModeOn
        root.notify("Dropdeck", "Couldn't switch stream mode — check PipeWire (pactl).")
      }
    }
  }

  // --- persistence ---------------------------------------------------------
  function boundedText(collector, exitCode) {
    if (exitCode !== 0) return ""
    var text = collector.text
    return text.length >= maxStateBytes ? "" : text
  }

  Process {
    id: padsReader
    // Refuse to read anything that isn't a plain regular file: a symlink could
    // redirect the read, and a FIFO in its place would block the reader
    // forever. `timeout` is a backstop for a wedged filesystem. Output is
    // still byte-capped (see boundedText).
    command: ["bash", "-c",
      'p=$1; n=$2; [ -f "$p" ] && [ ! -L "$p" ] || exit 0; exec timeout 5 head -c "$n" -- "$p"',
      "dropdeck", root.padsPath, String(root.maxStateBytes)]
    running: true
    stdout: StdioCollector { id: padsOut }
    onExited: function(exitCode) {
      root.loadedPadsText = root.boundedText(padsOut, exitCode)
      root.padsFileLoaded = true
      root.initializeIfReady()
    }
  }

  FileView {
    id: padsFile
    path: root.padsPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  function flushPads() {
    padsFile.setText(JSON.stringify({ pads: root.pads, masterVolume: root.masterVolume, micSource: root.micSource }, null, 2) + "\n")
  }

  function initializeIfReady() {
    if (initialized || !padsFileLoaded) return
    try {
      var parsed = loadedPadsText !== "" ? JSON.parse(loadedPadsText) : {}
      if (Array.isArray(parsed.pads)) {
        var loaded = []
        for (var i = 0; i < padCount; i++) {
          var p = parsed.pads[i]
          loaded.push(p && typeof p.path === "string"
            ? { path: p.path, label: (typeof p.label === "string" && sanitizeLabel(p.label)) || defaultPad(i).label }
            : defaultPad(i))
        }
        pads = loaded
      }
      if (typeof parsed.masterVolume === "number" && isFinite(parsed.masterVolume))
        masterVolume = Math.max(0, Math.min(1, parsed.masterVolume))
      if (typeof parsed.micSource === "string")
        micSource = parsed.micSource
    } catch (error) {
      console.warn("bert.dropdeck: pads file unreadable (" + error + "), using defaults")
    }
    initialized = true
    streamStatusProc.running = true
    refreshInputSources()
  }
}
