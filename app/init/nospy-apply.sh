#!/bin/sh
# lifesgoodwithoutspying - apply privacy hardening according to the configured options.
#
# Runs at boot via run-parts and on demand from the app UI.

DIR="$(dirname "$(realpath "$0")")"
. "$DIR/nospy-lib.sh"

LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"

# Homebrew Channel captures nothing from init.d scripts, so log ourselves.
mkdir -p /var/lib/webosbrew 2>/dev/null || true

log_trim "$LOG"

exec >>"$LOG" 2>&1
echo "==== apply $(date) ===="
# Record the settings this run applies. Saving a toggle does not apply it, so
# status compares this copy with the saved settings to report pending changes.
cat "$CONF" > "$CONF_APPLIED" 2>/dev/null || : > "$CONF_APPLIED"

BLOCKDIR="$DIR/blocklist.d"
DNS_FILTER_INIT="$DIR/nospy-dns-filter.sh"
DNS_FILTER_STATE="/var/lib/webosbrew/lifesgoodwithoutspying-dns-filter.state"
DOMAINS_TMP="/tmp/lifesgoodwithoutspying.domains.$$"
KEYS_TMP="/tmp/lifesgoodwithoutspying.keys.$$"
UNITS_TMP="/tmp/lifesgoodwithoutspying.units.$$"
EXECS_TMP="/tmp/lifesgoodwithoutspying.execs.$$"
SERVICES_TMP="/tmp/lifesgoodwithoutspying.services.$$"
APPS_TMP="/tmp/lifesgoodwithoutspying.apps.$$"

# Scratch files are per-run and multi-megabyte-free, but never cleaned before;
# remove them however we exit.
trap 'rm -f "$DOMAINS_TMP" "$KEYS_TMP" "$UNITS_TMP" "$EXECS_TMP" "$SERVICES_TMP" "$APPS_TMP" "$DNS_BLOCKLIST.tmp.$$" "$DNS_BLOCKLIST.sdp.$$"' EXIT
# An untrapped SIGTERM (the job cap's first signal) ends the shell without
# running the EXIT trap, so turn it into a normal exit.
trap 'exit 143' INT TERM

# Remove only our mounts from /etc/hosts
# webosbrew (and potentially other apps) may have mounts on this
unmount_ours() {
    n=0
    while hosts_ours_active && [ "$n" -lt 5 ]; do
        umount /etc/hosts 2>/dev/null || umount -l /etc/hosts 2>/dev/null || break
        n=$((n + 1))
    done
}

