#!/bin/sh
# Controlled DNS filter handoff for the webOS TV.
#
# All outbound UDP and TCP traffic destined for port 53 is diverted by the
# nat OUTPUT chain into a local filtering helper. This includes the DNS
# queries ConnMan's DNS proxy makes on behalf of every app. ConnMan's DNS
# settings are not modified by this handoff.
#
# The helper's own upstream queries are exempt from the redirect by source
# port: its UDP upstream socket is pinned to a fixed source port, and its TCP
# upstream connections rotate through a dedicated range.
#
# This script is intentionally separate from the normal webOS JS service. It
# is called by the opt-in init hook only after the user enables the feature.
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
LEGACY_FIREWALL_CHAIN="${NOSPY_DNS_FIREWALL_CHAIN:-NOSPYDNS}"
IPV6_MODE="${NOSPY_DNS_IPV6_MODE:-off}"
TIMEOUT_SECONDS="${NOSPY_DNS_TIMEOUT_SECONDS:-8}"
SERVICE_TIMEOUT_SECONDS="${NOSPY_DNS_SERVICE_TIMEOUT_SECONDS:-30}"
HELPER_ADDRESS="${NOSPY_DNS_HELPER_ADDRESS:-127.0.0.1}"
HELPER_PORT="${NOSPY_DNS_HELPER_PORT:-5354}"
HELPER_UPSTREAM_SPORT="${NOSPY_DNS_HELPER_UPSTREAM_SPORT:-15354}"
HELPER_UPSTREAM_TCP_PORT_START="${NOSPY_DNS_HELPER_UPSTREAM_TCP_PORT_START:-15355}"
HELPER_UPSTREAM_TCP_PORT_END="${NOSPY_DNS_HELPER_UPSTREAM_TCP_PORT_END:-15483}"
RESOLV_CONF="${NOSPY_DNS_RESOLV_CONF:-/etc/resolv.conf}"
RESOLV_SOURCE="${NOSPY_DNS_RESOLV_SOURCE:-$STATE_DIR/lifesgoodwithoutspying-resolv.conf}"
RESOLV_MARKER="# lifesgoodwithoutspying dns-filter resolv.conf"

SERVICE=""
SETTINGS=""
LISTEN_ADDRESS=""
UPSTREAM=""
INTERFACE=""
ORIGINAL_NAMESERVERS=""
ORIGINAL_IPV6=""
LEGACY_FIREWALL_STARTED=0
NAT_STARTED=0

# BusyBox's timeout takes the duration as a bare SECS argument in 1.35 (webOS 9)
# but only as "-t SECS" in 1.29 (webOS 5/6), and each rejects the other's form
# outright. The wrong form exits 127 without ever running the command, so ask
# this build which one it accepts instead of assuming. Probed once per run: a
# valid result inherited from the parent script is kept.
# Duplicated from nospy-lib.sh so this script stays standalone.
case "${TIMEOUT_STYLE:-}" in
    bare|flag|none) ;;
    *) TIMEOUT_STYLE="" ;;
esac

log() {
    echo "dns-filter: $*"
}

