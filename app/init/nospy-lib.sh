#!/bin/sh
# lifesgoodwithoutspying shared helpers

CONF="/var/lib/webosbrew/lifesgoodwithoutspying.conf"
HOSTS_GEN="/var/lib/webosbrew/lifesgoodwithoutspying.hosts"
HOSTS_PENDING="/var/lib/webosbrew/lifesgoodwithoutspying.hosts-pending"
CLOCK_SYNC_DELAY=60

# Defaults
conf_default() {
    case "$1" in
        domains.acr)        echo on ;;
        domains.smartad)    echo on ;;
        domains.dashboard)  echo on ;;
        domains.telemetry)  echo on ;;
        domains.sdp)        echo on ;;
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
        domains.sdp domains.lgchannels domains.updates domains.thinq \
        voice.stop ads.stop lan.block purge.boot
}

# Newline-separated list of domain category keys.
domain_keys() {
    printf '%s\n' \
        domains.smartad domains.acr domains.dashboard domains.telemetry \
        domains.sdp domains.lgchannels domains.updates domains.thinq
}

# Map a blocklist category key to its blocklist file name.
cat_file_for_key() {
    case "$1" in
        domains.smartad)    echo "10-smartad.txt" ;;
        domains.acr)        echo "20-acr.txt" ;;
        domains.dashboard)  echo "30-dashboard.txt" ;;
        domains.telemetry)  echo "40-telemetry.txt" ;;
        domains.sdp)        echo "45-sdp.txt" ;;
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

# A pending SDP grace-period update is identified by a token so an older
# delayed worker cannot modify a newer hosts file after a re-apply or disable.
pending_hosts_current() {
    [ -f "$HOSTS_PENDING" ] || return 1
    read -r pending_pid pending_token < "$HOSTS_PENDING"
    [ -n "$pending_pid" ] && [ "$pending_token" = "$1" ] || return 1
    kill -0 "$pending_pid" 2>/dev/null
}

pending_hosts_clear() {
    [ -f "$HOSTS_PENDING" ] || return 0
    read -r pending_pid pending_token < "$HOSTS_PENDING"
    [ "$pending_token" = "$1" ] && rm -f "$HOSTS_PENDING"
    return 0
}

pending_hosts_cancel() {
    rm -f "$HOSTS_PENDING"
}

hosts_pending() {
    [ -f "$HOSTS_PENDING" ] || return 1
    read -r pending_pid pending_token < "$HOSTS_PENDING"
    [ -n "$pending_pid" ] && [ -n "$pending_token" ] || return 1
    kill -0 "$pending_pid" 2>/dev/null
}

# Exit 0 only if OUR generated file is the mount currently on top of /etc/hosts.
hosts_ours_active() {
    grep -qF "$NOSPY_MARKER" /etc/hosts 2>/dev/null
}

# Print the state of /etc/hosts: waiting | ours | external | open.
hosts_state() {
    if hosts_pending; then
        echo "waiting"
    elif ! hosts_is_mounted; then
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

# Print "<pid> <exe-path>" for every process in one pass. readlink/grep per pid
# costs hundreds of forks, which is seconds slow on a TV this busy.
proc_exe_table() {
    ls -l /proc/[0-9]*/exe 2>/dev/null | awk '
        {
            target = ""
            pid_field = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "->") target = $(i + 1)
                else if ($i ~ /^\/proc\/[0-9]+\/exe$/) pid_field = $i
            }
            if (target == "" || pid_field == "") next
            sub(/^\/proc\//, "", pid_field)
            sub(/\/exe$/, "", pid_field)
            print pid_field, target
        }'
}

# Pids whose exact exe path is listed in the given file.
pids_for_paths() {
    list="$1"
    [ -f "$list" ] || return 0
    proc_exe_table | awk -v list="$list" '
        BEGIN { while ((getline line < list) > 0) want[line] = 1; close(list) }
        $2 in want { print $1 }'
}

# Kill every process whose exact exe path is listed in the given file. This
# catches the copies already running when the stub was mounted; the stub stops
# anything Luna starts afterwards.
kill_by_paths() {
    list="$1"
    [ -f "$list" ] || return 0
    pids="$(pids_for_paths "$list" | tr '\n' ' ')"
    [ -n "$pids" ] || return 0
    kill -TERM $pids 2>/dev/null
    sleep 1
    # a copy that ignored SIGTERM, or one Luna respawned in the meantime
    pids="$(pids_for_paths "$list" | tr '\n' ' ')"
    [ -n "$pids" ] || return 0
    kill -KILL $pids 2>/dev/null
    echo "[+] stopped target pid(s): $pids"
}

