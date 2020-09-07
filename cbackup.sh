#!/usr/bin/env bash

# cbackup: Simple full app + data + metadata backup/restore script for Android
#
# Required Termux packages: tsu tar sed zstd openssl-tool
# Optional packages: pv
#
# App data backups are tarballs compressed with Zstandard and encrypted with
# AES-256-CTR.
#
# Licensed under the MIT License (MIT)
# 
# Copyright (c) 2020 Danny Lin <danny@kdrag0n.dev>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -euo pipefail
shopt -s nullglob

# Constants
BACKUP_VERSION="1"
PASSWORD_CANARY="cbackup valid"

# Settings
tmp="/data/local/tmp/cbackup"
backup_dir="${2:-/sdcard/cbackup}"
encryption_args=(-pbkdf2 -iter 200001 -aes-256-ctr)
debug=false
# FIXME: hardcoded password for testing
password="cbackup-test!"

# Prints an error in bold red
function err() {
    echo
    echo -e "\e[1;31m$@\e[0m"
    echo
}

# Prints an error in bold red and exits the script
function die() {
    err "$@"
    exit 1
}

# Prints a warning in bold yellow
function warn() {
    echo
    echo -e "\e[1;33m$@\e[0m"
    echo
}

# Shows an informational message
function msg() {
    echo -e "\e[1;32m$@\e[0m"
}

# Shows a debug message
function dbg() {
    if [[ "$debug" == "true" ]]; then
        echo "$@"
    fi
}

function encrypt_stream() {
    PASSWORD="$password" openssl enc "${encryption_args[@]}" -pass env:PASSWORD
}

function decrypt_file() {
    PASSWORD="$password" openssl enc -d -in "$1" "${encryption_args[@]}" -pass env:PASSWORD
}

# Setup
ssaid_restored=false
rm -fr "$tmp"
mkdir -p "$tmp"

# Degrade gracefully if pv is not available
if type pv > /dev/null; then
    progress_cmd="pv"
else
    progress_cmd="cat"
fi

do_backup() {
    rm -fr "$backup_dir"
    mkdir -p "$backup_dir"

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

        # cbackup metadata
        echo "$BACKUP_VERSION" > "$appout/backup_version.txt"
        echo -n "$PASSWORD_CANARY" | encrypt_stream > "$appout/password_canary.bin"

        # APKs
        msg "    • APK"
        mkdir "$appout/apk"
        apkdir="$(grep "codePath=" <<< "$appinfo" | sed 's/^\s*codePath=//')"
        cp "$apkdir/base.apk" "$apkdir/split_"* "$appout/apk"

        # Data
        msg "    • Data"
        tar -C / -cf - "data/data/$app" | \
            zstd -T0 - | \
            encrypt_stream | \
            $progress_cmd > "$appout/data.tar.zst.enc"

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
        if grep -q "installerPackageName=" <<< "$appinfo"; then
            grep "installerPackageName=" <<< "$appinfo" | \
                sed 's/^\s*installerPackageName=//' > "$appout/installer_name.txt"
        fi

        echo
    done

    # Copy script into backup for easy restoration
    cp "$0" "$backup_dir/restore.sh"
}