# Run a command under a shell watchdog: SIGTERM after SECS seconds, then
# SIGKILL GRACE seconds later (straight to SIGKILL when GRACE is 0). Returns
# the command's status. The watchdog's stdio is detached so a caller reading
# this through a command substitution is not held open until it fires, and
# cancelling it also stops its sleep, which would otherwise linger until it
# would have fired.
run_capped() {
    c_secs="$1"
    c_grace="$2"
    shift 2
    # A background command gets /dev/null as stdin; hand it the caller's.
    { "$@" <&3 3<&- & } 3<&0
    c_pid=$!
    (
        trap 'kill "$c_sleep" 2>/dev/null; exit 0' TERM
        c_sleep=
        sleep "$c_secs" &
        c_sleep=$!
        wait "$c_sleep"
        if [ "$c_grace" -gt 0 ]; then
            kill -TERM "$c_pid" 2>/dev/null || exit 0
            sleep "$c_grace" &
            c_sleep=$!
            wait "$c_sleep"
        fi
        kill -KILL "$c_pid" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    c_dog=$!
    wait "$c_pid"
    c_rc=$?
    kill "$c_dog" 2>/dev/null
    wait "$c_dog" 2>/dev/null
    return "$c_rc"
}

# Run one probe for at most 2 seconds. Under the Homebrew Channel's exec on
# webOS 4.4 (BusyBox 1.24), timeout never starts its command and only returns
# once its own limit kills it, so an unguarded probe costs 11 seconds.
probe_quick() {
    run_capped 2 0 "$@" </dev/null >/dev/null 2>&1
}

detect_timeout_style() {
    [ -n "$TIMEOUT_STYLE" ] && return 0
    if ! command -v timeout >/dev/null 2>&1; then
        TIMEOUT_STYLE=none
    elif probe_quick timeout 1 true; then
        TIMEOUT_STYLE=bare
    elif probe_quick timeout -t 1 true; then
        TIMEOUT_STYLE=flag
    else
        TIMEOUT_STYLE=none
    fi
    # Child scripts of the same run (apply, the DNS handoff) skip the probe.
    export TIMEOUT_STYLE
    if [ "$TIMEOUT_STYLE" = none ]; then
        # stderr, because callers read this through a command substitution.
        log "no usable timeout on this build; using a shell watchdog" >&2
    fi
    return 0
}

# Run a command with a timeout, so one slow helper call cannot stall an apply
# or a boot hook. Builds without a usable timeout applet (webOS 4.x) get the
# shell watchdog instead.
bounded() {
    detect_timeout_style
    case "$TIMEOUT_STYLE" in
        # SIGKILL: util-linux script (webOS 4.x) blocks SIGTERM.
        bare) timeout -s KILL 10 "$@"; return $? ;;
        flag) timeout -t 10 -s KILL "$@"; return $? ;;
    esac
    run_capped 10 1 "$@"
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
    LEGACY_FIREWALL_STARTED="$(read_state_value FIREWALL_STARTED || echo 0)"
    NAT_STARTED="$(read_state_value NAT_STARTED || echo 0)"
    [ -n "$INTERFACE" ] && [ -n "$UPSTREAM" ]
}

