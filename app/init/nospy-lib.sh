#!/bin/sh
# lifesgoodwithoutspying shared helpers

CONF="/var/lib/webosbrew/lifesgoodwithoutspying.conf"
CONF_APPLIED="/var/lib/webosbrew/lifesgoodwithoutspying.conf-applied"
HOSTS_GEN="/var/lib/webosbrew/lifesgoodwithoutspying.hosts"
HOSTS_PENDING="/var/lib/webosbrew/lifesgoodwithoutspying.hosts-pending"
DNS_BLOCKLIST="/var/lib/webosbrew/lifesgoodwithoutspying.dns"
CLOCK_SYNC_DELAY=60
# Token of the current NTP clock worker; removing it stops the worker.
NTP_TOKEN="/tmp/lifesgoodwithoutspying.ntp"
# Token of the worker that starts the DNS filter once the network is up.
DNS_RETRY_TOKEN="/tmp/lifesgoodwithoutspying.dns-retry"

# Defaults
conf_default() {
    case "$1" in
        domains.acr)        echo on ;;
        domains.smartad)    echo on ;;
        domains.quickset)   echo off ;;
        domains.dashboard)  echo on ;;
        domains.lgrecommends) echo off ;;
        domains.wiselg)     echo off ;;
        domains.telemetry)  echo on ;;
        domains.sdp)        echo on ;;
        clock.ntp)          echo off ;;
        domains.lgchannels) echo off ;;
        domains.updates)    echo off ;;
        domains.thinq)      echo off ;;
        dns.filter)         echo off ;;
        dns.disable_ipv6)   echo off ;;
        voice.stop)         echo on ;;
        ads.stop)           echo on ;;
        lan.block)          echo off ;;
        purge.boot)         echo off ;;
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

# Cut a log back to its last 200 lines once it passes 64 KiB. The file is
# replaced, so call this before opening the log for writing: output from an
# already-open descriptor would land in the discarded copy.
log_trim() {
    [ -f "$1" ] || return 0
    size="$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$size" ] && [ "$size" -gt 65536 ]; then
        tail -n 200 "$1" > "$1.tmp" 2>/dev/null && mv "$1.tmp" "$1"
    fi
}

# Exit 0 if the key is "on".
is_on() {
    [ "$(conf_get "$1")" = "on" ]
}

# Print every key with the value it has in the given settings file (default
# when unset), so two files can be compared by what they mean.
# The file is read once, as status calls this on every poll and a lookup per
# key costs several processes. As in conf_get, the last line for a key wins and
# an empty value means the default.
conf_effective() {
    for key in $(conf_keys); do
        printf '%s=' "$key"
        conf_default "$key"
    done | awk -v file="$1" '
        BEGIN {
            while ((getline line < file) > 0) {
                i = index(line, "=")
                if (i > 1) value[substr(line, 1, i - 1)] = substr(line, i + 1)
            }
        }
        {
            key = substr($0, 1, index($0, "=") - 1)
            if (value[key] != "") print key "=" value[key]
            else print
        }'
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
        domains.acr domains.smartad domains.quickset domains.dashboard domains.lgrecommends \
        domains.telemetry domains.sdp clock.ntp domains.lgchannels domains.updates \
        domains.thinq domains.wiselg dns.filter dns.disable_ipv6 voice.stop ads.stop lan.block purge.boot
}

# Newline-separated list of domain category keys.
domain_keys() {
    printf '%s\n' \
        domains.smartad domains.quickset domains.acr domains.dashboard domains.lgrecommends \
        domains.telemetry domains.sdp domains.lgchannels domains.updates \
        domains.thinq domains.wiselg
}

# Map a blocklist category key to its blocklist file name.
cat_file_for_key() {
    case "$1" in
        domains.smartad)    echo "10-smartad.txt" ;;
        domains.quickset)   echo "15-quickset.txt" ;;
        domains.acr)        echo "20-acr.txt" ;;
        domains.dashboard)  echo "30-dashboard.txt" ;;
        domains.lgrecommends) echo "32-lgrecommends.txt" ;;
        domains.wiselg)     echo "35-wiselg.txt" ;;
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
#
# pending_read loads the worker's pid and token into pending_pid and
# pending_token; it fails when there is no pending update.
pending_read() {
    [ -f "$HOSTS_PENDING" ] || return 1
    read -r pending_pid pending_token < "$HOSTS_PENDING"
}

