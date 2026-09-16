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

# Voice recognition
apply_voice() {
    if ! is_on voice.stop; then
        echo "[~] voice.stop disabled"
        # toggling back on means voice should work again
        voice_restore
        return 0
    fi

    # Stop the voiceinput and voiceconductor units
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl stop voiceinput voiceconductor >/dev/null 2>&1; then
            echo "[+] stopped voiceinput + voiceconductor units"
        else
            echo "[~] systemctl stop returned non-zero (units may be absent on this build)"
        fi
    fi

    # Kill any remaining processes
    for proc in voiceinput voiceinput_network voiceinput_preprocessor \
                voiceinput_hidraw voiceinput_sound voiceconductor voiceclick; do
        if pkill -9 "$proc" 2>/dev/null; then
            echo "[+] killed $proc"
        fi
    done
}


# Ad services
apply_ads() {
    if ! is_on ads.stop; then
        # livepick is a unit; admanager/adoverlay respawn on their own
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start livepick >/dev/null 2>&1 || true
        fi
        return 0
    fi
    stopped=0
    for proc in admanager adoverlay livepick; do
        if pkill -9 "$proc" 2>/dev/null; then
            echo "[+] killed $proc"
            stopped=1
        fi
    done
    if [ "$stopped" -eq 0 ]; then
        echo "[~] no ad services running"
    fi
    # admanager is activity-supervised and restarts when the ad UI asks for it,
    # so it may reappear until the next apply / boot.
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
}

# Clear any existing ACR/voice files 
purge_residue() {
    total=0
    for base in /var/log /tmp /var/run; do
        [ -d "$base" ] || continue
        n="$(find "$base" -maxdepth 3 -type f \
            \( -iname '*acr*' -o -iname '*voice*' -o -iname '*alphonso*' -o -iname '*stt*' \) \
            2>/dev/null | wc -l)"
        [ "$n" -gt 0 ] || continue
        find "$base" -maxdepth 3 -type f \
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

apply_purge() {
    if is_on purge.boot; then
        purge_residue
    fi
}

apply_hosts
apply_voice
apply_ads
apply_lan
apply_purge
watch_ensure

echo "==== done ===="
