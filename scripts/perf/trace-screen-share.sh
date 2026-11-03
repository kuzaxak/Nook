#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Records why Nook stutters while the screen is shared. Each pass scrolls the front Nook page the
# same way and records Time Profiler (every process, so WindowServer shows too), Animation Hitches
# and SwiftUI for Nook. "baseline" runs with no capture; "share" runs with share-sim.swift capturing
# the display as a call's screen share does. summarize.py then compares the passes.
#   scripts/perf/trace-screen-share.sh [seconds per recording, default 20] [output folder]
#
# Once per Mac: let the terminal use Screen Recording and Accessibility (System Settings → Privacy &
# Security), and let Instruments attach to apps: sudo DevToolsSecurity -enable
# PASSES="baseline" during a real call traces with the call's own capture. DRIVE=0 leaves the
# scrolling to you.
set -euo pipefail
cd "$(dirname "$0")/../.."

SECONDS_PER="${1:-20}"
OUT="${2:-$HOME/Desktop/nook-traces-$(date +%Y%m%d-%H%M%S)}"
PASSES="${PASSES:-baseline share}"
DRIVE="${DRIVE:-1}"
BIN="$(mktemp -d)"
SIM_PID=""
trap 'rm -rf "$BIN"; [[ -n "$SIM_PID" ]] && kill "$SIM_PID" 2>/dev/null; true' EXIT

pgrep -x Nook >/dev/null || { echo "Start Nook with a page open first."; exit 1; }
mkdir -p "$OUT"
swiftc -O -parse-as-library scripts/perf/share-sim.swift -o "$BIN/share-sim"
swiftc -O scripts/perf/scroll-driver.swift -o "$BIN/scroll-driver"

record() {
  local pass="$1" template="$2" slug="$3"
  shift 3
  echo "$pass: $template"
  local driver=""
  if [[ "$DRIVE" == 1 ]]; then
    "$BIN/scroll-driver" "$SECONDS_PER" &
    driver=$!
  fi
  # Instruments that need a kernel trace session fail on Macs whose SIP setup blocks it; the
  # other recordings still answer the question.
  if ! xcrun xctrace record --no-prompt --template "$template" "$@" --time-limit "${SECONDS_PER}s" \
    --output "$OUT/$pass-$slug.trace" >/dev/null; then
    echo "$pass: $template could not record; skipped"
  fi
  [[ -n "$driver" ]] && wait "$driver" || true
}

for pass in $PASSES; do
  if [[ "$pass" == share ]]; then
    "$BIN/share-sim" 3600 > "$OUT/share-sim.txt" &
    SIM_PID=$!
    sleep 3
  fi
  record "$pass" "Time Profiler" time-profile --all-processes
  record "$pass" "Animation Hitches" hitches --attach Nook
  record "$pass" "SwiftUI" swiftui --attach Nook
  if [[ -n "$SIM_PID" ]]; then
    kill -INT "$SIM_PID"
    wait "$SIM_PID" || true
    SIM_PID=""
  fi
done

python3 -I scripts/perf/summarize.py "$OUT" | tee "$OUT/summary.txt"
echo "Traces are in $OUT; open any .trace in Instruments for the full picture."
