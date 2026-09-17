#!/bin/sh
# lifesgoodwithoutspying - remove runtime changes

DIR="$(dirname "$(realpath "$0")")"
. "$DIR/nospy-lib.sh"

LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"
mkdir -p /var/lib/webosbrew 2>/dev/null || true
exec >>"$LOG" 2>&1
echo "==== remove $(date) ===="

if hosts_ours_active; then
    # lazy fallback so a busy file still detaches
    if umount /etc/hosts 2>/dev/null || umount -l /etc/hosts 2>/dev/null; then
        echo "[+] /etc/hosts sink removed"
    else
        echo "[-] failed to unmount /etc/hosts (will clear on reboot)"
    fi
elif hosts_is_mounted; then
    echo "[~] /etc/hosts is mounted by something else; leaving it alone"
else
    echo "[~] /etc/hosts was not overridden"
fi

if head -n 2 /usr/sbin/upnpd 2>/dev/null | grep -q 'nospy-upnpd-stub'; then
    if umount /usr/sbin/upnpd 2>/dev/null || umount -l /usr/sbin/upnpd 2>/dev/null; then
        echo "[+] restored /usr/sbin/upnpd"
    fi
fi

# apply stubs executables and stops services; disabling protection should
# unmount the stubs and turn the services back on, or they stay down until the
# next reboot.
services_restore

echo "==== done ===="
