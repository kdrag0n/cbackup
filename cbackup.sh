#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

# Required Termux packages: tsu sed zstd pv openssl-tool

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
backup_dir="${1:-/sdcard/cbackup}"
encryption_args=(-pbkdf2 -iter 200001 -aes-256-ctr)
# FIXME: hardcoded password for testing
password="cbackup-test!"

# Setup
rm -fr "$tmp"
mkdir -p "$tmp"

rm -fr "$backup_dir"
mkdir -p "$backup_dir"

do_backup() {
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
        appout="$backup_dir/$app"
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

        # Permissions
        msg "    • Other (permissions, SSAID, battery optimization, installer name)"
        grep "granted=true, flags=" <<< "$appinfo" | \
            sed 's/^\s*\(.*\): granted.*$/\1/g' > "$appout/permissions.list" \
            || true

        # SSAID
        if grep -q 'package="'"$app"'"' /data/system/users/0/settings_ssaid.xml; then
            grep 'package="'"$app"'"' /data/system/users/0/settings_ssaid.xml > "$appout/ssaid.xml"
        fi

        # Battery optimization
        if grep -q "$app" /data/system/deviceidle.xml; then
            touch "$appout/battery_opt_disabled"
        fi

        # Installer name
        pkginfo="$(grep 'package name="'"$app"'"' /data/system/packages.xml)"
        if grep -q "installer=" <<< "$pkginfo"; then
            sed 's/^.*installer="\(.*\)".*$/\1/' <<< "$pkginfo" > "$appout/installer_name.txt"
        fi

        echo
    done
}

do_restore() {

}

if [[ -z "$1" ]]; then
    echo "No action specified, defaulting to backup"
    do_backup
elif [[ "$1" == "backup" ]]; then
    do_backup
elif [[ "$1" == "restore" ]]; then
    do_restore
fi

# Cleanup
rm -fr "$tmp"

echo
echo
msg "========================"
msg "Backup/restore finished!"
msg "========================"