pending_hosts_current() {
    pending_read || return 1
    [ -n "$pending_pid" ] && [ "$pending_token" = "$1" ] || return 1
    kill -0 "$pending_pid" 2>/dev/null
}

pending_hosts_clear() {
    pending_read || return 0
    [ "$pending_token" = "$1" ] && rm -f "$HOSTS_PENDING"
    return 0
}

pending_hosts_cancel() {
    rm -f "$HOSTS_PENDING"
}

hosts_pending() {
    pending_read || return 1
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

# Seconds left in the SDP grace period. Measured from the worker's start in
# /proc, which keeps counting while the grace period sets the wall clock.
# Clock ticks are taken as 100 a second, as on every webOS kernel.
hosts_wait_seconds() {
    hosts_pending || { echo 0; return 0; }
    awk -v delay="$CLOCK_SYNC_DELAY" -v stat="/proc/$pending_pid/stat" '
        BEGIN {
            if ((getline up < "/proc/uptime") <= 0 || (getline st < stat) <= 0) { print 0; exit }
            # The fields after "pid (comm) " start at field 3, so starttime
            # (field 22) is the 20th.
            sub(/^.*\) /, "", st)
            split(st, f, " ")
            left = delay - (up - f[20] / 100)
            if (left < 0) left = 0
            if (left > delay) left = delay
            printf "%d\n", left + 0.999
        }'
}

# BusyBox's timeout takes the duration as a bare SECS argument in 1.35 (webOS 9)
# but only as "-t SECS" in 1.29 (webOS 5/6), and each rejects the other's form
# outright. The wrong form exits 127 without ever running the command, so ask
# this build which one it accepts instead of assuming. Probed once per run: a
# valid result inherited from the parent script is kept.
case "${TIMEOUT_STYLE:-}" in
    bare|flag|none) ;;
    *) TIMEOUT_STYLE="" ;;
esac

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
    return 0
}

# Run a command for at most SECS seconds. Builds without a usable timeout
# applet (seen on webOS 4.x) get a shell watchdog instead, as an unbounded
# luna-send there blocks the whole apply, and with it the app's UI.
bounded_for() {
    b_secs="$1"
    shift
    detect_timeout_style
    case "$TIMEOUT_STYLE" in
        # SIGKILL: util-linux script (webOS 4.x) blocks SIGTERM, and once its
        # child has exited it can wait forever, so a TERM never stops it.
        bare) timeout -s KILL "$b_secs" "$@"; return $? ;;
        flag) timeout -t "$b_secs" -s KILL "$@"; return $? ;;
    esac
    run_capped "$b_secs" 1 "$@"
}

# Run a command with a timeout to avoid a hang blocking boot or the UI.
bounded() {
    bounded_for 10 "$@"
}

# Start or stop one service unit. webOS 5 and newer run systemd; webOS 4.x and
# older run Upstart, whose jobs carry the same names without ".service". A unit
# missing on a given build fails harmlessly. Upstart's stop waits for the job,
# so it is bounded.
unit_ctl() {
    u_action="$1"
    u_unit="$2"
    if command -v systemctl >/dev/null 2>&1; then
        # --no-block: these units take the full 90s stop/start timeout
        # otherwise, which would stall the whole apply.
        systemctl --no-block "$u_action" "$u_unit" >/dev/null 2>&1
    elif command -v initctl >/dev/null 2>&1; then
        bounded initctl "$u_action" "${u_unit%.service}" >/dev/null 2>&1
    else
        return 1
    fi
}

has_unit_manager() {
    command -v systemctl >/dev/null 2>&1 || command -v initctl >/dev/null 2>&1
}

# Process targets.
#
# LG starts most of these from the Luna hub (ls-hubd), so killing a process only
# gets it respawned. Instead we bind-mount an inert stub over the executable:
# the next exec exits immediately, with no polling loop needed. Matching is by
# exact /proc/<pid>/exe path, so jailed copies count too. Paths that do not
# exist on a given build are skipped at apply time.

