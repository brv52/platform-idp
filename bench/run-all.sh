#!/usr/bin/env bash
# Runs the whole benchmark suite against the local cluster and renders
# metrics.json and docs/results.md from the results.
#
#   attacks        bench/attacks/run.sh      ~1 min
#   admission      bench/admission.sh        ~2 min   (k6, 500 VUs)
#   rotation       bench/svid-rotation.sh    ~20 min  (DURATION=15m)
#   regressions    bench/regressions.sh      ~25 min  (5 bad releases)
#   clean          bench/clean-releases.sh   ~35 min  (5 clean releases)
#
# Usage: bench/run-all.sh [step ...]     default: all steps, in this order
#        bench/run-all.sh render         only re-render from bench/out/*.json
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench/lib.sh
source "${HERE}/lib.sh"

STEPS=(attacks admission rotation regressions clean)
(( $# )) && STEPS=("$@")

failed=()
run() { # step command...
  local step="$1"; shift
  log "---- ${step}"
  "$@" || { warn "${step} failed (exit $?)"; failed+=("$step"); }
}

for s in "${STEPS[@]}"; do
  case "$s" in
    attacks)     run attacks "${HERE}/attacks/run.sh" ;;
    admission)   run admission "${HERE}/admission.sh" ;;
    rotation)    run rotation "${HERE}/svid-rotation.sh" ;;
    regressions) run regressions "${HERE}/regressions.sh" ;;
    clean)       run clean "${HERE}/clean-releases.sh" "${CLEAN_COUNT:-5}" ;;
    render)      ;;
    *)           die "unknown step: $s" ;;
  esac
done

"${HERE}/render.sh" || failed+=(render)
(( ${#failed[@]} == 0 )) || die "failed steps: ${failed[*]}"
