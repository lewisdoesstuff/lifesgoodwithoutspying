#!/bin/sh
# lifesgoodwithoutspying control helper.
#
# Usage:
#   nospy-ctl.sh enable|disable|apply|purge|status|log|job|joblog
#   nospy-ctl.sh set <key> on|off   (saves only; run apply to use it)
#   nospy-ctl.sh get <key>
#
# enable, disable and apply start a background job and return at once;
# poll "job" (or "status") for job=running|done|failed.

INITD="/var/lib/webosbrew/init.d"
LINK="$INITD/50-lifesgoodwithoutspying"
LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"
TMP="/tmp/lifesgoodwithoutspying.ctl.$$"

# Drop our scratch files however we exit.
trap 'rm -f "$TMP"*' EXIT

SELF="$(realpath "$0")"
DIR="$(dirname "$SELF")"
. "$DIR/nospy-lib.sh"

APPLY="$DIR/nospy-apply.sh"
REMOVE="$DIR/nospy-remove.sh"

# Count each enabled domain once, as a host can sit in more than one category.
blocklist_count() {
    domain_keys > "$TMP"
    while IFS= read -r key; do
        is_on "$key" || continue
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$DIR/blocklist.d/$file" ] || continue
        grep -v '^[[:space:]]*#' "$DIR/blocklist.d/$file" | grep -v '^[[:space:]]*$'
    done < "$TMP" | awk '!seen[$0]++ { n++ } END { print n + 0 }'
    rm -f "$TMP"
}

DNS_STATUS_CACHE=""
DNS_STATUS_LOADED=0

# Ask the helper once (about 0.6s on a TV). Call this in the main shell before
# reading fields: they run inside $(...), where a filled cache is thrown away.
dns_filter_load() {
    [ "$DNS_STATUS_LOADED" -eq 0 ] || return 0
    if [ -x "$DIR/nospy-dns-filter.sh" ]; then
        DNS_STATUS_CACHE="$("$DIR/nospy-dns-filter.sh" status 2>/dev/null)"
    fi
    DNS_STATUS_LOADED=1
}

dns_filter_status() {
    dns_filter_load
    printf '%s\n' "$DNS_STATUS_CACHE"
}

dns_filter_runtime() {
    dns_filter_status | sed -n 's/^enabled=//p' | head -n 1
}

dns_filter_field() {
    dns_filter_status | sed -n "s/^$1=//p" | head -n 1
}

# One selftest line per service group, from proc_states output on stdin,
# naming the listed processes that are running or couldn't be checked.
# proc.<group>.<name>=<state> lines come first, then <group>=<state>.
selftest_processes() {
    awk -F= '
        $1 ~ /^proc\./ {
            key = $1
            sub(/^proc\./, "", key)
            group = substr(key, 1, index(key, ".") - 1)
            seen[group] = 1
            if ($2 == "running" || $2 == "unknown") names[group, $2] = names[group, $2] " " substr(key, index(key, ".") + 1)
            next
        }
        $1 in seen {
            if ($2 == "running") print "  " $1 ": running (protection NOT active):" names[$1, "running"]
            else if ($2 == "unknown") print "  " $1 ": unknown (process scan failed):" names[$1, "unknown"]
            else print "  " $1 ": stopped"
        }'
}

# Background jobs.
#
# enable, disable and apply used to run the whole apply inside the Homebrew
# Channel exec call, so the UI waited on every child the apply started. One
# blocking child (luna-send on webOS 4.x) then froze the app with every button
# disabled. These now start a detached job and return at once; the UI polls
# "status" for job=running|done|failed and reads "joblog" afterwards.
#
# Both files describe jobs of the current boot only, so they live in /tmp: a
# pid saved before a reboot can name an unrelated process after it.
JOB_STATE="/tmp/lifesgoodwithoutspying.job"
JOB_RESULT="/tmp/lifesgoodwithoutspying.job-result"
# Hard cap on one job. A stage that outlives it gets SIGTERM, so apply can
# remove its scratch files, and SIGKILL JOB_GRACE seconds later. The UI always
# gets an answer instead of polling a job that never ends. The shell acts on
# SIGTERM only once its current command returns, so JOB_GRACE must outlast
# bounded's 10 seconds.
JOB_LIMIT=240
JOB_GRACE=15