# Count live processes whose exact exe path is listed in the given file.
count_running_paths() {
    list="$1"
    [ -f "$list" ] || { echo 0; return 0; }
    proc_exe_table | awk -v list="$list" '
        BEGIN { while ((getline line < list) > 0) want[line] = 1; close(list) }
        $2 in want { n++ }
        END { print n + 0 }'
}

# Delete locally buffered ACR / speech-to-text files. Our own scratch files are
# excluded by name: they live in /tmp and match "voice", so without this a
# concurrent apply would delete the list a running status call is reading.
purge_residue() {
    total=0
    for base in /var/log /tmp /var/run; do
        [ -d "$base" ] || continue
        n="$(find "$base" -maxdepth 3 -type f ! -name 'lifesgoodwithoutspying*' \
            \( -iname '*acr*' -o -iname '*voice*' -o -iname '*alphonso*' -o -iname '*stt*' \) \
            2>/dev/null | wc -l)"
        [ "$n" -gt 0 ] || continue
        find "$base" -maxdepth 3 -type f ! -name 'lifesgoodwithoutspying*' \
            \( -iname '*acr*' -o -iname '*voice*' -o -iname '*alphonso*' -o -iname '*stt*' \) \
            -exec rm -f {} + 2>/dev/null
        total=$((total + n))
    done
    if [ "$total" -gt 0 ]; then
        echo "[+] purged $total ACR/voice residue file(s)"
    else
        echo "[~] no ACR/voice residue found"
    fi
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
            systemctl --no-block start "$unit" >/dev/null 2>&1
        done
    return 0
}

# Restart the SSDP discovery daemon that apply_lan stops.
ssdp_restore() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl --no-block start ssdp-discovery-lgtv >/dev/null 2>&1; then
        echo "[+] restarted ssdp-discovery-lgtv"
    fi
}

# True if the real upnpd daemon is running (as opposed to our stub shell).
# Candidates are matched by comm, which is the basename of the executed file:
# for the stub that is the script name "upnpd", the same as the real binary.
# The exe link is what tells the two apart.
upnp_running() {
    for pid in $(pgrep upnpd 2>/dev/null); do
        case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
            */upnpd) return 0 ;;
        esac
    done
    return 1
}

# Kill a pid and its direct children. The upnpd stub is a shell script whose
# child is a very long sleep; killing only the shell would orphan the sleep.
kill_with_children() {
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill -9 "$child" 2>/dev/null
    done
    kill -9 "$1" 2>/dev/null
}

# Undo the upnpd stub: unmount it, then kill the stub shells the unmount leaves
# behind. A stub shell still holds the "upnpd" name, so the service supervising
# it would not spawn the real binary until it is gone. The exe check keeps a
# healthy real upnpd alive.
#
# Returns 0 if it unstubbed something, 1 if there was nothing to do.
upnp_unstub() {
    changed=0
    if head -n 2 /usr/sbin/upnpd 2>/dev/null | grep -q 'nospy-upnpd-stub'; then
        if umount /usr/sbin/upnpd 2>/dev/null || umount -l /usr/sbin/upnpd 2>/dev/null; then
            echo "[+] restored /usr/sbin/upnpd"
            changed=1
        else
            # Still mounted: killing the stub would only make the supervisor
            # respawn it, so leave it for a later run.
            echo "[-] failed to unmount /usr/sbin/upnpd"
            return 1
        fi
    fi
    for pid in $(pgrep upnpd 2>/dev/null); do
        case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
            */upnpd) ;; # real daemon, leave it alone
            *) kill_with_children "$pid"
               echo "[+] killed lingering upnpd stub ($pid)"
               changed=1 ;;
        esac
    done
    if [ "$changed" -eq 1 ]; then
        sleep 1
        return 0
    fi
    return 1
}

# upnpd has no systemd unit of its own: it is spawned by
# com.webos.service.upnp, which luna starts on demand. Pinging that service is
# what LG's own bootmode-firstuse.service does to bring UPnP up.
upnp_restore() {
    command -v luna-send >/dev/null 2>&1 || return 0
    # Already up: skip the luna round-trip, which can block for its timeout.
    upnp_running && return 0
    if command -v script >/dev/null 2>&1; then
        bounded script -q -c \
            "luna-send -n 1 -f luna://com.webos.service.upnp/com/palm/luna/private/ping '{}'" \
            /dev/null >/dev/null 2>&1
    else
        bounded luna-send -n 1 -f \
            luna://com.webos.service.upnp/com/palm/luna/private/ping '{}' \
            >/dev/null 2>&1
    fi
    echo "[+] asked com.webos.service.upnp to start upnpd"
}

# Put back everything the toggles may have stopped: unstub the executables
# first, then let the units come back up.
services_restore() {
    stub_clear_all
    upnp_unstub
    units_restore
    ssdp_restore
    upnp_restore
}