do_restore() {
    # First pass to show the user a list of apps to restore
    apps=()
    for appdir in "$backup_dir/"*
    do
        dbg "Discovered app $appdir"
        app="$(basename "$appdir")"
        apps+=("$app")
    done

    echo "Apps to restore:"
    tr ' ' '\n' <<< "${apps[@]}"
    echo
    echo

    for app in "${apps[@]}"
    do
        appdir="$backup_dir/$app"
        msg "Restoring $app..."

        # Check version
        if [[ ! -f "$appdir/backup_version.txt" ]]; then
            die "Backup version is missing"
        else
            bver="$(cat "$appdir/backup_version.txt")"
            if [[ "$bver" != "$BACKUP_VERSION" ]]; then
                die "Incompatible backup version $bver, expected $BACKUP_VERSION"
            fi
        fi

        # Check password canary
        if [[ "$(decrypt_file "$appdir/password_canary.bin")" != "$PASSWORD_CANARY" ]]; then
            die "Incorrect password or corrupted backup!"
        fi

        # APKs
        msg "    • APK"
        # Install reason 2 = device restore
        pm_install_args=(--install-reason 2 --restrict-permissions --user 0 --pkg "$app")
        # Installer name
        if [[ -f "$appdir/installer_name.txt" ]]; then
            pm_install_args+=(-i "$(cat "$appdir/installer_name.txt")")
        fi
        dbg "PM install args: ${pm_install_args[@]}"

        # Install split APKs
        pm_session="$(pm install-create "${pm_install_args[@]}" | sed 's/^.*\[\([[:digit:]]*\)\].*$/\1/')"
        dbg "PM session: $pm_session"
        for apk in "$appdir/apk/"*
        do
            # We need to specify size because we're streaming it to pm through stdin
            # to avoid creating a temporary file
            apk_size="$(wc -c "$apk" | cut -d' ' -f1)"
            split_name="$(basename "$apk")"
            dbg "Writing $apk_size-byte APK $apk with split name $split_name to session $pm_session"
            cat "$apk" | pm install-write -S "$apk_size" "$pm_session" "$split_name" > /dev/null
        done
        pm install-commit "$pm_session" > /dev/null
        appinfo="$(dumpsys package "$app")"

        # Data
        msg "    • Data"
        dbg "Extracting data with encryption args: ${encryption_args[@]}"
        decrypt_file "$appdir/data.tar.zst.enc" | \
            zstd -d -T0 - | \
            $progress_cmd | \
            tar -C / -xf -

        uid="$(grep "userId=" <<< "$appinfo" | sed 's/^\s*userId=//')"
        gid_cache="$((uid + 10000))"
        app_id="$((uid - 10000))"
        secontext="u:object_r:app_data_file:s0:c$app_id,c256,c512,c768"

        dbg "Changing data owner to $uid and cache to $gid_cache"
        chown -R "$uid:$uid" "/data/data/$app"
        chown -R "$uid:$gid_cache" "/data/data/$app/"*cache*

        dbg "Changing SELinux context to $secontext"
        # We need to use Android chcon to avoid "Operation not supported on transport endpoint" errors
        /system/bin/chcon -hR "$secontext" "/data/data/$app"

        # Permissions
        msg "    • Other (permissions, SSAID, battery optimization, installer name)"
        for perm in $(cat "$appdir/permissions.list")
        do
            dbg "Granting permission $perm"
            pm grant --user 0 "$app" "$perm"
        done

        # SSAID
        if [[ -f "$appdir/ssaid.xml" ]]; then
            dbg "Restoring SSAID: $(cat "$appdir/ssaid.xml")"
            cat "$appdir/ssaid.xml" >> /data/system/users/0/settings_ssaid.xml
            ssaid_restored=true
        fi

        # Battery optimization
        if [[ -f "$appdir/battery_opt_disabled" ]]; then
            dbg "Whitelisting in deviceidle"
            dumpsys deviceidle whitelist "+$app"
        fi

        # Installer name was already restored during APK installation, but we still
        # print it in this section to make the output consistent with backup mode

        echo
    done
}

# "$1" might be unbound here, so we need to temporarily allow unbound variables
set +u
if [[ -z "$1" ]]; then
    set -u
    echo "No action specified, defaulting to backup"
    do_backup
else
    set -u
    if [[ "$1" == "backup" ]]; then
        do_backup
    elif [[ "$1" == "restore" ]]; then
        do_restore
    fi
fi

# Cleanup
rm -fr "$tmp"

echo
echo
msg "========================"
msg "Backup/restore finished!"
msg "========================"

if [[ "$ssaid_restored" == "true" ]]; then
    warn "Warning: Restored SSAIDs will be lost if you do not reboot IMMEDIATELY!"
fi