job_running() {
    [ -f "$JOB_STATE" ] || return 1
    read -r job_pid job_action < "$JOB_STATE"
    [ -n "$job_pid" ] || return 1
    # A pid can also be reused within one boot, so check it is still a job.
    case " $(tr '\000' ' ' < "/proc/$job_pid/cmdline" 2>/dev/null) " in
        *" run-job "*) return 0 ;;
    esac
    return 1
}

job_state() {
    if job_running; then
        echo running
    elif [ -f "$JOB_RESULT" ]; then
        read -r res_action res_rc < "$JOB_RESULT"
        if [ "$res_rc" = 0 ]; then echo "done"; else echo failed; fi
    else
        echo idle
    fi
}

job_start() {
    if job_running; then
        echo "another change is still being applied ($job_action)" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$LOG")"
    rm -f "$JOB_RESULT"
    # Trim now: the job holds the log open, so apply's own trim would split it.
    log_trim "$LOG"
    # Detach completely: no stdio may stay tied to the exec call's pipes, or
    # the Homebrew Channel keeps waiting for them to close. No setsid: it forks
    # when called from a process-group leader (an SSH shell), and $! would
    # then name a pid that exits at once while the job is still running.
    # The Homebrew Channel runs us with LD_PRELOAD=libsystrim.so.3, which makes
    # every process the job starts about 2.5 times slower to launch (and stops
    # BusyBox timeout working); the job does not need it.
    LD_PRELOAD= sh "$SELF" run-job "$1" </dev/null >>"$LOG" 2>&1 &
    printf '%s %s\n' "$!" "$1" > "$JOB_STATE"
    echo "job=started"
}

# The job body, run detached by job_start.
job_body() {
    case "$1" in
        enable)
            mkdir -p "$INITD"
            chmod +x "$APPLY" "$REMOVE"
            run_capped "$JOB_LIMIT" "$JOB_GRACE" "$APPLY"
            rc=$?
            ln -sf "$APPLY" "$LINK"
            return "$rc"
            ;;
        disable)
            rm -f "$LINK"
            run_capped "$JOB_LIMIT" "$JOB_GRACE" "$REMOVE"
            ;;
        apply)
            chmod +x "$APPLY"
            run_capped "$JOB_LIMIT" "$JOB_GRACE" "$APPLY"
            ;;
        *)
            echo "unknown job: $1"
            return 2
            ;;
    esac
}

is_known_key() {
    conf_keys > "$TMP"
    found=1
    while IFS= read -r k; do
        if [ "$k" = "$1" ]; then
            found=0
        fi
    done < "$TMP"
    rm -f "$TMP"
    return "$found"
}

