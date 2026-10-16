#!/usr/bin/env bash
# agent-leak-app process monitoring. Output is saved by the caller with tee.
set -uo pipefail
export LC_ALL=C

APP_NAME="agent-leak-app-arm64"
APP_USER="${APP_USER:-agent-admin}"
APP_PORT="${AGENT_PORT:-15034}"

if ! id "$APP_USER" >/dev/null 2>&1; then
    printf '[ERROR] User does not exist: %s\n' "$APP_USER" >&2
    exit 1
fi

sample() {
    local timestamp pids rows port_status socket_rows
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    pids=$(pgrep -d ',' -u "$APP_USER" \
        -f "(^|/)${APP_NAME}([[:space:]]|$)" || true)

    if socket_rows=$(ss -H -ltn "sport = :$APP_PORT" 2>/dev/null); then
        port_status="NOT_LISTENING"
        if [[ -n "$socket_rows" ]]; then
            port_status="LISTENING"
        fi
    else
        port_status="UNKNOWN"
    fi

    if [[ -z "$pids" ]]; then
        printf '[%s] PROCESS:NOT_RUNNING PORT:%s\n' \
            "$timestamp" "$port_status"
        return
    fi

    rows=$(ps -p "$pids" \
        -o pid=,ppid=,stat=,pcpu=,pmem=,rss=,nlwp=,etimes= 2>/dev/null || true)

    if [[ -z "$rows" ]]; then
        printf '[%s] PROCESS:NO_PS_DATA PIDS:%s PORT:%s\n' \
            "$timestamp" "$pids" "$port_status"
        return
    fi

    awk -v ts="$timestamp" -v port="$port_status" '
        NF >= 8 {
            printf "[%s] PID:%s PPID:%s STAT:%s CPU_AVG:%s%% MEM:%s%% RSS_KiB:%s RSS_MiB:%.2f THREADS:%s ELAPSED_s:%s PORT:%s\n",
                ts, $1, $2, $3, $4, $5, $6, $6 / 1024, $7, $8, port
        }
    ' <<< "$rows"
}

case "${1:-}" in
    --once)
        sample
        ;;
    "")
        trap 'exit 0' INT TERM
        printf '[MONITOR_START] %s APP:%s USER:%s INTERVAL:1s CPU:process_lifetime_average\n' \
            "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$APP_NAME" "$APP_USER"
        while true; do
            sample
            sleep 1
        done
        ;;
    *)
        printf 'Usage: bash %s [--once]\n' "$0" >&2
        exit 2
        ;;
esac

