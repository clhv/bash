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
DEFAULT_CLASS_ID=9999
DEFAULT_RATE="10gbit"
XUI_DB="/etc/x-ui/x-ui.db"
IFACE=$(ip route | awk '$1=="default" {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
[[ -z "$IFACE" ]] && IFACE="eth0"

[[ $EUID -ne 0 ]] && { echo "ERROR: run as root" >&2; exit 1; }

mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/bandwidth_limiter.pid"
LIMIT_DIR="$STATE_DIR/limited"
VIOLATIONS_DIR="$STATE_DIR/violations"
BYTES_DIR="$STATE_DIR/last_bytes"
mkdir -p "$LIMIT_DIR" "$VIOLATIONS_DIR" "$BYTES_DIR"

log() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "$msg" >> "$LOG_FILE"; }

port_to_hex() { printf '%x' "$1"; }


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
    mkdir -p "$LIMIT_DIR" "$VIOLATIONS_DIR" "$BYTES_DIR"
}

get_ports_from_db() {
    if [[ -f "$XUI_DB" ]]; then
        sqlite3 "$XUI_DB" "SELECT port FROM inbounds WHERE enable=1;" 2>/dev/null | grep -E '^[0-9]+$' | sort -un
    fi
}

init_tc_root() {
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc add dev "$IFACE" root handle 1: htb default $DEFAULT_CLASS_ID
    local hex_default
    hex_default=$(port_to_hex $DEFAULT_CLASS_ID)
    tc class add dev "$IFACE" parent 1: classid 1:${hex_default} htb rate "$DEFAULT_RATE" burst 256k
    log "TC root: qdisc 1: htb default ${DEFAULT_CLASS_ID}, default class ${DEFAULT_RATE}"
}

add_port_class() {
    local port=$1
    local rate=${2:-$BASE_RATE}
    local hex_port
    hex_port=$(port_to_hex "$port")
    tc class add dev "$IFACE" parent 1: classid 1:${hex_port} htb rate "$rate" burst 64k 2>/dev/null
}

add_port_filter() {
    local port=$1
    local hex_port
    hex_port=$(port_to_hex "$port")
    local filter_handle
    filter_handle=$(printf '0x%x' "$port")
    tc filter add dev "$IFACE" parent 1: protocol ip prio 1 handle ${filter_handle} u32 \
        match ip sport "$port" 0xffff flowid 1:${hex_port} 2>/dev/null
}

remove_port_filter() {
    local port=$1
    local filter_handle
    filter_handle=$(printf '0x%x' "$port")
    tc filter del dev "$IFACE" parent 1: protocol ip prio 1 handle ${filter_handle} u32 2>/dev/null
}

remove_port_class() {
    local port=$1
    local hex_port
    hex_port=$(port_to_hex "$port")
    remove_port_filter "$port"
    tc class del dev "$IFACE" parent 1: classid 1:${hex_port} 2>/dev/null
}

set_port_rate() {
    local port=$1
    local rate=$2
    local hex_port
    hex_port=$(port_to_hex "$port")
    tc class change dev "$IFACE" parent 1: classid 1:${hex_port} htb rate "$rate" burst 64k
}

get_port_sent_bytes() {
    local port=$1
    local hex_port
    hex_port=$(port_to_hex "$port")
    local sent
    sent=$(tc -s class show dev "$IFACE" parent 1: 2>/dev/null | grep -A3 "class 1:${hex_port}" | grep "Sent" | awk '{print $2}')
    echo "${sent:-0}"
}

