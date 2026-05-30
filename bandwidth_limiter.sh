#!/bin/bash

BASE_RATE="30mbit"
LIMIT_RATE="2mbit"
BANDWIDTH_THRESHOLD=8
LIMIT_DURATION=1800
WINDOW_DURATION=600
TRIGGER_COUNT=2
STATE_DIR="/var/lib/bandwidth_limiter"
LOG_FILE="/var/log/bandwidth_limiter.log"
LOG_MAX_SIZE=10485760
IFACE=$(ip route | awk '$1=="default" {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
[[ -z "$IFACE" ]] && IFACE="eth0"

[[ $EUID -ne 0 ]] && { echo "ERROR: run as root" >&2; exit 1; }

mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/bandwidth_limiter.pid"
LIMIT_FILE="$STATE_DIR/limited"
VIOLATIONS_FILE="$STATE_DIR/violations"
BYTES_FILE="$STATE_DIR/last_bytes"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "$msg" >> "$LOG_FILE"; }

kill_old_instance() {
    local my_pid=$$
    local all_pids
    all_pids=$(pgrep -f 'bandwidth_limiter\.sh' 2>/dev/null)

    local p
    for p in $all_pids; do
        (( p == my_pid )) && continue
        local cmdline
        cmdline=$(cat /proc/"$p"/cmdline 2>/dev/null | tr '\0' ' ')
        [[ "$cmdline" != *"bandwidth_limiter"* ]] && continue
        log "Killing old instance PID $p: $cmdline"
        kill "$p" 2>/dev/null
    done

    sleep 2

    for p in $all_pids; do
        (( p == my_pid )) && continue
        if kill -0 "$p" 2>/dev/null; then
            log "Force killing PID $p"
            kill -9 "$p" 2>/dev/null
        fi
    done

    sleep 1

    local remaining
    remaining=$(pgrep -f 'bandwidth_limiter\.sh' 2>/dev/null | grep -v "^${my_pid}$")
    if [[ -n "$remaining" ]]; then
        log "WARNING: still running after kill: $remaining"
        kill -9 $remaining 2>/dev/null
        sleep 1
    fi

    cleanup_all
    log "Old rules cleaned up"
}

cleanup_all() {
    tc qdisc del dev "$IFACE" root 2>/dev/null
    rm -f "$STATE_DIR"/* "$PID_FILE"
}

set_rate() {
    local rate=$1
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc add dev "$IFACE" root handle 1: htb default 10
    tc class add dev "$IFACE" parent 1: classid 1:10 htb rate "$rate" burst 64k
}

get_sent_bytes() {
    local sent
    sent=$(tc -s class show dev "$IFACE" parent 1: 2>/dev/null | grep -A1 "1:10" | grep "Sent" | awk '{print $2}')
    echo "${sent:-0}"
}

record_violation() {
    local now
    now=$(date +%s)
    local cutoff=$((now - WINDOW_DURATION))
    local tmp=""
    if [[ -f "$VIOLATIONS_FILE" ]]; then
        while IFS= read -r ts; do
            (( ts > cutoff )) && tmp+="${ts}"$'\n'
        done < "$VIOLATIONS_FILE"
    fi
    printf '%s' "$tmp" > "$VIOLATIONS_FILE"
    printf '%s\n' "$now" >> "$VIOLATIONS_FILE"
}

get_violation_count() {
    local now
    now=$(date +%s)
    local cutoff=$((now - WINDOW_DURATION))
    local count=0
    if [[ -f "$VIOLATIONS_FILE" ]]; then
        while IFS= read -r ts; do
            (( ts > cutoff )) && count=$((count + 1))
        done < "$VIOLATIONS_FILE"
    fi
    echo "$count"
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if (( size > LOG_MAX_SIZE )); then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "Log rotated (was $(( size / 1024 ))KB)"
        fi
    fi
}

cleanup() {
    log "Cleaning up..."
    cleanup_all
    log "Cleanup done"
    exit 0
}

trap cleanup SIGINT SIGTERM

kill_old_instance
echo $$ > "$PID_FILE"

set_rate "$BASE_RATE"

log "=== Bandwidth Limiter (global) ==="
log "Interface: ${IFACE} | All egress traffic"
log "Base rate: ${BASE_RATE} | Threshold: ${BANDWIDTH_THRESHOLD}Mbps"
log "Window: $((WINDOW_DURATION / 60))min | Trigger: ${TRIGGER_COUNT} hits"
log "Penalty: ${LIMIT_RATE} for $((LIMIT_DURATION / 60))min then restore ${BASE_RATE}"

log "Verifying tc..."
class_info=$(tc class show dev "$IFACE" parent 1: 2>/dev/null | grep "1:10")
if [[ -n "$class_info" ]]; then
    log "tc OK: $class_info"
else
    log "WARNING: tc class 1:10 not found!"
fi

while true; do
    if [[ -f "$LIMIT_FILE" ]]; then
        limit_time=$(cat "$LIMIT_FILE")
        now=$(date +%s)
        elapsed=$((now - limit_time))
        if (( elapsed >= LIMIT_DURATION )); then
            set_rate "$BASE_RATE"
            rm -f "$LIMIT_FILE" "$VIOLATIONS_FILE" "$BYTES_FILE"
            log "RESTORED to ${BASE_RATE}"
        else
            remaining=$(( (LIMIT_DURATION - elapsed) / 60 ))
            log "LIMITED ${LIMIT_RATE}, ${remaining}min remaining"
            rotate_log
            sleep 60
            continue
        fi
    fi

    current_bytes=$(get_sent_bytes)
    now=$(date +%s)

    if [[ ! -f "$BYTES_FILE" ]]; then
        echo "${now} ${current_bytes}" > "$BYTES_FILE"
        log "Initialized (baseline recorded)"
        rotate_log
        sleep 60
        continue
    fi

    read -r prev_ts prev_bytes < "$BYTES_FILE"
    echo "${now} ${current_bytes}" > "$BYTES_FILE"

    elapsed=$((now - prev_ts))
    (( elapsed < 1 )) && elapsed=1
    diff=$((current_bytes - prev_bytes))
    (( diff < 0 )) && diff=0

    mbps=$((diff * 8 / elapsed / 1000000))

    if (( mbps >= BANDWIDTH_THRESHOLD )); then
        record_violation
        vcount=$(get_violation_count)
        log "${mbps}Mbps >= ${BANDWIDTH_THRESHOLD}Mbps | violations: ${vcount}/${TRIGGER_COUNT}"
        if (( vcount >= TRIGGER_COUNT )); then
            set_rate "$LIMIT_RATE"
            date +%s > "$LIMIT_FILE"
            rm -f "$VIOLATIONS_FILE"
            log "LIMITED to ${LIMIT_RATE} for $((LIMIT_DURATION / 60))min"
        fi
    else
        vcount=$(get_violation_count)
        log "${mbps}Mbps | violations: ${vcount}/${TRIGGER_COUNT}"
    fi

    rotate_log
    sleep 60
done