# Emit enabled domains, once each: a host can sit in more than one category.
# During the initial sink build, domains.sdp is held back so the other
# protections can take effect immediately.
collect_domains() {
    mode="$1"
    domain_keys > "$KEYS_TMP"
    while IFS= read -r key; do
        if [ "$key" = domains.sdp ] && [ "$mode" = initial ]; then
            # Disabled SDP never contributes domains. Enabled SDP is held back
            # for the grace period, unless the NTP clock is on: then SDP is not
            # needed for the time, so it is blocked immediately.
            is_on "$key" && is_on clock.ntp || continue
        else
            is_on "$key" || continue
        fi
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$BLOCKDIR/$file" ] || continue
        grep -v '^[[:space:]]*#' "$BLOCKDIR/$file" | grep -v '^[[:space:]]*$'
    done < "$KEYS_TMP" | awk '!seen[$0]++'
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

# Keep valid generation artifacts even when every domain category is disabled.
# The DNS handoff can then load an intentional empty generation instead of
# retaining entries from an earlier protection generation.
write_empty_generated_hosts() {
    empty_tmp="$HOSTS_GEN.empty.$$"
    {
        echo ""
        echo "$NOSPY_MARKER generation empty-$(date +%s)-$$"
    } > "$empty_tmp" || return 1
    chmod 644 "$empty_tmp" || return 1
    mv "$empty_tmp" "$HOSTS_GEN"
}

# Publish the DNS domain artifact independently of /etc/hosts. The temporary
# file is replaced atomically so a reload can never observe a partial list.
write_dns_artifact() {
    input="$1"
    generation="$2"
    count="$(grep -c . "$input" 2>/dev/null)"
    [ -n "$count" ] || count=0
    artifact_tmp="$DNS_BLOCKLIST.tmp.$$"
    {
        echo "# lifesgoodwithoutspying dns-filter generation $generation rules $count"
        cat "$input"
    } > "$artifact_tmp" || return 1
    chmod 600 "$artifact_tmp" || return 1
    mv "$artifact_tmp" "$DNS_BLOCKLIST"
}

append_sdp_dns_artifact() {
    base_generation="$1"
    file="$(cat_file_for_key domains.sdp)"
    path="$BLOCKDIR/$file"
    [ -f "$path" ] || return 1
    grep -q "^# lifesgoodwithoutspying dns-filter generation $base_generation rules " \
        "$DNS_BLOCKLIST" 2>/dev/null || return 1

    combined="$DNS_BLOCKLIST.sdp.$$"
    sed '1d' "$DNS_BLOCKLIST" > "$combined" || return 1
    grep -v '^[[:space:]]*#' "$path" | grep -v '^[[:space:]]*$' >> "$combined" || return 1
    write_dns_artifact "$combined" "${base_generation}-sdp"
    result=$?
    rm -f "$combined"
    return "$result"
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
            if append_sdp_dns_artifact "$token"; then
                # A filter still waiting for the network loads this list when
                # it starts, so only a running one needs a reload.
                if is_on dns.filter && [ -x "$DNS_FILTER_INIT" ] && [ -f "$DNS_FILTER_STATE" ]; then
                    "$DNS_FILTER_INIT" reload || echo "[-] DNS filter reload failed after SDP update"
                fi
            else
                echo "[-] failed to publish DNS artifact after SDP update"
            fi
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
    is_on domains.sdp && ! is_on clock.ntp && sdp_pending=1
    generation="$(date +%s)-$$"

    if [ "$count" -eq 0 ] && [ "$sdp_pending" -eq 0 ]; then
        echo "[~] no domain categories enabled; our sink is off"
        write_empty_generated_hosts || echo "[-] failed to write empty generated hosts marker"
        write_dns_artifact "$DOMAINS_TMP" "empty-$generation" || echo "[-] failed to write empty DNS artifact"
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
    if ! write_dns_artifact "$DOMAINS_TMP" "$generation"; then
        echo "[-] failed to publish DNS artifact; removing incomplete hosts sink"
        unmount_ours
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 1
    fi
    if [ "$sdp_pending" -eq 1 ]; then
        schedule_sdp_block "$generation"
    fi
    rm -f "$DOMAINS_TMP" "$KEYS_TMP"
}

dns_filter_ipv6_mode() {
    if is_on dns.disable_ipv6; then
        echo off
    else
        echo preserve
    fi
}

# The handoff needs an active ConnMan service, and at boot Wi-Fi can take
# longer to connect than the handoff waits. Keep trying in the background for
# up to 10 minutes rather than leaving the filter off until the next apply. A
# newer apply or a disable replaces or removes the token, which stops this
# worker.
schedule_dns_filter_retry() {
    token="$(date +%s)-$$"
    echo "$token" > "$DNS_RETRY_TOKEN"
    (
        trap - EXIT HUP INT TERM
        trap '' HUP
        waited=0
        while [ "$waited" -lt 600 ]; do
            sleep 10
            waited=$((waited + 10))
            [ "$(cat "$DNS_RETRY_TOKEN" 2>/dev/null)" = "$token" ] || exit 0
            is_on dns.filter || break
            out="$(NOSPY_DNS_IPV6_MODE="$(dns_filter_ipv6_mode)" "$DNS_FILTER_INIT" enable 2>&1)"
            rc=$?
            [ "$rc" -eq 75 ] && continue
            [ -n "$out" ] && printf '%s\n' "$out"
            if [ "$rc" -eq 0 ]; then
                echo "[+] DNS filter started after waiting ${waited}s for the network"
            else
                # Anything other than "no network yet" will not fix itself.
                echo "[-] DNS filter could not start"
            fi
            break
        done
        [ "$waited" -lt 600 ] || echo "[-] no usable network after 600s; DNS filter left off"
        [ "$(cat "$DNS_RETRY_TOKEN" 2>/dev/null)" = "$token" ] && rm -f "$DNS_RETRY_TOKEN"
    ) &
    echo "[~] no network yet; the DNS filter will start in the background once it is up"
}

apply_dns_filter() {
    rm -f "$DNS_RETRY_TOKEN"
    if [ -f "$DNS_FILTER_STATE" ] && [ ! -x "$DNS_FILTER_INIT" ]; then
        echo "[-] DNS handoff state exists but its rollback script is missing"
        return 1
    fi
    nat="$(dns_filter_nat_check)"
    if is_on dns.filter && [ "$nat" = no ]; then
        # A setting saved before this check existed, or copied from another
        # TV. The handoff would only fail, so switch it off for good.
        echo "[~] DNS filter needs iptables NAT, which this kernel lacks; turning dns.filter and dns.disable_ipv6 off"
        conf_set dns.filter off
        conf_set dns.disable_ipv6 off
        cat "$CONF" > "$CONF_APPLIED" 2>/dev/null
    elif is_on dns.filter && [ "$nat" = unknown ]; then
        # Possibly a passing failure (xtables lock, slow boot): leave the
        # filter as it is and save nothing, so the next apply checks again.
        echo "[~] couldn't check iptables NAT this time; leaving the DNS filter as it is"
        return 0
    fi
    if is_on dns.filter; then
        if [ ! -x "$DNS_FILTER_INIT" ] || [ ! -f "$DIR/nospy-dns-filter.js" ]; then
            echo "[-] DNS filter is enabled but its helper bundle is missing"
            return 1
        fi
        # Reconfigure the complete handoff when either companion setting changes.
        # The nameserver is always part of the handoff; only IPv6 is optional.
        if [ -f "$DNS_FILTER_STATE" ]; then
            # Same IPv6 mode as the running handoff: only the blocklist can have
            # changed, and the helper reloads that in place. Restarting the
            # handoff costs several seconds, so do that only when the reload
            # fails (e.g. the helper is not running after a reboot).
            if [ "$(sed -n 's/^IPV6_MODE=//p' "$DNS_FILTER_STATE")" = "$(dns_filter_ipv6_mode)" ] &&
                "$DNS_FILTER_INIT" reload 2>/dev/null; then
                return 0
            fi
            "$DNS_FILTER_INIT" disable || return 1
        fi
        NOSPY_DNS_IPV6_MODE="$(dns_filter_ipv6_mode)" "$DNS_FILTER_INIT" enable
        rc=$?
        if [ "$rc" -eq 75 ]; then
            schedule_dns_filter_retry
            return 0
        fi
        return "$rc"
    fi

    if [ -f "$DNS_FILTER_STATE" ] && [ -x "$DNS_FILTER_INIT" ]; then
        "$DNS_FILTER_INIT" disable
        return $?
    fi
    if is_on dns.disable_ipv6; then
        echo "[~] dns.disable_ipv6 is companion-only; ignored while dns.filter is off"
    fi
    return 0
}

# Common apply for the stub-based categories.
#
# Turning a toggle on stops the category's units, bind-mounts an inert stub
# over each target executable, then kills whatever was already running.
# Turning it off unwinds both, so a toggle is not a one-way door. Services that
# have a stand-in get it only while their executables are stubbed.
apply_stub_category() {
    key="$1"
    unit_fn="$2"
    exec_fn="$3"

    "$exec_fn" > "$EXECS_TMP"
    answered="$(answered_in "$EXECS_TMP")"
    for service in $answered; do
        answer_stop "$service"
    done

    if ! is_on "$key"; then
        stub_clear_key "$key"
        services_rescan
        if has_unit_manager; then
            "$unit_fn" > "$UNITS_TMP"
            while IFS= read -r unit; do
                [ -n "$unit" ] || continue
                unit_ctl start "$unit"
            done < "$UNITS_TMP"
        fi
        echo "[~] $key disabled"
        return 0
    fi

    if has_unit_manager; then
        "$unit_fn" > "$UNITS_TMP"
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            unit_ctl stop "$unit"
        done < "$UNITS_TMP"
    fi

    stub_write
    stub_clear_key "$key"
    n=0
    shared=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        stub_mount "$key" "$path"
        case $? in
            0) n=$((n + 1)) ;;
            2) shared=$((shared + 1)) ;;
        esac
    done < "$EXECS_TMP"
    if [ "$shared" -gt 0 ]; then
        echo "[+] $key: stubbed $n executable(s), $shared more through a shared jail mount"
    else
        echo "[+] $key: stubbed $n executable(s)"
    fi

    # Services the hub starts through the jailer get a fresh /usr without the
    # stub, so point their .service file at the stub instead.
    if command -v ls-control >/dev/null 2>&1; then
        jailed_service_files "$EXECS_TMP" > "$SERVICES_TMP"
        n=0
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            if service_override "$key" "$path"; then
                n=$((n + 1))
            fi
        done < "$SERVICES_TMP"
        [ "$n" -eq 0 ] || echo "[+] $key: pointed $n jailed service(s) at the stub"
    fi
    services_rescan

    kill_by_paths "$EXECS_TMP"
    for service in $answered; do
        answer_start "$service"
    done
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
    pids="$(pgrep -x upnpd 2>/dev/null | tr '\n' ' ')"
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill_with_children "$pid"
        done
        echo "[+] killed running upnpd"
    fi
    # the watcher used to keep ssdp down; do it here now.
    unit_ctl stop ssdp-discovery-lgtv || true
    if pkill -9 ssdp 2>/dev/null; then
        echo "[+] killed ssdp"
    fi
}

