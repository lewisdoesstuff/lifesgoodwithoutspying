#!/bin/sh
# Controlled ConnMan -> local DNS filter handoff for the webOS TV.
#
# This script is intentionally separate from the normal webOS JS service. It
# is called by the opt-in init hook only after the user enables the feature.
# It keeps ConnMan running and changes only its per-service resolver settings.
set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
umask 077

SELF="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
STATE_DIR="${NOSPY_DNS_STATE_DIR:-/var/lib/webosbrew}"
BLOCKLIST="${NOSPY_DNS_BLOCKLIST:-$STATE_DIR/lifesgoodwithoutspying.dns}"
BLOCKLIST_FORMAT="${NOSPY_DNS_BLOCKLIST_FORMAT:-domains}"
STATUS_FILE="${NOSPY_DNS_STATUS_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.status}"
PID_FILE="${NOSPY_DNS_PID_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.pid}"
LOG_FILE="${NOSPY_DNS_LOG_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.log}"
STATE_FILE="${NOSPY_DNS_STATE_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.state}"
if [ -n "${NOSPY_DNS_BUNDLE:-}" ]; then
    BUNDLE="$NOSPY_DNS_BUNDLE"
elif [ -f "$SCRIPT_DIR/nospy-dns-filter.js" ]; then
    BUNDLE="$SCRIPT_DIR/nospy-dns-filter.js"
elif [ -f "$SCRIPT_DIR/../dist/nospy-dns-filter.js" ]; then
    BUNDLE="$SCRIPT_DIR/../dist/nospy-dns-filter.js"
else
    BUNDLE="$SCRIPT_DIR/nospy-dns-filter.js"
fi
NODE="${NOSPY_DNS_NODE:-node}"
FIREWALL_CHAIN="${NOSPY_DNS_FIREWALL_CHAIN:-NOSPYDNS}"
IPV6_MODE="${NOSPY_DNS_IPV6_MODE:-off}"
TIMEOUT_SECONDS="${NOSPY_DNS_TIMEOUT_SECONDS:-8}"
SERVICE_TIMEOUT_SECONDS="${NOSPY_DNS_SERVICE_TIMEOUT_SECONDS:-30}"

SERVICE=""
SETTINGS=""
LISTEN_ADDRESS=""
UPSTREAM=""
INTERFACE=""
ORIGINAL_NAMESERVERS=""
ORIGINAL_IPV6=""
FIREWALL_STARTED=0

log() {
    echo "dns-filter: $*"
}

die() {
    echo "dns-filter: $*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = "0" ] || die "must run as root"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

read_state_value() {
    key="$1"
    [ -f "$STATE_FILE" ] || return 1
    value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n 1)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

load_state() {
    [ -f "$STATE_FILE" ] || return 1
    SERVICE="$(read_state_value SERVICE || true)"
    # The settings path is derived from SERVICE; do not trust arbitrary paths
    # from the state file.
    [ -n "$SERVICE" ] || return 1
    SETTINGS="/var/lib/connman/$SERVICE/settings"
    LISTEN_ADDRESS="$(read_state_value LISTEN_ADDRESS || true)"
    UPSTREAM="$(read_state_value UPSTREAM || true)"
    INTERFACE="$(read_state_value INTERFACE || true)"
    ORIGINAL_NAMESERVERS="$(read_state_value ORIGINAL_NAMESERVERS || true)"
    ORIGINAL_IPV6="$(read_state_value ORIGINAL_IPV6 || true)"
    # States written by 0.4.6 and earlier used the implicit strict mode.
    # Treat those as IPv6-off so an upgrade can still roll them back safely.
    IPV6_MODE="$(read_state_value IPV6_MODE || echo off)"
    case "$IPV6_MODE" in
        off|preserve) ;;
        *) IPV6_MODE=off ;;
    esac
    FIREWALL_STARTED="$(read_state_value FIREWALL_STARTED || echo 0)"
    [ -n "$LISTEN_ADDRESS" ] && [ -n "$UPSTREAM" ] && [ -n "$INTERFACE" ]
}

