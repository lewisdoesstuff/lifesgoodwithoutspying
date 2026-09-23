#!/bin/sh
# lifesgoodwithoutspying - apply privacy hardening according to the configured options.
#
# Runs at boot via run-parts and on demand from the app UI.

DIR="$(dirname "$(realpath "$0")")"
. "$DIR/nospy-lib.sh"

LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"

# Homebrew Channel captures nothing from init.d scripts, so log ourselves.
mkdir -p /var/lib/webosbrew 2>/dev/null || true

# Log trimming
if [ -f "$LOG" ]; then
    size="$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$size" ] && [ "$size" -gt 65536 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
fi

exec >>"$LOG" 2>&1
echo "==== apply $(date) ===="

BLOCKDIR="$DIR/blocklist.d"
DOMAINS_TMP="/tmp/lifesgoodwithoutspying.domains.$$"
KEYS_TMP="/tmp/lifesgoodwithoutspying.keys.$$"
UNITS_TMP="/tmp/lifesgoodwithoutspying.units.$$"
EXECS_TMP="/tmp/lifesgoodwithoutspying.execs.$$"
APPS_TMP="/tmp/lifesgoodwithoutspying.apps.$$"

# Scratch files are per-run and multi-megabyte-free, but never cleaned before;
# remove them however we exit.
trap 'rm -f "$DOMAINS_TMP" "$KEYS_TMP" "$UNITS_TMP" "$EXECS_TMP" "$APPS_TMP"' EXIT

# Remove only our mounts from /etc/hosts
# webosbrew (and potentially other apps) may have mounts on this
unmount_ours() {
    n=0
    while hosts_ours_active && [ "$n" -lt 5 ]; do
        umount /etc/hosts 2>/dev/null || umount -l /etc/hosts 2>/dev/null || break
        n=$((n + 1))
    done
}

# Emit enabled domains. During the initial sink build, domains.sdp is held
# back so the other protections can take effect immediately.
collect_domains() {
    mode="$1"
    domain_keys > "$KEYS_TMP"
    while IFS= read -r key; do
        if [ "$key" = domains.sdp ] && [ "$mode" = initial ]; then
            # Enabled SDP is held back for the grace period; disabled SDP is
            # included immediately with the other categories.
            is_on "$key" && continue
        else
            is_on "$key" || continue
        fi
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$BLOCKDIR/$file" ] || continue
        grep -v '^[[:space:]]*#' "$BLOCKDIR/$file" | grep -v '^[[:space:]]*$'
    done < "$KEYS_TMP"
}

mount_generated_hosts() {
    count="$1"
    if mount --bind "$HOSTS_GEN" /etc/hosts; then
        echo "[+] /etc/hosts sink applied ($count domains)"
    else
        echo "[-] failed to bind-mount /etc/hosts"
        return 1
    fi
}

append_sdp_domains() {
    file="$(cat_file_for_key domains.sdp)"
    path="$BLOCKDIR/$file"
    [ -f "$path" ] || return 1
    grep -q 'nextlgsdp\.com' "$path" 2>/dev/null || return 1
    count="$(grep -v '^[[:space:]]*#' "$path" | grep -vc '^[[:space:]]*$')"
    {
        echo ""
        echo "$NOSPY_MARKER SDP clock-sync grace period complete"
        grep -v '^[[:space:]]*#' "$path" | while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "0.0.0.0 $domain"
            echo ":: $domain"
        done
    } >> "$HOSTS_GEN"
    echo "$count"
}

hosts_generation_active() {
    grep -qF "$NOSPY_MARKER generation $1" /etc/hosts 2>/dev/null
}

# Add SDP to the already-mounted sink after LG has had time to consume
# X-Server-Time. Run asynchronously so boot hooks and UI calls return
# immediately. A generation token invalidates the worker if settings are
# re-applied or protection is disabled during the grace period.
schedule_sdp_block() {
    token="$1"
    (
        trap - EXIT HUP INT TERM
        trap '' HUP
        sleep 1
        waited=1
        while [ "$waited" -lt "$CLOCK_SYNC_DELAY" ]; do
            pending_hosts_current "$token" || exit 0
            sleep 1
            waited=$((waited + 1))
        done
        pending_hosts_current "$token" || exit 0
        if ! is_on domains.sdp; then
            pending_hosts_clear "$token"
            exit 0
        fi
        if ! hosts_generation_active "$token"; then
            pending_hosts_clear "$token"
            exit 0
        fi
        if ! hosts_ours_active; then
            echo "[-] our /etc/hosts sink disappeared during SDP grace period"
        elif [ "$(append_sdp_domains)" -gt 0 ] 2>/dev/null; then
            echo "[+] SDP domains blocked after ${CLOCK_SYNC_DELAY}s clock-sync grace period"
        else
            echo "[-] failed to add SDP domains after clock-sync grace period"
        fi
        pending_hosts_clear "$token"
    ) &
    pending_pid=$!
    printf '%s %s\n' "$pending_pid" "$token" > "$HOSTS_PENDING"
    echo "[~] SDP blocked after ${CLOCK_SYNC_DELAY}s; other domain blocks are active"
}

# hosts blocking
apply_hosts() {
    if [ ! -f /etc/hosts ]; then
        echo "[-] /etc/hosts not found; refusing to touch the domain sink"
        return 1
    fi
    if [ ! -d "$BLOCKDIR" ]; then
        echo "[-] blocklist dir missing ($BLOCKDIR); skipping domain sink"
        return 1
    fi

    # Invalidate an older delayed worker, then remove only our previous mount,
    # leaving whatever is underneath.
    pending_hosts_cancel
    unmount_ours

    collect_domains initial > "$DOMAINS_TMP"
    count="$(grep -c . "$DOMAINS_TMP" 2>/dev/null)"
    [ -n "$count" ] || count=0
    sdp_pending=0
    is_on domains.sdp && sdp_pending=1
    generation="$(date +%s)-$$"

    if [ "$count" -eq 0 ] && [ "$sdp_pending" -eq 0 ]; then
        echo "[~] no domain categories enabled; our sink is off"
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 0
    fi

    cp /etc/hosts "$HOSTS_GEN" || return 1
    {
        echo ""
        echo "$NOSPY_MARKER generation $generation"
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "0.0.0.0 $domain"
            echo ":: $domain"
        done < "$DOMAINS_TMP"
    } >> "$HOSTS_GEN"

    # All non-SDP blocks are active immediately. If SDP is enabled, append it
    # to this same mounted inode after the clock-sync grace period.
    if ! mount_generated_hosts "$count"; then
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 1
    fi
    if [ "$sdp_pending" -eq 1 ]; then
        schedule_sdp_block "$generation"
    fi
    rm -f "$DOMAINS_TMP" "$KEYS_TMP"
}

# Common apply for the stub-based categories.
#
# Turning a toggle on stops the category's units, bind-mounts an inert stub
# over each target executable, then kills whatever was already running.
# Turning it off unwinds both, so a toggle is not a one-way door.
apply_stub_category() {
    key="$1"
    unit_fn="$2"
    exec_fn="$3"

    if ! is_on "$key"; then
        stub_clear_key "$key"
        if command -v systemctl >/dev/null 2>&1; then
            "$unit_fn" > "$UNITS_TMP"
            while IFS= read -r unit; do
                [ -n "$unit" ] || continue
                # --no-block: these units take the full 90s stop/start timeout
                # otherwise, which would stall the whole apply.
                systemctl --no-block start "$unit" >/dev/null 2>&1
            done < "$UNITS_TMP"
        fi
        echo "[~] $key disabled"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        "$unit_fn" > "$UNITS_TMP"
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            systemctl --no-block stop "$unit" >/dev/null 2>&1
        done < "$UNITS_TMP"
    fi

    stub_write
    stub_clear_key "$key"
    "$exec_fn" > "$EXECS_TMP"
    n=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if stub_mount "$key" "$path"; then
            n=$((n + 1))
        fi
    done < "$EXECS_TMP"
    echo "[+] $key: stubbed $n executable(s)"

    kill_by_paths "$EXECS_TMP"
}

# Ad / ACR / telemetry daemons.
apply_ads() {
    apply_stub_category ads.stop ads_units ads_execs
}

# Voice services, and the voice app if it is already up.
apply_voice() {
    apply_stub_category voice.stop voice_units voice_execs
    if is_on voice.stop; then
        voice_apps > "$APPS_TMP"
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            app_close "$id"
        done < "$APPS_TMP"
    fi
}

# ThinQ / Alexa / IoT companions (opt-in through domains.thinq).
apply_thinq() {
    apply_stub_category domains.thinq thinq_units thinq_execs
}

# LAN discovery (ssdp/upnp)
apply_lan() {
    if ! is_on lan.block; then
        # Put the real binary back and clear any stub process that outlived its
        # mount. A stub shell still holds the "upnpd" name, so the supervisor
        # would not spawn the real binary until it is gone.
        upnp_unstub
        # Ensure discovery is running. Both are cheap when it already is:
        # ssdp_restore is async, and upnp_restore skips the luna ping when a
        # real upnpd is up.
        ssdp_restore
        upnp_restore
        return 0
    fi
    if [ ! -f /usr/sbin/upnpd ]; then
        echo "[-] /usr/sbin/upnpd not found; skipping lan block"
        return 1
    fi
    if ! head -n 2 /usr/sbin/upnpd 2>/dev/null | grep -q 'nospy-upnpd-stub'; then
        if mount --bind "$DIR/nospy-upnpd-stub" /usr/sbin/upnpd; then
            echo "[+] stubbed /usr/sbin/upnpd"
        else
            echo "[-] failed to stub /usr/sbin/upnpd"
            return 1
        fi
    else
        echo "[~] upnpd stub already mounted"
    fi
    # mount first, then kill: anything forked after this gets the stub.
    # Children are killed too, so a stub shell's long sleep is not orphaned.
    pids="$(pgrep upnpd 2>/dev/null | tr '\n' ' ')"
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill_with_children "$pid"
        done
        echo "[+] killed running upnpd"
    fi
    # the watcher used to keep ssdp down; do it here now.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-block stop ssdp-discovery-lgtv >/dev/null 2>&1 || true
    fi
    if pkill -9 ssdp 2>/dev/null; then
        echo "[+] killed ssdp"
    fi
}

apply_purge() {
    if is_on purge.boot; then
        purge_residue
    fi
}

apply_hosts
apply_ads
apply_voice
apply_thinq
apply_lan
apply_purge

echo "==== done ===="
