#!/bin/bash
# Dropdeck stream mode: wires up a PipeWire "virtual mic" so the pads can be
# heard by streaming tools (Restream Studio, OBS, ...) mixed into your real
# mic. Restream never sees your PipeWire graph directly, so it needs one
# ordinary-looking input device that already has both signals mixed in.
#
# Graph built by `on`:
#
#   default (or pinned) mic ---------------\
#                                           >-> dropdeck_bus (null-sink)
#   dropdeck_pads (null-sink).monitor -----/        |
#         |                                         |  .monitor
#         |                            module-remap-source
#         |                                         |
#         |                                  dropdeck_mic  <-- pick THIS as your
#         |                                  (real Audio/Source)   mic in Restream/OBS
#         |
#         \-----------------------------> default sink
#                                         (so you still hear pads locally)
#
# Why the remap-source: a null-sink only exposes a ".monitor", which browsers
# (Chromium, so Restream Studio) deliberately hide from the mic picker. So we
# take the mixed bus and re-publish it through module-remap-source as a plain
# Audio/Source — "Dropdeck-Mic" — which every app, browsers included, lists
# like a normal microphone.
#
# The real mic is the one passed as $1 (the plugin's saved choice) if it
# exists, otherwise whatever's the system default when this runs. PipeWire
# won't hot-repoint a live loopback, so changing mics means an off/on (the
# plugin's `restart` does exactly that).
#
# Pad playback targets the dropdeck_pads sink only while this is "on" (see
# Service.qml); otherwise pads just play to the default sink.
#
# This script keeps NO state on disk. Every question is answered from
# PipeWire's own live module list: `status` checks whether our pad sink
# exists, and `off` unloads only modules of the three types we load whose
# argument string references dropdeck_pads / dropdeck_bus / dropdeck_mic — so
# a partial build, a crash, or another process can't leave a half-graph or
# trick teardown into touching unrelated modules.
set -euo pipefail

PADS_SINK="dropdeck_pads"
STREAM_BUS_SINK="dropdeck_bus"
STREAM_MIC_SOURCE="dropdeck_mic"
# Every module we load names one of these in its args; teardown keys off that.
OURS_RE="(^|[^A-Za-z0-9_])(${PADS_SINK}|${STREAM_BUS_SINK}|${STREAM_MIC_SOURCE})([^A-Za-z0-9_]|$)"

# pactl load-module <args...> — fail loudly if it doesn't return a numeric id
# so on()'s ERR trap tears down a partial build.
load_module() {
  local id
  id="$(pactl load-module "$@")"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "load-module gave no id: $*" >&2; return 1; }
}

status() {
  if pactl list short sinks | grep -q "\\b${PADS_SINK}\\b"; then
    echo "on"
  else
    echo "off"
  fi
}

on() {
  if [[ "$(status)" == "on" ]]; then
    echo "on"
    exit 0
  fi
  # Clear anything a prior session left behind, then build. Any failure from
  # here tears down whatever we managed to create.
  off_quiet
  trap 'off_quiet; trap - ERR; exit 1' ERR

  # $1 (optional): pin this PipeWire source as the mic instead of following the
  # system default. The plugin passes its saved choice here.
  local want_mic="${1:-}"
  local mic_source sink_out
  if [[ -n "$want_mic" ]] && pactl list short sources | awk '{print $2}' | grep -qxF "$want_mic"; then
    mic_source="$want_mic"
  else
    mic_source="$(pactl get-default-source 2>/dev/null || true)"
  fi
  sink_out="$(pactl get-default-sink 2>/dev/null || true)"
  # A monitor or empty default is no use as "the mic" — let the loopback
  # auto-attach to the default source instead of pinning a bad one.
  case "$mic_source" in
    ""|*.monitor) mic_source="" ;;
  esac

  # node.pause-on-idle=false + session.suspend-timeout-seconds=0 keep the
  # null sinks alive when nothing is flowing. Without this the pad sink
  # suspends a few seconds after the last pad, and the next
  # `pw-play --target dropdeck_pads` blocks forever waiting for a
  # suspended sink to wake instead of playing — pads go silent mid-stream.
  local nullprops="node.pause-on-idle=false session.suspend-timeout-seconds=0"

  load_module module-null-sink \
    sink_name="$PADS_SINK" \
    sink_properties="device.description=Dropdeck-Pads $nullprops"

  load_module module-null-sink \
    sink_name="$STREAM_BUS_SINK" \
    sink_properties="device.description=Dropdeck-Bus $nullprops"

  # Publish the mixed bus as a real microphone the mic picker will show.
  load_module module-remap-source \
    master="$STREAM_BUS_SINK".monitor \
    source_name="$STREAM_MIC_SOURCE" \
    source_properties="device.description=Dropdeck-Mic device.class=sound"

  # latency_msec=1 is below what module-loopback can actually service and
  # crackles under load; ~20ms is inaudible for a soundboard and stable.
  if [[ -n "$mic_source" ]]; then
    load_module module-loopback source="$mic_source" sink="$STREAM_BUS_SINK" latency_msec=20
  else
    load_module module-loopback sink="$STREAM_BUS_SINK" latency_msec=20
  fi

  load_module module-loopback source="$PADS_SINK".monitor sink="$STREAM_BUS_SINK" latency_msec=20

  if [[ -n "$sink_out" ]]; then
    load_module module-loopback source="$PADS_SINK".monitor sink="$sink_out" latency_msec=20
  else
    load_module module-loopback source="$PADS_SINK".monitor latency_msec=20
  fi

  trap - ERR
  echo "on"
}

off_quiet() {
  # Unload every module whose type is one we load and whose args reference one
  # of our uniquely-named devices. Derived entirely from PipeWire, so it can
  # only ever touch our own graph. `tac` = newest first, so dependents unload
  # before the sinks they read.
  local id name args
  while IFS=$'\t' read -r id name args; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    case "$name" in
      module-null-sink|module-loopback|module-remap-source) ;;
      *) continue ;;
    esac
    [[ "$args" =~ $OURS_RE ]] || continue
    pactl unload-module "$id" >/dev/null 2>&1 || true
  done < <(pactl list short modules | tac)
}

off() {
  off_quiet
  echo "off"
}

# Rebuild the graph in place — used when only the mic choice changed. Tearing
# down and re-running `on` is the simplest correct way to re-point the mic
# loopback (PipeWire won't move an existing one). $1 forwards to `on`.
restart() {
  off_quiet
  on "${1:-}"
}

case "${1:-status}" in
  on) on "${2:-}" ;;
  off) off ;;
  restart) restart "${2:-}" ;;
  status) status ;;
  *) echo "usage: $0 {on [mic-source]|off|restart [mic-source]|status}" >&2; exit 2 ;;
esac
