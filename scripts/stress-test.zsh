#!/bin/zsh
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/stress-test.zsh [options]

Options:
  -m, --mode MODE         easy, normal, medium, or extreme (default: normal)
  -d, --duration SECONDS   Sample duration (default: 60)
  -i, --interval SECONDS   Sample interval (default: 1)
  -r, --record             Wait for manual Start/Stop recording in the UI
  --no-build               Skip cargo/swift build steps
  -h, --help               Show this help

Examples:
  scripts/stress-test.zsh --duration 120
  scripts/stress-test.zsh --record --duration 600
EOF
}

duration=60
interval=1
record_mode=0
no_build=0
mode=normal
duration_set=0
interval_set=0

while (( $# > 0 )); do
  case "$1" in
    -m|--mode) mode="$2"; shift 2 ;;
    -d|--duration) duration="$2"; duration_set=1; shift 2 ;;
    -i|--interval) interval="$2"; interval_set=1; shift 2 ;;
    -r|--record) record_mode=1; shift ;;
    --no-build) no_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
done

case "$mode" in
  easy) (( duration_set )) || duration=30; (( interval_set )) || interval=1 ;;
  normal) (( duration_set )) || duration=60; (( interval_set )) || interval=1 ;;
  medium) (( duration_set )) || duration=180; (( interval_set )) || interval=0.5 ;;
  extreme) (( duration_set )) || duration=600; (( interval_set )) || interval=0.25; record_mode=1 ;;
  *) print -u2 "mode must be easy, normal, medium, or extreme"; exit 2 ;;
esac

if ! [[ "$duration" =~ '^[0-9]+([.][0-9]+)?$' && "$interval" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  print -u2 "duration and interval must be positive numbers"
  exit 2
fi

root_dir="${0:A:h:h}"
cd "$root_dir"

if (( ! no_build )); then
  print "[stress] building Rust FFI and Swift app..."
  cargo build -p macord-ffi --release >/dev/null
  swift build >/dev/null
fi

app_path="$root_dir/.build/debug/Macord"
if [[ ! -x "$app_path" ]]; then
  print -u2 "Macord binary not found: $app_path"
  print -u2 "Run without --no-build first."
  exit 1
fi

mkdir -p "$root_dir/artifacts"
sample_file="$root_dir/artifacts/stress-test-$(date '+%Y%m%d-%H%M%S').csv"
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

print "[stress] mode=$mode duration=${duration}s interval=${interval}s"
case "$mode" in
  easy) print "[stress] profile: preview, native source, 30 FPS, H.264, camera off" ;;
  normal) print "[stress] profile: 1080p60, H.264, camera on, microphone on" ;;
  medium) print "[stress] profile: 1440p60, HEVC, camera on, microphone + system audio" ;;
  extreme) print "[stress] profile: 4K120 target, HEVC, camera + all audio enabled" ;;
esac
print "[stress] launching $app_path"
"$app_path" --stress-profile "$mode" >/dev/null 2>&1 &
app_pid=$!

for _ in {1..30}; do
  kill -0 "$app_pid" 2>/dev/null && break
  sleep 0.1
done

if ! kill -0 "$app_pid" 2>/dev/null; then
  print -u2 "Macord exited before sampling. Check permissions or build output."
  exit 1
fi

if (( record_mode )); then
  print "[stress] Recording mode: configure the highest profile you want to test, then press Start."
  read "REPLY?Press Enter after recording has started..."
fi

print "[stress] sampling PID $app_pid for ${duration}s every ${interval}s"
print "timestamp,cpu_percent,rss_mb,threads" > "$sample_file"
start_time="$(date +%s.%N)"

while true; do
  now="$(date +%s.%N)"
  elapsed="$(awk -v now="$now" -v start="$start_time" 'BEGIN { print now - start }')"
  finished="$(awk -v elapsed="$elapsed" -v duration="$duration" 'BEGIN { print (elapsed >= duration) ? 1 : 0 }')"
  (( finished )) && break

  if ! kill -0 "$app_pid" 2>/dev/null; then
    print -u2 "Macord exited during sampling."
    break
  fi

  cpu="$(ps -p "$app_pid" -o %cpu= | tr -d ' ' | head -1)"
  rss_kb="$(ps -p "$app_pid" -o rss= | tr -d ' ' | head -1)"
  threads="$(ps -M "$app_pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  [[ -z "$cpu" ]] && cpu=0
  [[ -z "$rss_kb" ]] && rss_kb=0
  [[ -z "$threads" ]] && threads=0
  rss_mb="$(awk -v rss="$rss_kb" 'BEGIN { printf "%.3f", rss / 1024 }')"
  print "$(date '+%H:%M:%S'),$cpu,$rss_mb,$threads" >> "$sample_file"
  sleep "$interval"
done

if (( record_mode )); then
  print "[stress] sampling complete. Stop recording in the UI if it is still active."
fi

MACORD_STRESS_SAMPLE="$sample_file" awk -F, '
  NR == 1 { next }
  {
    cpu = $2
    rss = $3
    threads = $4
    if (n == 0 || cpu < cpu_min) cpu_min = cpu
    if (n == 0 || cpu > cpu_max) cpu_max = cpu
    if (n == 0 || rss < rss_min) rss_min = rss
    if (n == 0 || rss > rss_max) rss_max = rss
    if (n == 0 || threads < threads_min) threads_min = threads
    if (n == 0 || threads > threads_max) threads_max = threads
    cpu_sum += cpu
    rss_sum += rss
    thread_sum += threads
    n++
  }
  END {
    if (n == 0) { print "No samples collected."; exit 1 }
    printf "\nMacord stress test summary\n"
    printf "samples:       %d\n", n
    printf "CPU %%   min/max/avg: %.2f / %.2f / %.2f\n", cpu_min, cpu_max, cpu_sum/n
    printf "RAM MB  min/max/avg: %.2f / %.2f / %.2f\n", rss_min, rss_max, rss_sum/n
    printf "threads min/max/avg: %.0f / %.0f / %.2f\n", threads_min, threads_max, thread_sum/n
    printf "GPU:     see in-app Metal allocation metric; macOS has no reliable CLI utilization API\n"
    printf "raw samples: %s\n", ENVIRON["MACORD_STRESS_SAMPLE"]
  }
' "$sample_file"

if (( record_mode )); then
  print "\nUse the in-app Performance panel and unified log category com.macord.app/performance for frame drops, GPU memory, and file size."
fi