save_state() {
    mkdir -p "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
    {
        echo "SERVICE=$SERVICE"
        echo "LISTEN_ADDRESS=$LISTEN_ADDRESS"
        echo "UPSTREAM=$UPSTREAM"
        echo "INTERFACE=$INTERFACE"
        echo "ORIGINAL_NAMESERVERS=$ORIGINAL_NAMESERVERS"
        echo "ORIGINAL_IPV6=$ORIGINAL_IPV6"
        echo "IPV6_MODE=$IPV6_MODE"
        echo "FIREWALL_STARTED=$FIREWALL_STARTED"
    } > "$STATE_FILE.tmp" || die "cannot write state: $STATE_FILE"
    mv "$STATE_FILE.tmp" "$STATE_FILE" || die "cannot commit state: $STATE_FILE"
}

clear_state() {
    rm -f "$STATE_FILE"
}

SNAPSHOT_ERROR=""
SNAPSHOT_RETRY=0

configure_connman_bus() {
    if [ -n "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]; then
        return 0
    fi
    for socket_path in /tmp/var/run/dbus/system_bus_socket /var/run/dbus/system_bus_socket; do
        if [ -S "$socket_path" ]; then
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=$socket_path"
            export DBUS_SYSTEM_BUS_ADDRESS
            return 0
        fi
    done
    # Let busctl try its compiled-in default if no known webOS socket exists.
    return 0
}

active_service_ids() {
    connmanctl services 2>/dev/null |
        awk '$1 ~ /O/ { print $NF }'
}

connman_unique_name() {
    configure_connman_bus
    busctl --system list 2>/dev/null |
        awk '$1 ~ /^:[0-9]/ && $0 ~ /[[:space:]]connman\.service[[:space:]]/ { print $1 }'
}

connman_property() {
    section="$1"
    key="$2"
    stop_section="$3"
    awk -v section="$section" -v key="$key" -v stop_section="$stop_section" '
        function unquote(value) {
            gsub(/^"|"$/, "", value)
            return value
        }
        {
            in_section = 0
            for (i = 1; i <= NF; i++) {
                if (section == "") {
                    if ($i == "\"" key "\"") {
                        print unquote($(i + 2))
                        exit
                    }
                } else {
                    if ($i == "\"" section "\"") {
                        in_section = 1
                    } else if (in_section && stop_section != "" && $i == "\"" stop_section "\"") {
                        exit
                    }
                    if (in_section && $i == "\"" key "\"") {
                        print unquote($(i + 2))
                        exit
                    }
                }
            }
        }
    '
}

connman_nameservers() {
    awk '
        function unquote(value) {
            gsub(/^"|"$/, "", value)
            return value
        }
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "\"Nameservers\"" && $(i + 1) == "as") {
                    count = $(i + 2) + 0
                    for (j = 1; j <= count; j++) {
                        print unquote($(i + 2 + j))
                    }
                    exit
                }
            }
        }
    '
}

is_ipv4_literal() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

snapshot_fail() {
    SNAPSHOT_ERROR="$1"
    SNAPSHOT_RETRY="$2"
    return 1
}