# The executables each service toggle stops, by name. The names are also what
# status reports, one proc.<group>.<name> line each.
VOICE_NAMES="voiceinput voiceinput_network voiceinput_preprocessor voiceinput_hidraw voiceinput_sound voiceconductor voiceclick nlpmanager performer"
ADS_NAMES="admanager livepick acr2 nudge rdxd uploadd sportsalarm adoverlay-service"
THINQ_NAMES="trigger_thinq trigger_alexa iot-proxy iot-client mqtt-client lg.thinqai.adapter amazon-alexa-adapter amazon-alexa-vsk"
SERVICE_GROUPS="voice ads thinq lan"

# "<name> <path>" for every executable one group targets. Each name gets the
# canonical directories plus any per-app jail copy: jails hardlink the /usr/sbin
# binaries and a process may run from the jail path rather than the host one, so
# both need stubbing. Unmatched jail globs stay literal and are skipped by
# stub_mount's -f test. Launchers and copies outside those directories follow.
group_targets() {
    case "$1" in
        voice) names="$VOICE_NAMES" ;;
        ads) names="$ADS_NAMES" ;;
        thinq) names="$THINQ_NAMES" ;;
        # apply_lan stubs only the host binary, with its own script.
        lan) printf '%s\n' "upnpd /usr/sbin/upnpd"; return 0 ;;
        *) return 1 ;;
    esac
    for name in $names; do
        for path in "/usr/sbin/$name" "/usr/bin/$name" \
                    /var/palm/jail/*/usr/sbin/"$name" /var/palm/jail/*/usr/bin/"$name"; do
            printf '%s %s\n' "$name" "$path"
        done
    done
    case "$1" in
        voice) printf '%s\n' "app.voice /usr/bin/com.webos.app.voice" ;;
        # app launchers that fork the daemons above
        ads) printf '%s\n' "app.livepick /usr/bin/com.webos.app.livepick" \
                           "app.livepick-full /usr/bin/com.webos.app.livepick-full" ;;
        # iot-client also runs from its service directory
        thinq) printf '%s\n' "iot-client /usr/palm/services/com.webos.service.iotclient/iot-client" ;;
    esac
}

# Ad / ACR / telemetry executables.
ads_execs() {
    group_targets ads | awk '{ print $2 }'
}

# Units the ad / telemetry daemons run under.
ads_units() {
    printf '%s\n' livepick.service nudge.service rdxd.service uploadd.service
}

