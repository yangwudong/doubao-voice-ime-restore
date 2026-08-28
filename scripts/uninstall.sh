#!/usr/bin/env bash
#
# Removes DoubaoVoiceRestore: stops the LaunchAgent and deletes everything it
# installed. Doubao itself is never touched.

set -euo pipefail

readonly APP="DoubaoVoiceRestore"
readonly LABEL="io.github.yangwudong.doubao-voice-ime-restore"
readonly LEGACY_LABELS=("com.doubao-voice-restore")

readonly LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly SUPPORT_DIR="$HOME/Library/Application Support/$APP"
readonly LOG_FILE="$HOME/Library/Logs/$APP.log"
DOMAIN="gui/$(id -u)"
readonly DOMAIN

for label in "$LABEL" "${LEGACY_LABELS[@]}"; do
	launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
	rm -f "$LAUNCH_AGENTS_DIR/$label.plist"
done

rm -rf "$SUPPORT_DIR"
rm -f "$LOG_FILE"

printf 'Uninstalled. %s is stopped and will no longer start at login.\n' "$APP"