discover_service_snapshot() {
    SNAPSHOT_ERROR=""
    SNAPSHOT_RETRY=0
    configure_connman_bus
    ids="$(active_service_ids)"
    count="$(printf '%s\n' "$ids" | awk 'NF { n++ } END { print n + 0 }')"
    if [ "$count" -gt 1 ]; then
        snapshot_fail "multiple active ConnMan services; refusing an ambiguous handoff" 0
        return 1
    fi
    if [ "$count" -eq 0 ]; then
        snapshot_fail "no active ConnMan service" 1
        return 1
    fi
    SERVICE="$(printf '%s\n' "$ids" | awk 'NF { print; exit }')"
    case "$SERVICE" in
        ''|*[!A-Za-z0-9_]*)
            snapshot_fail "invalid ConnMan service identifier" 0
            return 1
            ;;
    esac
    SETTINGS="/var/lib/connman/$SERVICE/settings"
    [ -f "$SETTINGS" ] || {
        snapshot_fail "ConnMan settings not found: $SETTINGS" 0
        return 1
    }

    unique_names="$(connman_unique_name)"
    unique_count="$(printf '%s\n' "$unique_names" | awk 'NF { n++ } END { print n + 0 }')"
    if [ "$unique_count" -ne 1 ]; then
        snapshot_fail "could not identify one ConnMan D-Bus service" 1
        return 1
    fi
    unique_name="$(printf '%s\n' "$unique_names" | awk 'NF { print; exit }')"
    props="$(busctl --system call "$unique_name" \
        "/net/connman/service/$SERVICE" net.connman.Service GetProperties 2>/dev/null)" || {
        snapshot_fail "could not read ConnMan service properties" 1
        return 1
    }

    state="$(printf '%s\n' "$props" | connman_property '' State '')"
    if [ "$state" != "online" ]; then
        snapshot_fail "active ConnMan service is not online" 1
        return 1
    fi
    INTERFACE="$(printf '%s\n' "$props" | connman_property Ethernet Interface IPv4)"
    LISTEN_ADDRESS="$(printf '%s\n' "$props" | connman_property IPv4 Address IPv6)"
    [ -n "$INTERFACE" ] && [ -n "$LISTEN_ADDRESS" ] || {
        snapshot_fail "ConnMan service did not provide one Ethernet interface/address" 0
        return 1
    }
    case "$LISTEN_ADDRESS" in
        ''|*[!0-9.]*|0.0.0.0|127.*)
            snapshot_fail "ConnMan service address is not usable as a listener: $LISTEN_ADDRESS" 0
            return 1
            ;;
    esac
    ip -4 -o addr show dev "$INTERFACE" 2>/dev/null |
        grep -q " $LISTEN_ADDRESS/" || {
            snapshot_fail "ConnMan address is not assigned to its reported interface" 0
            return 1
        }

    nameservers="$(printf '%s\n' "$props" | connman_nameservers)"
    ipv4_nameservers=""
    ipv4_count=0
    while IFS= read -r nameserver; do
        [ -n "$nameserver" ] || continue
        if is_ipv4_literal "$nameserver"; then
            ipv4_nameservers="$nameserver"
            ipv4_count=$((ipv4_count + 1))
        fi
    done <<EOF
$nameservers
EOF
    if [ "$ipv4_count" -eq 0 ]; then
        snapshot_fail "active ConnMan service has no IPv4 nameserver" 0
        return 1
    fi
    if [ "$ipv4_count" -gt 1 ]; then
        snapshot_fail "active ConnMan service has multiple IPv4 nameservers" 0
        return 1
    fi
    UPSTREAM="$ipv4_nameservers"
    case "$UPSTREAM" in
        127.*|0.0.0.0|"$LISTEN_ADDRESS")
            snapshot_fail "active ConnMan nameserver is not a safe upstream: $UPSTREAM" 0
            return 1
            ;;
    esac
    return 0
}

wait_for_service_snapshot() {
    elapsed=0
    while [ "$elapsed" -lt "$SERVICE_TIMEOUT_SECONDS" ]; do
        if discover_service_snapshot; then
            return 0
        fi
        [ "$SNAPSHOT_RETRY" = "1" ] || return 1
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

connman_config() {
    option="$1"
    shift
    command_file="/tmp/nospy-dns-connman.$$"
    {
        printf 'config %s %s' "$SERVICE" "$option"
        for value in "$@"; do
            printf ' %s' "$value"
        done
        printf '\nexit\n'
    } > "$command_file"
    script -q -c connmanctl /dev/null < "$command_file" >/dev/null 2>&1
    result=$?
    rm -f "$command_file"
    return "$result"
}

helper_pid() {
    [ -f "$PID_FILE" ] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    command_line="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$command_line" in
        *nospy-dns-filter*) ;;
        *) return 1 ;;
    esac
    echo "$pid"
}

helper_running() {
    helper_pid >/dev/null 2>&1
}

