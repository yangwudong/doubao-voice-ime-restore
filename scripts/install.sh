#!/usr/bin/env bash
#
# Installs DoubaoVoiceRestore as a per-user LaunchAgent so it starts at login.
#
# Three ways to run it, with the same end result:
#
#   1. Remote, no checkout — downloads the latest release binary from GitHub:
#        curl -fsSL https://raw.githubusercontent.com/yangwudong/doubao-voice-ime-restore/main/scripts/install.sh | bash
#   2. From an unzipped release archive — uses the binary next to this script:
#        bash install.sh
#   3. From a source checkout — builds with the local Swift toolchain:
#        bash scripts/install.sh    (or: make install)
#
# Environment variables:
#   DVR_VERSION   Release tag to install, e.g. v1.0.0 (default: latest)
#   DVR_MIRROR    URL prefix for the GitHub download, for networks where
#                 github.com is slow or blocked, e.g. https://ghfast.top/

set -euo pipefail

readonly APP="DoubaoVoiceRestore"
readonly REPO="yangwudong/doubao-voice-ime-restore"
readonly ASSET="doubao-voice-ime-restore-macos-universal.zip"
readonly LABEL="io.github.yangwudong.doubao-voice-ime-restore"
# Labels used by earlier versions; booted out and removed so two copies of the
# agent can never race to restore the input source.
readonly LEGACY_LABELS=("com.doubao-voice-restore")

readonly SUPPORT_DIR="$HOME/Library/Application Support/$APP"
readonly INSTALLED_BIN="$SUPPORT_DIR/$APP"
readonly LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
readonly LOG_FILE="$HOME/Library/Logs/$APP.log"
DOMAIN="gui/$(id -u)"
readonly DOMAIN

# Empty when the script is piped from curl, since there is no file on disk.
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
	SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
else
	SCRIPT_DIR=""
fi
readonly SCRIPT_DIR

staging_dir=""
source_bin=""

info() { printf '==> %s\n' "$1"; }
die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}
cleanup() {
	if [[ -n "$staging_dir" ]]; then
		rm -rf "$staging_dir"
	fi
}
trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || die "this tool only runs on macOS."

# Downloads the release archive and sets source_bin to the binary inside it.
download_release() {
	command -v curl >/dev/null 2>&1 || die "curl is required to download a release."

	local version="${DVR_VERSION:-latest}"
	local url
	if [[ "$version" == "latest" ]]; then
		url="https://github.com/$REPO/releases/latest/download/$ASSET"
	else
		url="https://github.com/$REPO/releases/download/$version/$ASSET"
	fi
	url="${DVR_MIRROR:-}$url"

	staging_dir="$(mktemp -d)"

	info "Downloading the $version release"
	info "$url"
	curl -fsSL --connect-timeout 10 --retry 3 -o "$staging_dir/$ASSET" "$url" ||
		die "download failed. If github.com is unreachable, retry with DVR_MIRROR set to a GitHub mirror prefix."

	ditto -x -k "$staging_dir/$ASSET" "$staging_dir/unpacked" ||
		die "the downloaded archive could not be expanded."

	source_bin="$(/usr/bin/find "$staging_dir/unpacked" -type f -name "$APP" -print -quit)"
	[[ -n "$source_bin" ]] || die "no $APP binary found inside $ASSET."
	chmod +x "$source_bin"
}

# Prefers a binary shipped next to this script, then a local build, then a
# download from GitHub. Sets source_bin.
#
# Deliberately not called in a command substitution: a subshell would discard
# staging_dir and leak the temporary download directory past the EXIT trap.
locate_binary() {
	if [[ -n "$SCRIPT_DIR" && -x "$SCRIPT_DIR/$APP" ]]; then
		source_bin="$SCRIPT_DIR/$APP"
		return
	fi

	if [[ -n "$SCRIPT_DIR" ]]; then
		local repo_root
		repo_root="$(cd -- "$SCRIPT_DIR/.." && pwd)"
		if [[ -f "$repo_root/Package.swift" ]] && command -v swift >/dev/null 2>&1; then
			info "Building $APP from source"
			(cd -- "$repo_root" && swift build -c release) || die "build failed."
			source_bin="$repo_root/.build/release/$APP"
			return
		fi
	fi

	download_release
}

locate_binary
[[ -x "$source_bin" ]] || die "${source_bin:-no binary} is not executable."

info "Stopping any previous instance"
for label in "$LABEL" "${LEGACY_LABELS[@]}"; do
	launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
for label in "${LEGACY_LABELS[@]}"; do
	rm -f "$LAUNCH_AGENTS_DIR/$label.plist"
done

info "Installing to $SUPPORT_DIR"
mkdir -p "$SUPPORT_DIR" "$LAUNCH_AGENTS_DIR" "$(dirname -- "$LOG_FILE")"
install -m 755 "$source_bin" "$INSTALLED_BIN"
# Clear the download flag and ad-hoc sign, so Gatekeeper lets launchd start it.
xattr -d com.apple.quarantine "$INSTALLED_BIN" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$INSTALLED_BIN" >/dev/null 2>&1 || true

info "Registering the LaunchAgent"
cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED_BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$LOG_FILE</string>
	<key>StandardErrorPath</key>
	<string>$LOG_FILE</string>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
sleep 1

launchctl list "$LABEL" >/dev/null 2>&1 ||
	die "the agent did not start. Check the log: tail -50 \"$LOG_FILE\""

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/uninstall.sh" ]]; then
	uninstall_hint="bash \"$SCRIPT_DIR/uninstall.sh\""
else
	uninstall_hint="curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/uninstall.sh | bash"
fi

cat <<EOF

Installed $("$INSTALLED_BIN" --version). It is running now and starts at login.

  Verify   Switch to your usual input method, hold the Doubao voice hotkey
           (right Option by default), speak, then stop. Your input method
           should come back on its own.
  Log      tail -f "$LOG_FILE"
  Remove   $uninstall_hint

EOF
tail -n 2 "$LOG_FILE" 2>/dev/null || true
