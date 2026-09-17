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

# Process targets.
#
# LG starts most of these from the Luna hub (ls-hubd), so killing a process only
# gets it respawned. Instead we bind-mount an inert stub over the executable:
# the next exec exits immediately, with no polling loop needed. Matching is by
# exact /proc/<pid>/exe path, so jailed copies count too. Paths that do not
# exist on a given build are skipped at apply time.

# Candidate paths for one daemon name: the canonical directories plus any
# per-app jail copy. Jails hardlink the /usr/sbin binaries and a process may run
# from the jail path rather than the host one, so both need stubbing. Unmatched
# jail globs stay literal and are skipped by stub_mount's -f test.
target_paths() {
    printf '%s\n' "/usr/sbin/$1" "/usr/bin/$1"
    printf '%s\n' /var/palm/jail/*/usr/sbin/"$1" /var/palm/jail/*/usr/bin/"$1"
}

# Ad / ACR / telemetry executables.
ads_execs() {
    for name in admanager livepick acr2 nudge rdxd uploadd sportsalarm \
                adoverlay-service; do
        target_paths "$name"
    done
    # app launchers that fork the daemons above
    printf '%s\n' /usr/bin/com.webos.app.livepick /usr/bin/com.webos.app.livepick-full
}

# Units the ad / telemetry daemons run under.
ads_units() {
    printf '%s\n' livepick.service nudge.service rdxd.service uploadd.service
}

# Voice / wake-word / NLP executables, plus the voice app launcher.
voice_execs() {
    for name in voiceinput voiceinput_network voiceinput_preprocessor \
                voiceinput_hidraw voiceinput_sound voiceconductor voiceclick \
                nlpmanager performer; do
        target_paths "$name"
    done
    printf '%s\n' /usr/bin/com.webos.app.voice
}

voice_units() {
    printf '%s\n' voiceinput.service voiceconductor.service
}

# Apps to ask the application manager to close. They run inside WebAppMgr, so
# exact-path matching cannot see them.
voice_apps() {
    printf '%s\n' com.webos.app.voice
}

# ThinQ / Alexa / IoT executables (acted on only when domains.thinq is on).
thinq_execs() {
    for name in trigger_thinq trigger_alexa iot-proxy iot-client mqtt-client \
                lg.thinqai.adapter amazon-alexa-adapter amazon-alexa-vsk; do
        target_paths "$name"
    done
    # iot-client also runs from its service directory
    printf '%s\n' /usr/palm/services/com.webos.service.iotclient/iot-client
}

thinq_units() {
    printf '%s\n' iot-client.service
}

# Inert stub bind-mounted over each blocked executable.
STUB_FILE="/var/lib/webosbrew/lifesgoodwithoutspying.stub"

# Records "<category> <path>" for every executable we currently have stubbed.
STUB_STATE="/var/lib/webosbrew/lifesgoodwithoutspying.stubbed"

# Write the stub body once.
stub_write() {
    mkdir -p /var/lib/webosbrew 2>/dev/null || true
    printf '#!/bin/sh\nexit 0\n' > "$STUB_FILE"
    chmod 755 "$STUB_FILE"
}

# Bind the stub over one executable and remember it.
stub_mount() {
    key="$1"
    path="$2"
    [ -f "$path" ] || return 1
    mount --bind "$STUB_FILE" "$path" 2>/dev/null || return 1
    echo "$key $path" >> "$STUB_STATE"
    return 0
}

# Unmount everything stubbed for one category.
stub_clear_key() {
    key="$1"
    [ -f "$STUB_STATE" ] || return 0
    awk -v k="$key" '$1 == k { print $2 }' "$STUB_STATE" |
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            umount "$path" 2>/dev/null || umount -l "$path" 2>/dev/null
        done
    awk -v k="$key" '$1 != k' "$STUB_STATE" > "$STUB_STATE.tmp" 2>/dev/null ||
        : > "$STUB_STATE.tmp"
    mv "$STUB_STATE.tmp" "$STUB_STATE"
}

