#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

# Requirements:
#   tsu
#   sed
#   zstd
#   pv
#   openssl-tool

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
encryption_args=(-pbkdf2 -iter 200001 -aes-256-ctr)
# FIXME: hardcoded password for testing
password="cbackup-test!"

# Setup
rm -fr "$tmp"
mkdir -p "$tmp"

rm -fr "$out"
mkdir -p "$out"

# Get list of user app package names
pm list packages --user 0 > "$tmp/pm_all_pkgs.list"
pm list packages -s --user 0 > "$tmp/pm_sys_pkgs.list"
apps="$(grep -vf "$tmp/pm_sys_pkgs.list" "$tmp/pm_all_pkgs.list" | sed 's/package://g')"

# FIXME: OVERRIDE FOR TESTING
apps="dev.kdrag0n.flutter.touchpaint
com.simplemobiletools.gallery.pro
com.mixplorer
org.tasks
org.bromite.bromite
com.omgodse.notally
com.isaiahvonrundstedt.fokus
com.aurora.store
org.opencv.engine
com.minar.birday
net.redsolver.noteless
com.automattic.simplenote
com.termux
"

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

    # Data
    msg "    • Data"
    tar -C / -cf - "data/data/$app" | \
        zstd -T0 - | \
        PASSWORD="$password" openssl enc "${encryption_args[@]}" -pass env:PASSWORD | \
        pv > "$appout/data.tar.zst.enc"

    echo
done

# Cleanup
rm -fr "$tmp"

echo
echo
msg "================"
msg "Backup finished!"
msg "================"
