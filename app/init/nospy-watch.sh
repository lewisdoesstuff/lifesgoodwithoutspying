#!/bin/sh
# Re-assert the voice/ad kills every minute while their toggles are on.
#
# Started detached by nospy-apply.sh. Exits by itself once both toggles are
# off. Silent; check `watch=` in nospy-ctl.sh status.

DIR="$(dirname "$(realpath "$0")")"
. "$DIR/nospy-lib.sh"

while :; do
    sleep 60
    if ! is_on voice.stop && ! is_on ads.stop; then
        exit 0
    fi
    if is_on voice.stop; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop voiceinput voiceconductor >/dev/null 2>&1
        fi
        for proc in voiceinput voiceinput_network voiceinput_preprocessor \
                    voiceinput_hidraw voiceinput_sound voiceconductor voiceclick; do
            pkill -9 "$proc" 2>/dev/null
        done
    fi
    if is_on ads.stop; then
        for proc in admanager adoverlay livepick; do
            pkill -9 "$proc" 2>/dev/null
        done
    fi
done