status_value() {
    key="$1"
    [ -f "$STATUS_FILE" ] || return 1
    value="$(sed -n "s/^${key}=//p" "$STATUS_FILE" | tail -n 1)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

artifact_check_output() {
    timeout 10 "$NODE" "$BUNDLE" \
        --listen-address "$LISTEN_ADDRESS" \
        --listen-port 53 \
        --upstream "$UPSTREAM:53" \
        --blocklist "$BLOCKLIST" \
        --blocklist-format "$BLOCKLIST_FORMAT" \
        --check 2>&1
}

artifact_metadata() {
    output="$(artifact_check_output)" || return 1
    generation="$(printf '%s\n' "$output" | sed -n 's/.*generation=\([^;]*\);.*/\1/p')"
    declared="$(printf '%s\n' "$output" | sed -n 's/.*declared_rules=\([^;]*\);.*/\1/p')"
    unique="$(printf '%s\n' "$output" | sed -n 's/^ok: \([0-9][0-9]*\) blocklist rule(s).*/\1/p')"
    [ -n "$generation" ] && [ "$generation" != "unknown" ] || return 1
    [ -n "$declared" ] && [ "$declared" != "unknown" ] || return 1
    [ -n "$unique" ] || return 1
    printf '%s %s %s\n' "$generation" "$declared" "$unique"
}

helper_start() {
    [ -f "$BUNDLE" ] || die "DNS bundle not found: $BUNDLE"
    [ -f "$BLOCKLIST" ] || die "generated blocklist not found: $BLOCKLIST"
    require_command "$NODE"
    require_command timeout

    metadata="$(artifact_metadata)" || die "DNS artifact check failed"
    expected_generation="$(printf '%s\n' "$metadata" | awk '{print $1}')"
    expected_declared="$(printf '%s\n' "$metadata" | awk '{print $2}')"
    expected_unique="$(printf '%s\n' "$metadata" | awk '{print $3}')"

    if helper_running; then
        if [ "$(status_value generation 2>/dev/null || true)" = "$expected_generation" ] &&
            [ "$(status_value ready 2>/dev/null || true)" = "1" ]; then
            log "helper already running (acknowledged generation $expected_generation)"
            return 0
        fi
        die "a helper is running without the expected acknowledged generation"
    fi

    rm -f "$STATUS_FILE"
    : > "$LOG_FILE"
    nohup "$NODE" "$BUNDLE" \
        --listen-address "$LISTEN_ADDRESS" \
        --listen-port 53 \
        --upstream "$UPSTREAM:53" \
        --blocklist "$BLOCKLIST" \
        --blocklist-format "$BLOCKLIST_FORMAT" \
        --status-file "$STATUS_FILE" \
        >>"$LOG_FILE" 2>&1 </dev/null &
    pid=$!
    echo "$pid" > "$PID_FILE"

    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            die "DNS helper exited during startup; see $LOG_FILE"
        fi
        if grep -q 'listening generation=' "$LOG_FILE" 2>/dev/null &&
            [ "$(status_value ready 2>/dev/null || true)" = "1" ] &&
            [ "$(status_value generation 2>/dev/null || true)" = "$expected_generation" ] &&
            [ "$(status_value declared_rules 2>/dev/null || true)" = "$expected_declared" ] &&
            [ "$(status_value rules 2>/dev/null || true)" = "$expected_unique" ]; then
            log "helper listening on $LISTEN_ADDRESS:53 (acknowledged generation $expected_generation)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    die "DNS helper did not become ready; see $LOG_FILE"
}

helper_stop() {
    pid="$(helper_pid 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        elapsed=0
        while kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt 3 ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$STATUS_FILE"
}

helper_reload() {
    [ -f "$STATE_FILE" ] || die "handoff state is missing"
    load_state || die "invalid handoff state: $STATE_FILE"
    pid="$(helper_pid 2>/dev/null || true)"
    [ -n "$pid" ] || die "DNS helper is not running"
    metadata="$(artifact_metadata)" || die "DNS artifact check failed before reload"
    expected_generation="$(printf '%s\n' "$metadata" | awk '{print $1}')"
    expected_declared="$(printf '%s\n' "$metadata" | awk '{print $2}')"
    expected_unique="$(printf '%s\n' "$metadata" | awk '{print $3}')"
    old_sequence="$(status_value reload_sequence 2>/dev/null || echo 0)"

    kill -HUP "$pid" || die "could not signal DNS helper"
    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
        sequence="$(status_value reload_sequence 2>/dev/null || echo "$old_sequence")"
        generation="$(status_value generation 2>/dev/null || true)"
        declared="$(status_value declared_rules 2>/dev/null || true)"
        unique="$(status_value rules 2>/dev/null || true)"
        reload_ok="$(status_value reload_ok 2>/dev/null || echo 0)"
        if [ "$sequence" -gt "$old_sequence" ] 2>/dev/null; then
            if [ "$reload_ok" = "1" ] &&
                [ "$generation" = "$expected_generation" ] &&
                [ "$declared" = "$expected_declared" ] &&
                [ "$unique" = "$expected_unique" ]; then
                log "reload acknowledged generation=$expected_generation rules=$expected_unique"
                return 0
            fi
            if [ "$reload_ok" = "0" ]; then
                die "DNS helper rejected the new generation"
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    die "DNS helper reload acknowledgement timed out"
}

firewall_on() {
    if iptables -n -L "$FIREWALL_CHAIN" >/dev/null 2>&1; then
        die "firewall chain already exists: $FIREWALL_CHAIN"
    fi
    iptables -N "$FIREWALL_CHAIN" || die "cannot create firewall chain"
    iptables -A "$FIREWALL_CHAIN" -j DROP || {
        iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
        die "cannot populate firewall chain"
    }
    iptables -I INPUT 1 -i "$INTERFACE" -p udp --dport 53 -d "$LISTEN_ADDRESS" -j "$FIREWALL_CHAIN" || {
        iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
        die "cannot install UDP DNS firewall rule"
    }
    iptables -I INPUT 1 -i "$INTERFACE" -p tcp --dport 53 -d "$LISTEN_ADDRESS" -j "$FIREWALL_CHAIN" || {
        iptables -D INPUT -i "$INTERFACE" -p udp --dport 53 -d "$LISTEN_ADDRESS" -j "$FIREWALL_CHAIN" 2>/dev/null || true
        iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
        die "cannot install TCP DNS firewall rule"
    }
    FIREWALL_STARTED=1
    log "LAN access to $LISTEN_ADDRESS:53 blocked"
}

firewall_off() {
    [ "$FIREWALL_STARTED" = "1" ] || return 0
    if ! iptables -n -L "$FIREWALL_CHAIN" >/dev/null 2>&1; then
        FIREWALL_STARTED=0
        return 0
    fi
    iptables -D INPUT -i "$INTERFACE" -p tcp --dport 53 -d "$LISTEN_ADDRESS" -j "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -D INPUT -i "$INTERFACE" -p udp --dport 53 -d "$LISTEN_ADDRESS" -j "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
    FIREWALL_STARTED=0
}

capture_original_connman() {
    ORIGINAL_NAMESERVERS="$(grep '^Nameservers=' "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true)"
    ORIGINAL_IPV6="$(grep '^IPv6.method=' "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true)"
    [ -n "$ORIGINAL_IPV6" ] || ORIGINAL_IPV6=auto
}

