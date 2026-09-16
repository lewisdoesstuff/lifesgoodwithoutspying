#!/bin/sh
# lifesgoodwithoutspying control helper.
#
# Usage:
#   nospy-ctl.sh enable|disable|apply|purge|status|log
#   nospy-ctl.sh set <key> on|off
#   nospy-ctl.sh get <key>

INITD="/var/lib/webosbrew/init.d"
LINK="$INITD/50-lifesgoodwithoutspying"
LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"
TMP="/tmp/lifesgoodwithoutspying.ctl.$$"

SELF="$(realpath "$0")"
DIR="$(dirname "$SELF")"
. "$DIR/nospy-lib.sh"

APPLY="$DIR/nospy-apply.sh"
REMOVE="$DIR/nospy-remove.sh"

blocklist_count() {
    domain_keys > "$TMP"
    total=0
    while IFS= read -r key; do
        is_on "$key" || continue
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$DIR/blocklist.d/$file" ] || continue
        n="$(grep -v '^[[:space:]]*#' "$DIR/blocklist.d/$file" | grep -vc '^[[:space:]]*$')"
        total=$((total + n))
    done < "$TMP"
    rm -f "$TMP"
    echo "$total"
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
    enable)
        mkdir -p "$INITD"
        chmod +x "$APPLY" "$REMOVE"
        "$APPLY"
        ln -sf "$APPLY" "$LINK"
        echo "autostart=on"
        ;;
    disable)
        # stop the watcher first: nospy-remove.sh restores the services the
        # kill-toggles stopped, and the watcher would just re-kill them.
        watch_stop
        rm -f "$LINK"
        "$REMOVE"
        echo "autostart=off"
        ;;
    apply)
        chmod +x "$APPLY"
        "$APPLY"
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
        conf_set "$key" "$val"
        echo "$key=$val"
        # Re-apply so the change takes effect immediately.
        chmod +x "$APPLY"
        "$APPLY"
        ;;
    get)
        conf_get "$2"
        ;;
    status)
        if [ -L "$LINK" ]; then
            echo "autostart=on"
        else
            echo "autostart=off"
        fi
        echo "hosts=$(hosts_state)"
        echo "blocklist=$(blocklist_count)"
        echo "watch=$(watch_running && echo on || echo off)"
        conf_keys > "$TMP"
        while IFS= read -r key; do
            echo "$key=$(conf_get "$key")"
        done < "$TMP"
        rm -f "$TMP"
        if ps aux 2>/dev/null | grep -qE '[v]oiceinput|[v]oiceconductor'; then
            echo "voice=running"
        else
            echo "voice=stopped"
        fi
        if ps aux 2>/dev/null | grep -qE '[a]dmanager|[a]dooverlay|[l]ivepick'; then
            echo "ads=running"
        else
            echo "ads=stopped"
        fi
        ;;
    selftest)
        echo "== domain sink =="
        echo "state: $(hosts_state)   (ours = active)"
        echo "blocked entries: $(blocklist_count)"
        echo
        echo "== resolution: blocked hosts should be loopback =="
        for d in ad.lgsmartad.com alphonso.tv recommend.lgtvcommon.com; do
            printf "  %-30s %s\n" "$d" "$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
        done
        printf "  %-30s %s\n" "lgtvonline.lge.com (control)" "$(getent hosts lgtvonline.lge.com 2>/dev/null | awk '{print $1}' | head -1)"
        echo
        echo "== outbound to a blocked host (should fail) =="
        # -4: this build's curl stalls on dual-stack dials to the sinkhole,
        # so pin IPv4. Tests the same thing: the name goes nowhere.
        code="$(curl -4 -s --connect-timeout 3 -m 5 -o /dev/null -w '%{http_code}' https://ad.lgsmartad.com/ 2>/dev/null)"
        rc=$?
        echo "  ad.lgsmartad.com  http=${code:-none}  curl_rc=$rc"
        echo
        echo "== voice =="
        if ps aux 2>/dev/null | grep -qE '[v]oiceinput|[v]oiceconductor'; then
            echo "  voice: running (protection NOT active)"
        else
            echo "  voice: stopped"
        fi
        echo
        echo "== ACR / ad services present on the bus =="
        ls-monitor -l 2>/dev/null | grep -iE 'service\.acr|service\.livepick|colorInfoMiner|service\.admanager|service\.adoverlay|service\.tvdataexchang' || echo "  (none)"
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
        echo "usage: $0 enable|disable|apply|purge|status|selftest|log|set <key> on|off|get <key>" >&2
        exit 2
        ;;
esac
