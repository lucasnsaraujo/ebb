#!/bin/zsh
# Holds a release build of Ebb to its lightweight budget. Meant for CI, on a disposable macOS session:
# it launches the app, which puts an item in the menu bar.
#
#   scripts/check-budget.sh [path to the release Ebb binary]     default: .build/release/Ebb
#
# Checks the binary's size, then runs the app twice for --budget-seconds (60), each in a throwaway home with
# a stand-in proxy inside the process (see Sources/Ebb/Budget.swift): once with the menu bar item showing, once
# with --hidden. It samples the running process from outside: physical footprint from `footprint`, CPU time from `ps`.
# The app counts its own network requests and timer wakes into the report. A hidden Ebb must do none.
set -euo pipefail
cd "${0:A:h}/.."
zmodload zsh/datetime

binary="${1:-.build/release/Ebb}"
seconds=60
warmup=12       # CPU is also averaged after this many seconds, once launch work is done
sample_at=$((seconds - 5))

# Measured on the macos-26 runner (commit and run in the PR that added this), with each ceiling at
# about 1.5x. A number over its ceiling fails the build: lower it only with a reason, raise it only on purpose.
#                       measured  ceiling
typeset -A ceiling
ceiling[binary_mb]=1000          # MB, unstripped, one architecture
ceiling[footprint_mb]=1000       # MB, physical footprint near the end of the run
ceiling[cpu_percent]=1000        # CPU time over the whole run, launch included
ceiling[steady_cpu_percent]=1000 # CPU time after the first $warmup seconds
ceiling[requests]=1000           # network requests in the run
ceiling[wakes]=1000              # timer and loop wakes in the run
# A run that did nothing would pass every ceiling above, so the proxy must have been polled at least this often.
min_proxy_polls=2

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
rows=()

record() {  # record <name> <value> <ceiling or "-"> <unit>
    local name=$1 value=$2 limit=$3 unit=$4 verdict="info"
    if [[ $limit != "-" ]]; then
        if (( value <= limit )); then verdict="ok"; else verdict="OVER"; failures=$((failures + 1)); fi
    fi
    printf '%-6s %-34s %10.2f %-4s ceiling %s\n' "$verdict" "$name" "$value" "$unit" "$limit"
    rows+=("| $name | $(printf '%.2f' "$value") $unit | $limit | $verdict |")
}

cpu_seconds() {  # ps prints m:ss.cc, or h:mm:ss.cc
    ps -o cputime= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

footprint_mb() {
    local out
    out="$(footprint "$1" 2>&1 || sudo -n footprint "$1" 2>&1 || true)"
    print -r -- "$out" | head -12 >&2
    local number unit
    number="$(print -r -- "$out" | grep -Eo 'Footprint: [0-9.]+ [KMG]?B' | head -1 | awk '{ print $2 }')"
    unit="$(print -r -- "$out" | grep -Eo 'Footprint: [0-9.]+ [KMG]?B' | head -1 | awk '{ print $3 }')"
    [[ -n $number ]] || { print -r -- "no footprint in the output above" >&2; return 1 }
    case $unit in
        KB) print $((number / 1024)) ;;
        MB) print $number ;;
        GB) print $((number * 1024)) ;;
        *) print $((number / 1048576)) ;;
    esac
}

sleep_until() {  # sleep_until <seconds since start> <start>
    local remaining=$(( $1 - (EPOCHREALTIME - $2) ))
    (( remaining > 0 )) && sleep "$remaining"
    return 0
}

# measure <label> [flags]: sets run_footprint, run_cpu, run_steady_cpu and the report's file name.
measure() {
    local label=$1; shift
    local home="$work/$label/home"
    mkdir -p "$home/Library/Application Support/Ebb"
    print -rn -- "budget-key" > "$home/Library/Application Support/Ebb/management-key"
    report="$work/$label.json"

    HOME="$home" CFFIXED_USER_HOME="$home" EBB_BUDGET_HOME="$home" \
        "$binary" --budget-report "$report" --budget-seconds "$seconds" "$@" > "$work/$label.log" 2>&1 &
    local pid=$! start=$EPOCHREALTIME

    sleep_until "$warmup" "$start"
    kill -0 "$pid" 2>/dev/null || { print -r -- "Ebb quit early:" >&2; cat "$work/$label.log" >&2; return 1 }
    local warm_cpu warm_time=$EPOCHREALTIME
    warm_cpu="$(cpu_seconds "$pid")"
    sleep_until "$sample_at" "$start"
    local end_cpu end_time=$EPOCHREALTIME
    end_cpu="$(cpu_seconds "$pid")"
    run_footprint="$(footprint_mb "$pid")"
    run_cpu=$(( 100 * end_cpu / (end_time - start) ))
    run_steady_cpu=$(( 100 * (end_cpu - warm_cpu) / (end_time - warm_time) ))

    local exit_code=0
    wait "$pid" || exit_code=$?
    if (( exit_code != 0 )) || [[ ! -f $report ]]; then
        print -r -- "Ebb exited with $exit_code and no report:" >&2
        cat "$work/$label.log" >&2
        return 1
    fi
}

field() {  # field <report> <key path>
    plutil -extract "$2" raw -o - "$1"
}

size_mb=$(( $(stat -f %z "$binary") / 1048576.0 ))
print "Budget for $binary"
record "binary size" "$size_mb" "${ceiling[binary_mb]}" MB

print "\nItem showing, $seconds s"
measure visible
record "physical footprint" "$run_footprint" "${ceiling[footprint_mb]}" MB
record "CPU, whole run" "$run_cpu" "${ceiling[cpu_percent]}" %
record "CPU, after ${warmup} s" "$run_steady_cpu" "${ceiling[steady_cpu_percent]}" %
record "network requests" "$(field "$report" requestTotal)" "${ceiling[requests]}" req
record "timer and loop wakes" "$(field "$report" wakeTotal)" "${ceiling[wakes]}" wakes
polls="$(field "$report" 'requests.GET auth-files' 2>/dev/null || print 0)"
record "proxy polls" "$polls" "-" polls
(( polls >= min_proxy_polls )) || { print "OVER   the stand-in proxy was polled $polls times, under $min_proxy_polls: the run measured nothing"; failures=$((failures + 1)); }
print -r -- "requests:" "$(plutil -extract requests json -o - "$report")"
print -r -- "wakes:   " "$(plutil -extract wakes json -o - "$report")"

print "\nItem hidden (--hidden), $seconds s: no polling, no network"
measure hidden --hidden
record "physical footprint" "$run_footprint" "-" MB
record "CPU, whole run" "$run_cpu" "-" %
record "network requests" "$(field "$report" requestTotal)" 0 req
record "timer and loop wakes" "$(field "$report" wakeTotal)" 0 wakes
print -r -- "requests:" "$(plutil -extract requests json -o - "$report")"
print -r -- "wakes:   " "$(plutil -extract wakes json -o - "$report")"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    { print "### Lightweight budget"; print "| | Measured | Ceiling | |"; print "| --- | --- | --- | --- |"; print -l -- $rows } >> "$GITHUB_STEP_SUMMARY"
fi
if (( failures > 0 )); then
    print "\n$failures check(s) over budget" >&2
    exit 1
fi
print "\nWithin budget"