get_current_class_ports() {
    tc class show dev "$IFACE" parent 1: 2>/dev/null | grep -oP 'class 1:\K[0-9a-fA-F]+' | while read -r hex; do
        local dec=$((16#$hex))
        (( dec != DEFAULT_CLASS_ID )) && echo "$dec"
    done | sort -un
}

sync_ports() {
    local desired_ports
    desired_ports=$(get_ports_from_db)
    if [[ -z "$desired_ports" ]]; then
        log "WARNING: no ports from DB, skipping sync"
        return
    fi

    local current_class_ports
    current_class_ports=$(get_current_class_ports)

    local -A desired_map=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && desired_map[$p]=1
    done <<< "$desired_ports"

    local -A current_map=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && current_map[$p]=1
    done <<< "$current_class_ports"

    for p in "${!desired_map[@]}"; do
        if [[ -z "${current_map[$p]}" ]]; then
            log "ADD port $p: class + filter"
            add_port_class "$p" "$BASE_RATE"
            add_port_filter "$p"
        fi
    done

    for p in "${!current_map[@]}"; do
        if [[ -z "${desired_map[$p]}" ]]; then
            log "REMOVE port $p: class + filter"
            remove_port_class "$p"
            rm -f "$LIMIT_DIR/$p" "$VIOLATIONS_DIR/$p" "$BYTES_DIR/$p"
        fi
    done
}

record_violation() {
    local port=$1
    local now
    now=$(date +%s)
    local cutoff=$((now - WINDOW_DURATION))
    local tmp=""
    if [[ -f "$VIOLATIONS_DIR/$port" ]]; then
        while IFS= read -r ts; do
            (( ts > cutoff )) && tmp+="${ts}"$'\n'
        done < "$VIOLATIONS_DIR/$port"
    fi
    printf '%s' "$tmp" > "$VIOLATIONS_DIR/$port"
    printf '%s\n' "$now" >> "$VIOLATIONS_DIR/$port"
}

get_violation_count() {
    local port=$1
    local now
    now=$(date +%s)
    local cutoff=$((now - WINDOW_DURATION))
    local count=0
    if [[ -f "$VIOLATIONS_DIR/$port" ]]; then
        while IFS= read -r ts; do
            (( ts > cutoff )) && count=$((count + 1))
        done < "$VIOLATIONS_DIR/$port"
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

init_tc_root

log "=== Bandwidth Limiter (per-port) ==="
log "Interface: ${IFACE} | Default class: ${DEFAULT_CLASS_ID} ${DEFAULT_RATE}"
log "Base rate: ${BASE_RATE} | Threshold: ${BANDWIDTH_THRESHOLD}Mbps"
log "Window: $((WINDOW_DURATION / 60))min | Trigger: ${TRIGGER_COUNT} hits"
log "Penalty: ${LIMIT_RATE} for $((LIMIT_DURATION / 60))min then restore ${BASE_RATE}"

SYNC_INTERVAL=300
last_sync=0

while true; do
    local now
    now=$(date +%s)

    if (( now - last_sync >= SYNC_INTERVAL )); then
        sync_ports
        last_sync=$now
    fi

    local ports
    ports=$(get_ports_from_db)
    if [[ -z "$ports" ]]; then
        log "No ports from DB, retrying in 60s"
        rotate_log
        sleep 60
        continue
    fi

    local port
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue

        local hex_port
        hex_port=$(port_to_hex "$port")

        local class_exists
        class_exists=$(tc class show dev "$IFACE" parent 1: 2>/dev/null | grep "class 1:${hex_port}")
        if [[ -z "$class_exists" ]]; then
            add_port_class "$port" "$BASE_RATE"
            add_port_filter "$port"
        fi

        if [[ -f "$LIMIT_DIR/$port" ]]; then
            local limit_time
            limit_time=$(cat "$LIMIT_DIR/$port")
            local elapsed=$((now - limit_time))
            if (( elapsed >= LIMIT_DURATION )); then
                set_port_rate "$port" "$BASE_RATE"
                rm -f "$LIMIT_DIR/$port" "$VIOLATIONS_DIR/$port" "$BYTES_DIR/$port"
                log "port ${port}: RESTORED to ${BASE_RATE}"
            else
                local remaining=$(( (LIMIT_DURATION - elapsed) / 60 ))
                log "port ${port}: LIMITED ${LIMIT_RATE}, ${remaining}min remaining"
                continue
            fi
        fi

        local current_bytes
        current_bytes=$(get_port_sent_bytes "$port")
        local bytes_file="$BYTES_DIR/$port"

        if [[ ! -f "$bytes_file" ]]; then
            echo "${now} ${current_bytes}" > "$bytes_file"
            continue
        fi

        local prev_ts prev_bytes
        read -r prev_ts prev_bytes < "$bytes_file"
        echo "${now} ${current_bytes}" > "$bytes_file"

        local elapsed=$((now - prev_ts))
        (( elapsed < 1 )) && elapsed=1
        local diff=$((current_bytes - prev_bytes))
        (( diff < 0 )) && diff=0

        local mbps=$((diff * 8 / elapsed / 1000000))

        if (( mbps >= BANDWIDTH_THRESHOLD )); then
            record_violation "$port"
            local vcount
            vcount=$(get_violation_count "$port")
            log "port ${port}: ${mbps}Mbps >= ${BANDWIDTH_THRESHOLD}Mbps | violations: ${vcount}/${TRIGGER_COUNT}"
            if (( vcount >= TRIGGER_COUNT )); then
                set_port_rate "$port" "$LIMIT_RATE"
                date +%s > "$LIMIT_DIR/$port"
                rm -f "$VIOLATIONS_DIR/$port"
                log "port ${port}: LIMITED to ${LIMIT_RATE} for $((LIMIT_DURATION / 60))min"
            fi
        else
            local vcount
            vcount=$(get_violation_count "$port")
            if (( vcount > 0 )); then
                log "port ${port}: ${mbps}Mbps | violations: ${vcount}/${TRIGGER_COUNT}"
            fi
        fi

    done <<< "$ports"

    rotate_log
    sleep 60
done