# Unmount every stub we own.
stub_clear_all() {
    [ -f "$STUB_STATE" ] || return 0
    awk '{ print $2 }' "$STUB_STATE" |
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            umount "$path" 2>/dev/null || umount -l "$path" 2>/dev/null
        done
    rm -f "$STUB_STATE"
}

# How many executables we currently have stubbed.
stub_count() {
    if [ -f "$STUB_STATE" ]; then
        grep -c . "$STUB_STATE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Exact executable path for a pid, with the " (deleted)" marker removed.
exe_path() {
    path="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
    [ -n "$path" ] || return 1
    echo "${path% (deleted)}"
}

# Kill every process whose exact exe path is listed in the given file. This
# catches the copies already running when the stub was mounted; the stub stops
# anything Luna starts afterwards.
kill_by_paths() {
    list="$1"
    [ -f "$list" ] || return 0
    pids=""
    for entry in /proc/[0-9]*; do
        path="$(exe_path "${entry#/proc/}")" || continue
        if grep -Fqx "$path" "$list"; then
            pids="$pids ${entry#/proc/}"
        fi
    done
    [ -n "$pids" ] || return 0
    kill -TERM $pids 2>/dev/null
    sleep 1
    for pid in $pids; do
        path="$(exe_path "$pid")" || continue
        if grep -Fqx "$path" "$list"; then
            kill -KILL "$pid" 2>/dev/null
        fi
    done
    echo "[+] stopped running target(s):$pids"
}

# Count live processes matching the exact paths in the given file.
count_running_paths() {
    list="$1"
    n=0
    [ -f "$list" ] || { echo 0; return 0; }
    for entry in /proc/[0-9]*; do
        path="$(exe_path "${entry#/proc/}")" || continue
        grep -Fqx "$path" "$list" && n=$((n + 1))
    done
    echo "$n"
}

# Print the process id of a running app, or nothing. luna-send only emits
# output when it has a tty, so run it under script(1). Both service spellings
# exist across webOS versions, so try each.
app_pid() {
    command -v luna-send >/dev/null 2>&1 || return 0
    command -v script >/dev/null 2>&1 || return 0
    for svc in com.webos.applicationManager com.webos.service.applicationmanager; do
        running="$(bounded script -q -c \
            "luna-send -n 1 -f luna://$svc/running '{}'" \
            /dev/null 2>/dev/null)" || continue
        pid="$(printf '%s\n' "$running" | tr '{},' '\n' | awk -v id="$1" '
            index($0, "\"id\"") && index($0, id) { want = 1; next }
            want && index($0, "\"processid\"") { gsub(/[^0-9]/, ""); print; exit }')"
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
    done
}

# Ask the application manager to close an app by id. Both service spellings are
# tried; closing an app that is already down fails harmlessly.
app_close() {
    for id in "$@"; do
        [ -n "$id" ] || continue
        pid="$(app_pid "$id")"
        [ -n "$pid" ] || continue
        for svc in com.webos.applicationManager com.webos.service.applicationmanager; do
            bounded script -q -c \
                "luna-send -n 1 -f luna://$svc/close '{\"processId\":\"$pid\"}'" \
                /dev/null >/dev/null 2>&1
        done
        echo "[+] asked the application manager to close $id (pid $pid)"
    done
}

# ---------------------------------------------------------------------------
# Restore helpers.
#
# Applying stubs executables and stops services. These put everything back when
# a toggle is switched off or protection is disabled. Without them a service
# stays down until the next reboot, which is surprising from the UI.
# ---------------------------------------------------------------------------

# Start every unit we may have stopped. Safe when already running.
units_restore() {
    command -v systemctl >/dev/null 2>&1 || return 0
    { ads_units; voice_units; thinq_units; } | sort -u |
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            systemctl start "$unit" >/dev/null 2>&1
        done
    return 0
}

# Restart the SSDP discovery daemon that apply_lan stops.
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

# Put back everything the toggles may have stopped: unstub the executables
# first, then let the units come back up.
services_restore() {
    stub_clear_all
    units_restore
    ssdp_restore
    upnp_restore
}
