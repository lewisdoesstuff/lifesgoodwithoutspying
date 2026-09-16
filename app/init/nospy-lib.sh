#!/bin/sh
# lifesgoodwithoutspying shared helpers

CONF="/var/lib/webosbrew/lifesgoodwithoutspying.conf"

# Defaults
conf_default() {
    case "$1" in
        domains.acr)        echo on ;;
        domains.smartad)    echo on ;;
        domains.dashboard)  echo on ;;
        domains.telemetry)  echo on ;;
        domains.lgchannels) echo off ;;
        domains.updates)    echo off ;;
        domains.thinq)      echo off ;;
        voice.stop)         echo on ;;
        ads.stop)           echo on ;;
        lan.block)          echo off ;;
        purge.boot)         echo on ;;
        *)                  echo off ;;
    esac
}

# Print the value of a config key, or its default.
conf_get() {
    key="$1"
    if [ -f "$CONF" ]; then
        v="$(grep "^$key=" "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
        if [ -n "$v" ]; then
            echo "$v"
            return 0
        fi
    fi
    conf_default "$key"
}

# Exit 0 if the key is "on".
is_on() {
    [ "$(conf_get "$1")" = "on" ]
}

# Persist a key=value pair.
conf_set() {
    key="$1"
    val="$2"
    mkdir -p "$(dirname "$CONF")"
    if [ -f "$CONF" ]; then
        grep -v "^$key=" "$CONF" > "$CONF.tmp" 2>/dev/null || : > "$CONF.tmp"
    else
        : > "$CONF.tmp"
    fi
    echo "$key=$val" >> "$CONF.tmp"
    mv "$CONF.tmp" "$CONF"
}

# Newline-separated list of every toggleable key.
conf_keys() {
    printf '%s\n' \
        domains.acr domains.smartad domains.dashboard domains.telemetry \
        domains.lgchannels domains.updates domains.thinq \
        voice.stop ads.stop lan.block purge.boot
}

# Newline-separated list of blocklist category keys.
domain_keys() {
    printf '%s\n' \
        domains.smartad domains.acr domains.dashboard domains.telemetry \
        domains.lgchannels domains.updates domains.thinq
}

# Map a blocklist category key to its blocklist file name.
cat_file_for_key() {
    case "$1" in
        domains.smartad)    echo "10-smartad.txt" ;;
        domains.acr)        echo "20-acr.txt" ;;
        domains.dashboard)  echo "30-dashboard.txt" ;;
        domains.telemetry)  echo "40-telemetry.txt" ;;
        domains.thinq)      echo "50-thinq.txt" ;;
        domains.lgchannels) echo "80-lgchannels.txt" ;;
        domains.updates)    echo "90-updates.txt" ;;
        *)                  echo "" ;;
    esac
}

# Exit 0 if our bind mount is currently over /etc/hosts.
hosts_is_mounted() {
    grep -q ' /etc/hosts ' /proc/mounts 2>/dev/null
}

# Distinctive header written into our generated hosts file, used to tell our
# mount apart from anyone else's.
NOSPY_MARKER="# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints"

# Exit 0 only if OUR generated file is the mount currently on top of /etc/hosts.
hosts_ours_active() {
    grep -qF "$NOSPY_MARKER" /etc/hosts 2>/dev/null
}

# Print the state of /etc/hosts: ours | external | open.
hosts_state() {
    if ! hosts_is_mounted; then
        echo "open"
    elif hosts_ours_active; then
        echo "ours"
    else
        echo "external"
    fi
}

# Run a command with a timeout when one is available to avoid a hang blocking boot
bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 "$@"
    else
        "$@"
    fi
}

# True if our watcher loop is currently running.
watch_running() {
    ps aux 2>/dev/null | grep -q '[n]ospy-watch\.sh'
}

# (Re)start the watcher if any kill-toggle is on. Silent when already up.
watch_ensure() {
    if ! is_on voice.stop && ! is_on ads.stop && ! is_on lan.block; then
        return 0
    fi
    if watch_running; then
        return 0
    fi
    # Detach fully: ignore HUP so that closing the ssh session (or the HBC
    # exec call) that started us doesn't take the loop down too.
    (trap '' HUP; sh "$DIR/nospy-watch.sh" >/dev/null 2>&1 < /dev/null &) 2>/dev/null
    echo "[+] started nospy-watch"
}

# Stop the watcher, if running.
watch_stop() {
    if watch_running; then
        pkill -f '[n]ospy-watch\.sh' 2>/dev/null
        echo "[+] stopped nospy-watch"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Restore helpers.
#
# The apply_* functions stop services. These put them back when a toggle is
# switched off or protection is disabled. Without them a service we killed
# stays down until the next reboot, which is surprising from the UI.
# ---------------------------------------------------------------------------

# Start the voice units again after they have been stopped/killed.
voice_restore() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl start voiceinput voiceconductor >/dev/null 2>&1; then
        echo "[+] restarted voiceinput + voiceconductor"
    else
        echo "[~] could not restart voice units"
    fi
}

# Restart the SSDP discovery daemon that apply_lan pkill's.
ssdp_restore() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl start ssdp-discovery-lgtv >/dev/null 2>&1; then
        echo "[+] restarted ssdp-discovery-lgtv"
    fi
}

# upnpd has no systemd unit of its own: it is spawned by
# com.webos.service.upnp, which luna starts on demand. Pinging that service is
# what LG's own bootmode-firstuse.service does to bring UPnP up.
upnp_restore() {
    command -v luna-send >/dev/null 2>&1 || return 0
    bounded luna-send -n 1 -f \
        luna://com.webos.service.upnp/com/palm/luna/private/ping '{}' \
        >/dev/null 2>&1
    echo "[+] asked com.webos.service.upnp to start upnpd"
}

# Put back everything the kill-toggles may have stopped. Safe to call when
# they are already running.
services_restore() {
    voice_restore
    ssdp_restore
    upnp_restore
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start livepick >/dev/null 2>&1 || true
    fi
}