configure_connman_on() {
    capture_original_connman
    connman_config --nameservers "$LISTEN_ADDRESS" ||
        die "could not set ConnMan nameserver"

    grep -q "^Nameservers=${LISTEN_ADDRESS}" "$SETTINGS" ||
        die "ConnMan nameserver setting was not persisted"

    case "$IPV6_MODE" in
        off)
            connman_config --ipv6 off ||
                die "could not set ConnMan IPv6 mode"
            grep -q "^IPv6.method=off" "$SETTINGS" ||
                die "ConnMan IPv6 setting was not persisted"
            log "ConnMan now uses $LISTEN_ADDRESS; IPv6 mode=off"
            ;;
        preserve)
            log "ConnMan now uses $LISTEN_ADDRESS; IPv6 configuration preserved"
            ;;
        *)
            die "invalid IPv6 mode: $IPV6_MODE"
            ;;
    esac
}

connman_setting_value() {
    setting_key="$1"
    grep "^${setting_key}=" "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true
}

verify_connman_restore() {
    expected_names="$(printf '%s' "$ORIGINAL_NAMESERVERS" | sed 's/[[:space:],;]//g')"
    actual_names="$(connman_setting_value Nameservers | sed 's/[[:space:],;]//g')"
    [ "$actual_names" = "$expected_names" ] || return 1
    if [ "$IPV6_MODE" = "off" ]; then
        actual_ipv6="$(connman_setting_value IPv6.method)"
        [ "$actual_ipv6" = "$ORIGINAL_IPV6" ] || return 1
    fi
    return 0
}