save_state() {
    mkdir -p "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
    {
        echo "SERVICE=$SERVICE"
        echo "LISTEN_ADDRESS=$HELPER_ADDRESS"
        echo "UPSTREAM=$UPSTREAM"
        echo "INTERFACE=$INTERFACE"
        echo "ORIGINAL_NAMESERVERS=$ORIGINAL_NAMESERVERS"
        echo "ORIGINAL_IPV6=$ORIGINAL_IPV6"
        echo "IPV6_MODE=$IPV6_MODE"
        echo "FIREWALL_STARTED=$LEGACY_FIREWALL_STARTED"
        echo "NAT_STARTED=$NAT_STARTED"
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

# connmanctl prints three flag columns before the name: favorite (*),
# autoconnect (A) and state (O online, R ready). Match the state column only,
# so a network name is never read as a flag, and take Ready as well as Online:
# ConnMan stays at Ready whenever its online check fails, which says nothing
# about whether the link works.
#
# connmanctl spins at full CPU and never answers when its stdin is at EOF,
# which is what /dev/null gives it at boot (seen on webOS 4.4). A pty from
# script(1) keeps it working; tr drops the pty's carriage returns.
active_service_ids() {
    bounded script -q -c "connmanctl services" /dev/null </dev/null 2>/dev/null |
        tr -d '\r' |
        awk 'substr($0, 3, 1) ~ /[OR]/ { print $NF }'
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
    # Ready is as usable as Online; ConnMan only stays at Ready because its
    # online check failed.
    case "$state" in
        online|ready) ;;
        *)
            snapshot_fail "active ConnMan service is not connected ($state)" 1
            return 1
            ;;
    esac
    INTERFACE="$(printf '%s\n' "$props" | connman_property Ethernet Interface IPv4)"
    LISTEN_ADDRESS="$(printf '%s\n' "$props" | connman_property IPv4 Address IPv6)"
    [ -n "$INTERFACE" ] || {
        snapshot_fail "ConnMan service did not provide an Ethernet interface" 0
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
        127.*|0.0.0.0)
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
    bounded script -q -c connmanctl /dev/null < "$command_file" >/dev/null 2>&1
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
    expected_node="$(command -v "$NODE")" || return 1
    [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$(realpath "$expected_node")" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -qxF "$BUNDLE" || return 1
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
    bounded "$NODE" "$BUNDLE" \
        --listen-address "$HELPER_ADDRESS" \
        --listen-port "$HELPER_PORT" \
        --upstream "$UPSTREAM:53" \
        --upstream-bind-port "$HELPER_UPSTREAM_SPORT" \
        --upstream-tcp-port-start "$HELPER_UPSTREAM_TCP_PORT_START" \
        --upstream-tcp-port-end "$HELPER_UPSTREAM_TCP_PORT_END" \
        --blocklist "$BLOCKLIST" \
        --blocklist-format "$BLOCKLIST_FORMAT" \
        --check 2>&1
}

# The check's own output is the only description of the failure, and the callers
# discard it. Keep the head of it: a config error also prints the usage text.
log_artifact_output() {
    if [ -z "$1" ]; then
        log "artifact check produced no output"
        return 0
    fi
    printf '%s\n' "$1" | head -n 6 | while IFS= read -r line; do
        log "check: $line"
    done
}

artifact_metadata() {
    output="$(artifact_check_output)"
    result=$?
    if [ "$result" -ne 0 ]; then
        log_artifact_output "$output"
        return 1
    fi
    generation="$(printf '%s\n' "$output" | sed -n 's/.*generation=\([^;]*\);.*/\1/p')"
    declared="$(printf '%s\n' "$output" | sed -n 's/.*declared_rules=\([^;]*\);.*/\1/p')"
    unique="$(printf '%s\n' "$output" | sed -n 's/^ok: \([0-9][0-9]*\) blocklist rule(s).*/\1/p')"
    if [ -z "$generation" ] || [ "$generation" = "unknown" ] ||
        [ -z "$declared" ] || [ "$declared" = "unknown" ] || [ -z "$unique" ]; then
        log_artifact_output "$output"
        return 1
    fi
    printf '%s %s %s\n' "$generation" "$declared" "$unique"
}

helper_start() {
    [ -f "$BUNDLE" ] || die "DNS bundle not found: $BUNDLE"
    [ -f "$BLOCKLIST" ] || die "generated blocklist not found: $BLOCKLIST"
    require_command "$NODE"

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

    mkdir -p "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
    rm -f "$STATUS_FILE"
    : > "$LOG_FILE"
    nohup "$NODE" "$BUNDLE" \
        --listen-address "$HELPER_ADDRESS" \
        --listen-port "$HELPER_PORT" \
        --upstream "$UPSTREAM:53" \
        --upstream-bind-port "$HELPER_UPSTREAM_SPORT" \
        --upstream-tcp-port-start "$HELPER_UPSTREAM_TCP_PORT_START" \
        --upstream-tcp-port-end "$HELPER_UPSTREAM_TCP_PORT_END" \
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
            log "helper listening on $HELPER_ADDRESS:$HELPER_PORT (acknowledged generation $expected_generation)"
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
    stop_pid="$(helper_pid 2>/dev/null || true)"
    if [ -n "$stop_pid" ]; then
        # Revalidate the exact executable and command line before each signal;
        # a process can exit and its numeric PID can be reused while we wait.
        [ "$(helper_pid 2>/dev/null || true)" != "$stop_pid" ] || kill "$stop_pid" 2>/dev/null || true
        elapsed=0
        while [ "$(helper_pid 2>/dev/null || true)" = "$stop_pid" ] && [ "$elapsed" -lt 3 ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if [ "$(helper_pid 2>/dev/null || true)" = "$stop_pid" ]; then
            kill -KILL "$stop_pid" 2>/dev/null || true
            sleep 1
            if [ "$(helper_pid 2>/dev/null || true)" = "$stop_pid" ]; then
                log "DNS helper still running; retaining its recovery records"
                return 1
            fi
        fi
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

legacy_firewall_cleanup() {
    iptables -D INPUT -i "$INTERFACE" -p tcp --dport 53 -d "$LISTEN_ADDRESS" -j "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
    iptables -D INPUT -i "$INTERFACE" -p udp --dport 53 -d "$LISTEN_ADDRESS" -j "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
    if iptables -n -L "$LEGACY_FIREWALL_CHAIN" >/dev/null 2>&1; then
        iptables -F "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
    fi
    LEGACY_FIREWALL_STARTED=0
}

legacy_nameservers_restore() {
    # The old connMan-nameserver handoff pinned Nameservers to the TV's own
    # address. If the current settings still reflect that stale pin, restore
    # whatever was captured before the handoff ran.
    case "$LISTEN_ADDRESS" in
        ""|127.*|"$HELPER_ADDRESS")
            return 0
            ;;
    esac
    actual="$(connman_setting_value Nameservers | sed 's/;$//')"
    [ "$actual" = "$LISTEN_ADDRESS" ] || return 0
    if [ -n "$ORIGINAL_NAMESERVERS" ]; then
        old_values="$(printf '%s' "$ORIGINAL_NAMESERVERS" | sed 's/;$//' | tr ',;' '  ')"
        # Nameserver settings contain only IP literals.
        # shellcheck disable=SC2086
        connman_config --nameservers $old_values || return 1
    else
        connman_config --nameservers || return 1
    fi
    return 0
}

nat_on() {
    nat_off || true

    # The helper's upstream UDP socket is pinned to port $HELPER_UPSTREAM_SPORT,
    # which falls outside the system ephemeral range, so its outgoing upstream
    # queries bypass the divert and the rest of DNS is diverted to the helper.
    iptables -t nat -A OUTPUT -p udp --dport 53 -m udp --sport "$HELPER_UPSTREAM_SPORT" -j ACCEPT || {
        nat_off || true
        die "cannot exempt the helper upstream UDP socket"
    }
    iptables -t nat -A OUTPUT -p tcp --dport 53 -m tcp --sport "$HELPER_UPSTREAM_TCP_PORT_START:$HELPER_UPSTREAM_TCP_PORT_END" -j ACCEPT || {
        nat_off || true
        die "cannot exempt the helper upstream TCP sockets"
    }
    iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" || {
        nat_off || true
        die "cannot install DNS divert"
    }
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" || {
        nat_off || true
        die "cannot install DNS divert"
    }
    NAT_STARTED=1
    log "DNS divert active: outbound UDP/TCP port 53 diverted to $HELPER_ADDRESS:$HELPER_PORT; helper upstream pins UDP source port $HELPER_UPSTREAM_SPORT and rotates TCP source ports $HELPER_UPSTREAM_TCP_PORT_START:$HELPER_UPSTREAM_TCP_PORT_END"
}

