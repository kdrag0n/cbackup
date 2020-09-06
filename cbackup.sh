#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

# Requirements:
#   tsu
#   sed

# Prints an error in bold red
function err() {
    echo
    echo "\e[1;31m$@\e[0m"
    echo
}

# Prints an error in bold red and exits the script
function die() {
    err "$@"
    exit 1
}

# Shows an informational message
function msg() {
    echo -e "\e[1;32m$@\e[0m"
}

# Settings
tmp="/data/local/tmp/cbackup"
out="${1:-/sdcard/cbackup}"

# Setup
rm -fr "$tmp"
mkdir -p "$tmp"

rm -fr "$out"
mkdir -p "$out"

# Get list of user app package names
pm list packages --user 0 > "$tmp/pm_all_pkgs.list"
pm list packages -s --user 0 > "$tmp/pm_sys_pkgs.list"
apps="$(grep -vf "$tmp/pm_sys_pkgs.list" "$tmp/pm_all_pkgs.list" | sed 's/package://g')"

echo "Apps to backup:"
echo "$apps"
echo
echo

# Back up apps
for app in $apps
do
    msg "Backing up $app..."
    appout="$out/$app"
    mkdir "$appout"
    appinfo="$(dumpsys package "$app")"

    # APK
    msg "    • APK"
    mkdir "$appout/apk"
    apkdir="$(grep "codePath=" <<< "$appinfo" | sed 's/^\s*codePath=//')"
    cp "$apkdir/base.apk" "$apkdir/split_"* "$appout/apk"

    echo
done

# Cleanup
rm -fr "$tmp"

echo
echo
msg "================"
msg "Backup finished!"
msg "================"