configure_connman_off() {
    restore_ok=1
    if [ -n "$ORIGINAL_NAMESERVERS" ]; then
        old_values="$(printf '%s' "$ORIGINAL_NAMESERVERS" | tr ',;' '  ')"
        # Nameserver settings contain only IP literals.
        # shellcheck disable=SC2086
        connman_config --nameservers $old_values || restore_ok=0
    else
        connman_config --nameservers || restore_ok=0
    fi
    [ -n "$ORIGINAL_IPV6" ] || ORIGINAL_IPV6=auto
    if [ "$IPV6_MODE" = "off" ]; then
        connman_config --ipv6 "$ORIGINAL_IPV6" || restore_ok=0
    else
        log "ConnMan IPv6 configuration was preserved"
    fi
    if [ "$restore_ok" -ne 1 ]; then
        log "ConnMan resolver rollback was incomplete; retaining handoff state"
        return 1
    fi
    verify_attempt=0
    while [ "$verify_attempt" -lt 5 ]; do
        verify_connman_restore && break
        verify_attempt=$((verify_attempt + 1))
        sleep 1
    done
    if ! verify_connman_restore; then
        log "ConnMan resolver settings did not reach their original values; retaining handoff state"
        return 1
    fi
    log "ConnMan resolver configuration restored"
}

enable_failed() {
    rc=$?
    trap - EXIT
    if [ -f "$STATE_FILE" ] && load_state; then
        if configure_connman_off >/dev/null 2>&1; then
            firewall_off || true
            helper_stop || true
            clear_state
        else
            log "rollback incomplete; retaining handoff state for a later retry"
        fi
    fi
    exit "$rc"
}

enable_handoff() {
    trap enable_failed EXIT
    require_root
    case "$IPV6_MODE" in
        off|preserve) ;;
        *) die "invalid IPv6 mode: $IPV6_MODE (expected off or preserve)" ;;
    esac
    [ -f "$STATE_FILE" ] && die "handoff is already enabled; run disable first"
    require_command connmanctl
    require_command iptables
    require_command ip
    require_command script
    require_command realpath
    if ! wait_for_service_snapshot; then
        die "could not obtain one coherent active ConnMan snapshot: $SNAPSHOT_ERROR"
    fi
    capture_original_connman
    save_state
    firewall_on
    save_state
    helper_start
    if ! configure_connman_on; then
        disable_handoff
        die "handoff setup failed"
    fi
    save_state
    trap - EXIT
    log "handoff enabled"
}

disable_handoff() {
    require_root
    if [ ! -f "$STATE_FILE" ]; then
        helper_stop
        log "handoff already disabled"
        return 0
    fi
    load_state || die "invalid handoff state: $STATE_FILE"
    if ! configure_connman_off; then
        log "handoff remains enabled because ConnMan rollback was incomplete"
        return 1
    fi
    firewall_off
    helper_stop
    clear_state
    log "handoff disabled"
}

status_handoff() {
    if [ -f "$STATE_FILE" ]; then
        load_state || die "invalid handoff state: $STATE_FILE"
        if helper_running; then
            echo "enabled=yes"
        else
            echo "enabled=no"
        fi
        echo "service=$SERVICE"
        echo "listener=$LISTEN_ADDRESS:53"
        echo "interface=$INTERFACE"
        echo "helper=$(helper_running && echo running || echo stopped)"
        echo "connman_nameservers=$(grep '^Nameservers=' "$SETTINGS" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
        echo "connman_ipv6=$(grep '^IPv6.method=' "$SETTINGS" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
        echo "handoff_ipv6_mode=$IPV6_MODE"
        echo "loaded_generation=$(status_value generation 2>/dev/null || true)"
        echo "loaded_rules=$(status_value rules 2>/dev/null || true)"
        echo "loaded_declared_rules=$(status_value declared_rules 2>/dev/null || true)"
    else
        echo "enabled=no"
        echo "helper=$(helper_running && echo running || echo stopped)"
    fi
}

plan_handoff() {
    discover_service_snapshot || die "could not obtain one coherent active ConnMan snapshot: $SNAPSHOT_ERROR"
    echo "service=$SERVICE"
    echo "listener=$LISTEN_ADDRESS:53"
    echo "upstream=$UPSTREAM:53"
    echo "interface=$INTERFACE"
    echo "ipv6_mode=$IPV6_MODE"
    echo "bundle=$BUNDLE"
    echo "blocklist=$BLOCKLIST"
    echo "blocklist_format=$BLOCKLIST_FORMAT"
}

case "${1:-status}" in
    enable) enable_handoff ;;
    disable) disable_handoff ;;
    reload) require_root; helper_reload ;;
    status) status_handoff ;;
    plan) plan_handoff ;;
    *) die "usage: $0 enable|disable|reload|status|plan" ;;
esac
