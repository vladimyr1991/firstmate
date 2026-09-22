#!/usr/bin/env bash
# Install or remove one macOS LaunchAgent for one explicit firstmate home.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { printf 'usage: %s install|uninstall --home <absolute-FM_HOME>\n' "${0##*/}" >&2; }
action=${1:-}; [ "$#" -gt 0 ] && shift || true; home=
while [ "$#" -gt 0 ]; do case "$1" in --home) [ "$#" -gt 1 ] || { usage; exit 2; }; home=$2; shift 2;; --help|-h) usage; exit 0;; *) usage; exit 2;; esac; done
case "$action" in install|uninstall) :;; *) usage; exit 2;; esac
case "$home" in /*) :;; *) printf 'outside guard install: --home must be absolute\n' >&2; exit 2;; esac
[ -d "$home" ] && [ ! -L "$home" ] || { printf 'outside guard install: unsafe home\n' >&2; exit 2; }
home=$(cd "$home" && pwd -P) || exit 2
case "$(uname)" in Darwin) :;; *) printf 'outside guard install: macOS LaunchAgents only; a future scheduler adapter is required\n' >&2; exit 2;; esac
digest=$(printf %s "$home" | shasum -a 256 | awk '{print $1}') || exit 1
label="com.firstmate.watcher-outside-guard.${digest:0:20}"
agents=${FM_LAUNCH_AGENTS_DIR:-"$HOME/Library/LaunchAgents"}; plist="$agents/$label.plist"; guard="$DIR/fm-watcher-outside-guard.sh"; domain="gui/$(id -u)"
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
matches() { [ -f "$plist" ] && grep -F "$(xml "$guard")" "$plist" >/dev/null && grep -F "$(xml "$home")" "$plist" >/dev/null; }
if [ "$action" = uninstall ]; then
  [ -e "$plist" ] || exit 0
  matches || { printf 'outside guard install: refusing mismatched plist\n' >&2; exit 1; }
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f "$plist" || exit 1
  exit 0
fi
[ ! -e "$plist" ] || matches || { printf 'outside guard install: refusing mismatched plist\n' >&2; exit 1; }
mkdir -p "$agents" || exit 1
tmp=$(mktemp "$agents/.${label}.XXXXXX") || exit 1
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>' "<key>Label</key><string>$(xml "$label")</string>" '<key>ProgramArguments</key><array>' "<string>$(xml "$guard")</string><string>--home</string><string>$(xml "$home")</string>" '</array><key>StartInterval</key><integer>60</integer><key>RunAtLoad</key><true/><key>ProcessType</key><string>Background</string>' "<key>StandardOutPath</key><string>$(xml "$home/state/.watcher-outside-guard.out")</string>" "<key>StandardErrorPath</key><string>$(xml "$home/state/.watcher-outside-guard.err")</string>" '</dict></plist>' > "$tmp" || { rm -f "$tmp"; exit 1; }
if ! chmod 644 "$tmp" || ! mv -f "$tmp" "$plist"; then rm -f "$tmp"; exit 1; fi
launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist" || { rm -f "$plist"; exit 1; }
launchctl print "$domain/$label" || exit 1
printf '%s\n' "$plist"
