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
HOSTS_GEN="/var/lib/webosbrew/lifesgoodwithoutspying.hosts"
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

# Emit every domain belonging to an enabled category.
collect_domains() {
    domain_keys > "$KEYS_TMP"
    while IFS= read -r key; do
        is_on "$key" || continue
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$BLOCKDIR/$file" ] || continue
        grep -v '^[[:space:]]*#' "$BLOCKDIR/$file" | grep -v '^[[:space:]]*$'
    done < "$KEYS_TMP"
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

    # Remove only our previous mount, leaving whatever is underneath.
    unmount_ours

    collect_domains > "$DOMAINS_TMP"
    count="$(grep -c . "$DOMAINS_TMP" 2>/dev/null)"
    [ -n "$count" ] || count=0

    if [ "$count" -eq 0 ]; then
        echo "[~] no domain categories enabled; our sink is off"
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 0
    fi

    cp /etc/hosts "$HOSTS_GEN" || return 1
    {
        echo ""
        echo "$NOSPY_MARKER"
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "0.0.0.0 $domain"
            echo ":: $domain"
        done < "$DOMAINS_TMP"
    } >> "$HOSTS_GEN"

    if mount --bind "$HOSTS_GEN" /etc/hosts; then
        echo "[+] /etc/hosts sink applied ($count domains)"
    else
        echo "[-] failed to bind-mount /etc/hosts"
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 1
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
        # put the real binary back if ours is mounted
        if head -n 2 /usr/sbin/upnpd 2>/dev/null | grep -q 'nospy-upnpd-stub'; then
            if umount /usr/sbin/upnpd 2>/dev/null || umount -l /usr/sbin/upnpd 2>/dev/null; then
                echo "[+] restored /usr/sbin/upnpd"
                # we had been blocking, so bring the discovery daemons back up
                ssdp_restore
                upnp_restore
            fi
        fi
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
    # mount first, then kill: anything forked after this gets the stub
    if pkill -9 upnpd 2>/dev/null; then
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