nat_off() {
    iptables -t nat -D OUTPUT -p udp --dport 53 -m udp --sport "$HELPER_UPSTREAM_SPORT" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -m tcp --sport "$HELPER_UPSTREAM_TCP_PORT_START:$HELPER_UPSTREAM_TCP_PORT_END" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" 2>/dev/null || true
    NAT_STARTED=0
}

# ConnMan's resolv.conf lists ::1 before 127.0.0.1. With ConnMan IPv6 off, its
# proxy on ::1 keeps forwarding to the IPv6 upstream it learned earlier, from
# an address the interface no longer has, so those queries are never answered
# and every lookup waits out the resolver timeout before trying 127.0.0.1.
# There is no ip6tables on these kernels to divert ::1, so mount a resolv.conf
# that lists only 127.0.0.1, which the divert above sends to the helper. It is
# read-only so ConnMan cannot rewrite it in place.
resolv_target() {
    realpath "$RESOLV_CONF" 2>/dev/null
}

resolv_ours_active() {
    target="$(resolv_target)" || return 1
    grep -q " $target " /proc/mounts 2>/dev/null &&
        grep -qF "$RESOLV_MARKER" "$target" 2>/dev/null
}

resolv_on() {
    resolv_off
    target="$(resolv_target)" || die "cannot resolve $RESOLV_CONF"
    {
        echo "$RESOLV_MARKER"
        echo "nameserver 127.0.0.1"
    } > "$RESOLV_SOURCE" || die "cannot write $RESOLV_SOURCE"
    chmod 644 "$RESOLV_SOURCE" || die "cannot chmod $RESOLV_SOURCE"
    mount --bind "$RESOLV_SOURCE" "$target" || die "cannot mount $RESOLV_SOURCE over $target"
    if mount -o remount,bind,ro "$target"; then
        log "resolv.conf lists only 127.0.0.1 (read-only over $target)"
    else
        log "resolv.conf lists only 127.0.0.1, but could not be made read-only; ConnMan may rewrite it"
    fi
}

resolv_off() {
    n=0
    while resolv_ours_active && [ "$n" -lt 5 ]; do
        target="$(resolv_target)"
        umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || break
        n=$((n + 1))
    done
    rm -f "$RESOLV_SOURCE"
}

capture_original_connman() {
    ORIGINAL_NAMESERVERS="$(grep '^Nameservers=' "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true)"
    ORIGINAL_IPV6="$(grep '^IPv6.method=' "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true)"
    [ -n "$ORIGINAL_IPV6" ] || ORIGINAL_IPV6=auto
}

connman_setting_value() {
    setting_key="$1"
    grep "^${setting_key}=" "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true
}