# Set the clock from NTP instead of LG's SDP X-Server-Time header. At boot the
# network may not be up yet, so retry in the background for up to 10 minutes.
# A newer apply or a disable replaces or removes the token, which stops this
# worker.
apply_clock() {
    if ! is_on clock.ntp; then
        rm -f "$NTP_TOKEN"
        return 0
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "[-] NTP clock needs node, which this TV lacks; clock left alone"
        return 0
    fi
    token="$(date +%s)-$$"
    echo "$token" > "$NTP_TOKEN"
    (
        trap - EXIT HUP INT TERM
        trap '' HUP
        attempt=0
        while [ "$attempt" -lt 60 ]; do
            [ "$(cat "$NTP_TOKEN" 2>/dev/null)" = "$token" ] || exit 0
            seconds="$(bounded node "$DIR/nospy-ntp.js" 2>/dev/null)"
            if [ -n "$seconds" ]; then
                offset=$(($(date +%s) - seconds))
                if [ "$offset" -ge -2 ] && [ "$offset" -le 2 ]; then
                    echo "[~] clock already matches NTP (off by ${offset}s)"
                elif how="$(set_clock "$seconds")"; then
                    echo "[+] clock set from NTP via $how (was off by ${offset}s)"
                else
                    echo "[-] NTP answered but the clock could not be set"
                fi
                [ "$(cat "$NTP_TOKEN" 2>/dev/null)" = "$token" ] && rm -f "$NTP_TOKEN"
                exit 0
            fi
            sleep 10
            attempt=$((attempt + 1))
        done
        echo "[-] no NTP answer after $attempt attempts; clock left alone"
    ) &
    echo "[~] setting the clock from NTP in the background"
}

apply_purge() {
    if is_on purge.boot; then
        purge_residue
    fi
}

hosts_ok=1
dns_filter_ok=1
apply_hosts || hosts_ok=0
if [ "$hosts_ok" -eq 1 ]; then
    apply_dns_filter || dns_filter_ok=0
elif [ -f "$DNS_FILTER_STATE" ] && [ -x "$DNS_FILTER_INIT" ]; then
    echo "[-] domain generation failed; stopping the DNS handoff to avoid stale rules"
    "$DNS_FILTER_INIT" disable || dns_filter_ok=0
fi
apply_clock
apply_ads
apply_voice
apply_thinq
apply_lan
apply_purge

if [ "$dns_filter_ok" -ne 1 ]; then
    echo "[-] one or more DNS handoff operations failed"
    exit 1
fi

echo "==== done ===="
