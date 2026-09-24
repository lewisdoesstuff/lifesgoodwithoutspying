#!/bin/sh
# lifesgoodwithoutspying - remove runtime changes

DIR="$(dirname "$(realpath "$0")")"
. "$DIR/nospy-lib.sh"

LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"
mkdir -p /var/lib/webosbrew 2>/dev/null || true
exec >>"$LOG" 2>&1
echo "==== remove $(date) ===="

# A delayed worker must not modify the sink after protection is disabled.
pending_hosts_cancel

DNS_FILTER_INIT="$DIR/nospy-dns-filter.sh"
DNS_FILTER_STATE="/var/lib/webosbrew/lifesgoodwithoutspying-dns-filter.state"
DNS_FILTER_PID="/var/lib/webosbrew/lifesgoodwithoutspying-dns-filter.pid"
remove_ok=1
if [ -f "$DNS_FILTER_STATE" ] || [ -f "$DNS_FILTER_PID" ]; then
    if [ -x "$DNS_FILTER_INIT" ]; then
        "$DNS_FILTER_INIT" disable || remove_ok=0
    else
        echo "[-] DNS filter rollback script is missing; state retained"
        remove_ok=0
    fi
fi

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

# apply stubs executables and stops services; disabling protection should
# unmount the stubs (including the untracked upnpd one) and turn the services
# back on, or they stay down until the next reboot.
services_restore

if [ "$remove_ok" -ne 1 ]; then
    echo "[-] one or more DNS handoff rollback operations failed"
    exit 1
fi

echo "==== done ===="