configure_connman_ipv6_on() {
    case "$IPV6_MODE" in
        off)
            connman_config --ipv6 off ||
                die "could not set ConnMan IPv6 mode"
            grep -q "^IPv6.method=off" "$SETTINGS" ||
                die "ConnMan IPv6 setting was not persisted"
            log "ConnMan IPv6 mode=off"
            ;;
        preserve)
            log "ConnMan IPv6 configuration preserved"
            ;;
        *)
            die "invalid IPv6 mode: $IPV6_MODE"
            ;;
    esac
}

verify_connman_restore() {
    if [ "$IPV6_MODE" = "off" ]; then
        actual_ipv6="$(connman_setting_value IPv6.method)"
        [ "$actual_ipv6" = "$ORIGINAL_IPV6" ] || return 1
    fi
    return 0
}

configure_connman_off() {
    restore_ok=1
    [ -n "$ORIGINAL_IPV6" ] || ORIGINAL_IPV6=auto
    if [ "$IPV6_MODE" = "off" ]; then
        connman_config --ipv6 "$ORIGINAL_IPV6" || restore_ok=0
    else
        log "ConnMan IPv6 configuration was preserved"
    fi
    if [ "$restore_ok" -ne 1 ]; then
        log "ConnMan IPv6 rollback was incomplete; retaining handoff state"
        return 1
    fi
    verify_attempt=0
    while [ "$verify_attempt" -lt 5 ]; do
        verify_connman_restore && break
        verify_attempt=$((verify_attempt + 1))
        sleep 1
    done
    if ! verify_connman_restore; then
        log "ConnMan IPv6 setting did not reach its original value; retaining handoff state"
        return 1
    fi
    log "ConnMan IPv6 configuration restored"
}

enable_failed() {
    rc=$?
    trap - EXIT
    if [ -f "$STATE_FILE" ] && load_state; then
        resolv_off || true
        nat_off || true
        legacy_firewall_cleanup || true
        if configure_connman_off >/dev/null 2>&1 && legacy_nameservers_restore; then
            if helper_stop; then clear_state; else log "helper stop incomplete; retaining handoff state"; fi
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
    # ConnMan discovery reads service properties over busctl. webOS 4.x ships
    # without it; fail now instead of retrying discovery for 30 seconds.
    require_command busctl
    require_command iptables
    require_command ip
    require_command script
    require_command realpath
    if ! wait_for_service_snapshot; then
        if [ "$SNAPSHOT_RETRY" = "1" ]; then
            # 75 (EX_TEMPFAIL): no usable network yet, as at boot before Wi-Fi
            # connects. Nothing has changed, so the caller can retry later.
            echo "dns-filter: no usable ConnMan service yet: $SNAPSHOT_ERROR" >&2
            exit 75
        fi
        die "could not obtain one coherent active ConnMan snapshot: $SNAPSHOT_ERROR"
    fi
    capture_original_connman
    save_state
    helper_start
    configure_connman_ipv6_on
    nat_on
    if [ "$IPV6_MODE" = "off" ]; then
        resolv_on
    fi
    save_state
    trap - EXIT
    log "handoff enabled"
}

disable_handoff() {
    require_root
    if [ ! -f "$STATE_FILE" ]; then
        helper_stop || return 1
        resolv_off
        nat_off
        legacy_firewall_cleanup
        log "handoff already disabled"
        return 0
    fi
    load_state || die "invalid handoff state: $STATE_FILE"
    if ! legacy_nameservers_restore; then
        log "handoff remains enabled because legacy nameserver rollback failed"
        return 1
    fi
    if ! configure_connman_off; then
        log "handoff remains enabled because ConnMan rollback was incomplete"
        return 1
    fi
    legacy_firewall_cleanup
    resolv_off
    nat_off
    helper_stop || { log "DNS helper stop incomplete; state retained"; return 1; }
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
        echo "mode=redirect"
        echo "service=$SERVICE"
        echo "listener=$HELPER_ADDRESS:$HELPER_PORT"
        echo "upstream=$UPSTREAM:53"
        echo "interface=$INTERFACE"
        echo "helper=$(helper_running && echo running || echo stopped)"
        echo "connman_nameservers=$(grep '^Nameservers=' "$SETTINGS" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
        echo "connman_ipv6=$(grep '^IPv6.method=' "$SETTINGS" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
        echo "handoff_ipv6_mode=$IPV6_MODE"
        echo "resolv_conf=$(resolv_ours_active && echo ipv4-only || echo system)"
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
    echo "mode=redirect"
    echo "service=$SERVICE"
    echo "listener=$HELPER_ADDRESS:$HELPER_PORT"
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