case "$1" in
    enable|disable|apply)
        job_start "$1"
        ;;
    run-job)
        # Outlive the SSH session it may have been started from.
        trap '' HUP
        echo "==== job: $2 $(date) ===="
        job_body "$2"
        rc=$?
        echo "==== $2 finished rc=$rc ===="
        printf '%s %s\n' "$2" "$rc" > "$JOB_RESULT"
        if [ -f "$JOB_STATE" ]; then
            read -r job_pid job_action < "$JOB_STATE"
            [ "$job_pid" = "$$" ] && rm -f "$JOB_STATE"
        fi
        exit "$rc"
        ;;
    job)
        # The job line of status alone. The app polls this while a job runs:
        # a full status costs a few seconds of CPU that the job would share.
        echo "job=$(job_state)"
        ;;
    joblog)
        # Everything since the newest job marker: the job plus the apply or
        # remove output it produced.
        if [ -f "$LOG" ]; then
            awk '/^==== job: / { n = 0 } { buf[n++] = $0 } END { for (i = 0; i < n; i++) print buf[i] }' "$LOG"
        fi
        ;;
    purge)
        purge_residue
        ;;
    set)
        key="$2"
        val="$3"
        if ! is_known_key "$key"; then
            echo "unknown key: $key" >&2
            exit 2
        fi
        case "$val" in
            on|off) ;;
            *) echo "value must be on or off" >&2; exit 2 ;;
        esac
        if [ "$key" = purge.boot ] && [ "$val" = on ]; then
            echo "Purge unavailable: no verified cache-path allowlist for this firmware" >&2
            exit 1
        fi
        # Only save the setting. A full apply takes 10-20 seconds, so the UI
        # collects changes and applies them once ("Update protection"); run
        # apply yourself after setting keys over SSH.
        conf_set "$key" "$val"
        echo "$key=$val"
        ;;
    get)
        conf_get "$2"
        ;;
    status)
        if [ -L "$LINK" ]; then
            echo "autostart=on"
            # Settings saved since the last apply.
            if [ ! -f "$CONF_APPLIED" ]; then
                echo "changes=pending"
            elif [ "$(conf_effective "$CONF")" = "$(conf_effective "$CONF_APPLIED")" ]; then
                echo "changes=none"
            else
                echo "changes=pending"
            fi
        else
            echo "autostart=off"
        fi
        echo "job=$(job_state)"
        hosts="$(hosts_state)"
        echo "hosts=$hosts"
        [ "$hosts" = waiting ] && echo "hosts_wait=$(hosts_wait_seconds)"
        echo "blocklist=$(blocklist_count)"
        dns_filter_load
        echo "dns_filter=$(dns_filter_runtime)"
        echo "dns_filter_generation=$(dns_filter_field loaded_generation)"
        echo "dns_filter_rules=$(dns_filter_field loaded_rules)"
        echo "connman_nameservers=$(dns_filter_field connman_nameservers)"
        echo "dns_filter_ipv6_mode=$(dns_filter_field handoff_ipv6_mode)"
        echo "connman_ipv6=$(dns_filter_field connman_ipv6)"
        echo "stubs=$(stub_count)"
        # The saved settings: bare for older frontends, and as saved.<key> so
        # the UI can tell settings apart from other on/off lines.
        conf_effective "$CONF" > "$TMP.conf"
        cat "$TMP.conf"
        sed 's/^/saved./' "$TMP.conf"
        # The settings the last apply used, so the UI can mark each unapplied
        # change. There is no file until the first apply.
        if [ -f "$CONF_APPLIED" ]; then
            conf_effective "$CONF_APPLIED" | sed 's/^/applied./'
        fi
        # Also prints voice= and ads=, which older frontends read.
        proc_states "$TMP.proc"
        ;;
    selftest)
        echo "== generated host sink (host-side check) =="
        echo "state: $(hosts_state)   (ours = active)"
        echo "configured entries: $(blocklist_count)"
        echo "  NOTE: this confirms the mount, not how every webOS service resolves names."
        echo
        echo "== DNS filter (ConnMan handoff) =="
        if is_on dns.filter; then
            echo "configured=on"
            dns_filter_load
            echo "runtime: $(dns_filter_runtime)"
            echo "handoff IPv6 mode: $(dns_filter_field handoff_ipv6_mode)"
            echo "loaded generation: $(dns_filter_field loaded_generation)"
            echo "loaded rules: $(dns_filter_field loaded_rules)"
            if is_on dns.disable_ipv6; then
                echo "IPv6 companion: disabled while DNS filter is enabled"
            else
                echo "IPv6 companion: preserved (IPv6 DNS may bypass the helper)"
            fi
        else
            echo "configured=off"
            if is_on dns.disable_ipv6; then
                echo "IPv6 companion: configured on but inactive until dns.filter is enabled"
            else
                echo "IPv6 companion: off"
            fi
        fi
        echo
        echo "== local resolution (getent; diagnostic only) =="
        for d in ad.lgsmartad.com alphonso.tv recommend.lgtvcommon.com; do
            printf "  %-30s %s\n" "$d" "$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
        done
        printf "  %-30s %s\n" "lgtvonline.lge.com (control)" "$(getent hosts lgtvonline.lge.com 2>/dev/null | awk '{print $1}' | head -1)"
        printf "  %-30s %s\n" "gb.nextlgsdp.com (SDP clock)" "$(getent hosts gb.nextlgsdp.com 2>/dev/null | awk '{print $1}' | head -1)"
        echo "  NOTE: getent uses this shell's resolver and the mounted /etc/hosts;"
        echo "        it does not prove that webOS daemons use the same DNS path."
        state="$(hosts_state)"
        if is_on domains.sdp; then
            case "$state" in
                waiting)
                    if [ -f "$HOSTS_GEN" ] && grep -q 'nextlgsdp\.com' "$HOSTS_GEN"; then
                        echo "  SDP clock block              FAILED (present during grace period)"
                    else
                        echo "  SDP clock block              pending (60-second grace period)"
                    fi
                    ;;
                ours)
                    if [ -f "$HOSTS_GEN" ] && grep -q 'nextlgsdp\.com' "$HOSTS_GEN"; then
                        echo "  SDP clock block              passed"
                    else
                        echo "  SDP clock block              FAILED (missing from active sink)"
                    fi
                    ;;
                open)
                    echo "  SDP clock block              not applied"
                    ;;
                *)
                    echo "  SDP clock block              unavailable ($state sink)"
                    ;;
            esac
        elif [ -f "$HOSTS_GEN" ] && grep -q 'nextlgsdp\.com' "$HOSTS_GEN"; then
            echo "  SDP clock block              FAILED (disabled but present in generated sink)"
        else
            echo "  SDP clock block              disabled"
        fi
        if is_on clock.ntp; then
            if [ -f "$NTP_TOKEN" ]; then
                echo "  NTP clock                    pending"
            else
                echo "  NTP clock                    on (see log for the last sync)"
            fi
        fi
        echo "  Clock (UTC)                  $(date -u '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "== local outbound check (curl; diagnostic only) =="
        # -4: this build's curl stalls on dual-stack dials to the sinkhole,
        # so pin IPv4. This still uses the shell's local resolver; it is not
        # evidence that a TV service's resolver will fail.
        code="$(curl -4 -s --connect-timeout 3 -m 5 -o /dev/null -w '%{http_code}' https://ad.lgsmartad.com/ 2>/dev/null)"
        rc=$?
        echo "  ad.lgsmartad.com  http=${code:-none}  curl_rc=$rc"
        echo "  NOTE: curl also uses the mounted /etc/hosts; this is not a TV process test."
        echo
        echo "== listed processes (effective protection check) =="
        proc_states "$TMP.proc" | selftest_processes
        echo
        echo "== ACR / ad services on the Luna bus =="
        ls-monitor -l 2>/dev/null | grep -iE 'service\.acr|service\.livepick|colorInfoMiner|service\.admanager|service\.adoverlay|service\.tvdataexchang|acr2|nudge|rdxd|uploadd|sportsalarm' | grep -vi 'wowplay' || echo "  (none)"
        echo
        echo "== buffered ACR / voice residue files =="
        find /var/log /tmp /var/run -maxdepth 3 -type f \
            \( -iname '*acr*' -o -iname '*voice*' -o -iname '*alphonso*' -o -iname '*stt*' \) \
            2>/dev/null | wc -l
        ;;
    log)
        if [ -f "$LOG" ]; then
            tail -n 200 "$LOG"
        else
            echo "(no log yet)"
        fi
        ;;
    *)
        echo "usage: $0 enable|disable|apply|purge|status|selftest|log|job|joblog|set <key> on|off|get <key>" >&2
        exit 2
        ;;
esac