# Voice / wake-word / NLP executables, plus the voice app launcher.
voice_execs() {
    group_targets voice | awk '{ print $2 }'
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
    group_targets thinq | awk '{ print $2 }'
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

# Print the state of every executable the service toggles target, one line
# per name, then one line per group:
#   proc.<group>.<name>=running|stopped|absent|unknown
#   <group>=running|stopped|unknown
# running  a live process runs from one of the name's paths
# stopped  one of its paths exists (our stub counts) and none is running
# absent   none of its paths exists on this TV
# unknown  the process table could not be read, so running and stopped can't
#          be told apart
# A group is running if any name in it is, else unknown if any name is. One
# /proc scan serves every group. $1 is a scratch file prefix.
proc_states() {
    tmp="$1"
    for group in $SERVICE_GROUPS; do
        group_targets "$group" | sed "s/^/$group /"
    done > "$tmp.targets"
    # One ls for every candidate path: a shell test per path costs about 0.1s
    # on a TV with many app jails. ls fails for the paths that don't exist,
    # which is expected; it still lists the ones that do.
    awk '{ print $3 }' "$tmp.targets" | xargs ls -d 2>/dev/null > "$tmp.exists" || :
    # The shell running this is always in the table, so an empty one means the
    # scan failed, not that nothing runs. A process that exits mid-scan only
    # drops its own line.
    scan=ok
    proc_exe_table > "$tmp.procs" || scan=failed
    [ -s "$tmp.procs" ] || scan=failed
    awk -v scan="$scan" -v procs="$tmp.procs" -v exists="$tmp.exists" '
        BEGIN {
            if (scan == "ok")
                while ((getline line < procs) > 0) { split(line, f, " "); run[f[2]] = 1 }
            while ((getline line < exists) > 0) present[line] = 1
        }
        {
            key = $1 "." $2
            if (!(key in state)) { order[++n] = key; group[key] = $1; state[key] = "absent" }
            if (scan == "ok" && ($3 in run)) state[key] = "running"
            else if (($3 in present) && state[key] == "absent") state[key] = (scan == "ok") ? "stopped" : "unknown"
        }
        END {
            for (i = 1; i <= n; i++) {
                key = order[i]
                print "proc." key "=" state[key]
                g = group[key]
                if (!(g in gstate)) { gorder[++m] = g; gstate[g] = "stopped" }
                if (state[key] == "running") gstate[g] = "running"
                else if (state[key] == "unknown" && gstate[g] != "running") gstate[g] = "unknown"
            }
            for (j = 1; j <= m; j++) print gorder[j] "=" gstate[gorder[j]]
        }' "$tmp.targets"
    echo "proc_scan=$scan"
    rm -f "$tmp.targets" "$tmp.exists" "$tmp.procs"
}

# Do not remove files without a firmware-specific, verified cache allowlist.
purge_residue() {
    echo "[-] Purge unavailable: no verified cache-path allowlist for this firmware"
    return 1
}

# Set the clock to a Unix time in seconds. Ask the system service first, so
# webOS knows the time changed; fall back to setting the kernel clock directly.
# On webOS 9 with network time on, setSystemTime answers returnValue:true but
# leaves the clock alone, so the date fallback is what takes effect there.
# Succeeds only if the clock ends up within 10 seconds of the target.
set_clock() {
    target="$1"
    started="$(uptime_seconds)"
    if luna_call luna://com.webos.service.systemservice/time/setSystemTime \
        "{\"utc\":$target}" >/dev/null; then
        clock_close_to "$target" && { echo luna; return 0; }
    fi
    # setSystemTime can take seconds to answer (3 on webOS 4.4 during an
    # apply), so move the target on by that much before setting it directly.
    target=$((target + $(uptime_seconds) - started))
    date -u -s "@$target" >/dev/null 2>&1
    clock_close_to "$target" && { echo date; return 0; }
    return 1
}

clock_close_to() {
    now="$(date +%s)"
    diff=$((now - $1))
    [ "$diff" -ge -10 ] && [ "$diff" -le 10 ]
}

# Whole seconds since boot. Unlike date, setting the clock doesn't move it.
uptime_seconds() {
    read -r up _ < /proc/uptime
    echo "${up%.*}"
}

# Make one luna call and print its reply. luna-send answers directly on webOS
# 4.x, so try that first; some builds only print on a tty, so an empty reply
# is retried under script(1). util-linux script 2.28 (webOS 4.x) can hang
# after its child exits, which is why it is only the fallback.
luna_call() {
    command -v luna-send >/dev/null 2>&1 || return 1
    reply="$(bounded luna-send -n 1 -f "$1" "$2" </dev/null 2>/dev/null)"
    if [ -z "$reply" ] && command -v script >/dev/null 2>&1; then
        reply="$(bounded script -q -c "luna-send -n 1 -f $1 '$2'" \
            /dev/null </dev/null 2>/dev/null)"
    fi
    [ -n "$reply" ] || return 1
    printf '%s\n' "$reply"
}

# Print the process id of a running app, or nothing. Both service spellings
# exist across webOS versions, so try each.
app_pid() {
    for svc in com.webos.applicationManager com.webos.service.applicationmanager; do
        running="$(luna_call "luna://$svc/running" '{}')" || continue
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
            luna_call "luna://$svc/close" "{\"processId\":\"$pid\"}" >/dev/null
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
    has_unit_manager || return 0
    { ads_units; voice_units; thinq_units; } | sort -u |
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            unit_ctl start "$unit"
        done
    return 0
}

# Restart the SSDP discovery daemon that apply_lan stops.
ssdp_restore() {
    has_unit_manager || return 0
    if unit_ctl start ssdp-discovery-lgtv; then
        echo "[+] restarted ssdp-discovery-lgtv"
    fi
}

# True if the real upnpd daemon is running (as opposed to our stub shell).
# Candidates are matched by comm, which is the basename of the executed file:
# for the stub that is the script name "upnpd", the same as the real binary.
# The exe link is what tells the two apart.
upnp_running() {
    for pid in $(pgrep -x upnpd 2>/dev/null); do
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
    for pid in $(pgrep -x upnpd 2>/dev/null); do
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
    luna_call luna://com.webos.service.upnp/com/palm/luna/private/ping '{}' >/dev/null
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
