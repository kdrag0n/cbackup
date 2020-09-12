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
shopt -s nullglob dotglob extglob

# Constants
BACKUP_VERSION="1"
PASSWORD_CANARY="cbackup-valid"

# Settings
tmp="/data/local/tmp/cbackup"
backup_dir="${2:-/sdcard/cbackup}"
encryption_args=(-pbkdf2 -iter 200001 -aes-256-ctr)
debug=false
# WARNING: Hardcoded password FOR TESTING ONLY!
password="cbackup-test!"

# Prints an error in bold red
function err() {
    echo
    echo -e "\e[1;31m$*\e[0m"
    echo
}

# Prints an error in bold red and exits the script
function die() {
    err "$*"
    exit 1
}

# Prints a warning in bold yellow
function warn() {
    echo
    echo -e "\e[1;33m$*\e[0m"
    echo
}

# Shows an informational message
function msg() {
    echo -e "\e[1;32m$*\e[0m"
}

# Shows a debug message
function dbg() {
    if [[ "$debug" == "true" ]]; then
        echo "$*"
    fi
}

function ask_password() {
    local confirm="$1"

    # password is likely to be unbound here
    set +u
    if [[ -z "$password" ]]; then
        set -u

        if [[ "$confirm" == "true" ]]; then
            read -rsp "Enter password for backup: " password
            echo
            read -rsp "Confirm password: " password2
            echo

            if [[ "$password2" != "$password" ]]; then
                die "Mismatching passwords!"
            fi

            unset -v password2
            echo
        else
            read -rsp "Enter backup password: " password
        fi
    fi

    set -u
}

function encrypt_to_file() {
    PASSWORD="$password" openssl enc -out "$1" "${encryption_args[@]}" -pass env:PASSWORD
}

function decrypt_file() {
    PASSWORD="$password" openssl enc -d -in "$1" "${encryption_args[@]}" -pass env:PASSWORD
}

function parse_diskstats_array() {
    local diskstats="$1"
    local label="$2"

    grep "$label: " <<< "$diskstats" | \
        sed "s/$label: //" | \
        tr -d '"[]' | \
        tr ',' '\n'
}

function get_app_data_sizes() {
    local diskstats pkg_names data_sizes end_idx
    declare -n size_map="$1"

    diskstats="$(dumpsys diskstats)"
    mapfile -t pkg_names < <(parse_diskstats_array "$diskstats" "Package Names")
    mapfile -t data_sizes < <(parse_diskstats_array "$diskstats" "App Data Sizes")
    end_idx="$((${#data_sizes[@]} - 1))"

    for i in $(seq 0 $end_idx)
    do
        # This is a name reference that should be used by the caller.
        # shellcheck disable=SC2034
        size_map["${pkg_names[$i]}"]="${data_sizes[$i]}"
    done
}

# Setup
ssaid_restored=false
termux_restored=false
rm -fr "$tmp"
mkdir -p "$tmp"

# Degrade gracefully if optional commands are not available
# This is a function so we can update it after in-place Termux restoration
function check_optional_cmds() {
    unset -f progress_cmd

    if type pv > /dev/null; then
        function progress_cmd() {
            pv "$@"
        }
    else
        function progress_cmd() {
            # Ignore pv arguments
            cat
        }
    fi
}

check_optional_cmds

do_backup() {
    rm -fr "$backup_dir"
    mkdir -p "$backup_dir"

    ask_password true

    # Get list of user app package names
    pm list packages --user 0 > "$tmp/pm_all_pkgs.list"
    pm list packages -s --user 0 > "$tmp/pm_sys_pkgs.list"
    local apps
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
com.termux.styling
"

    echo "Apps to backup:"
    echo "$apps"
    echo
    echo

    # Get map of app data sizes
    declare -A app_data_sizes
    get_app_data_sizes app_data_sizes

    # Back up apps
    local app
    for app in $apps
    do
        msg "Backing up $app..."

        local appout appinfo
        appout="$backup_dir/$app"
        mkdir "$appout"
        appinfo="$(dumpsys package "$app")"

        # cbackup metadata
        echo "$BACKUP_VERSION" > "$appout/backup_version.txt"
        echo -n "$PASSWORD_CANARY" | encrypt_to_file "$appout/password_canary.bin"

        # APKs
        msg "    • APK"
        mkdir "$appout/apk"
        local apkdir
        apkdir="$(grep "codePath=" <<< "$appinfo" | sed 's/^\s*codePath=//')"
        cp "$apkdir/base.apk" "$apkdir/split_"* "$appout/apk"

        # Data
        msg "    • Data"
        pushd / > /dev/null
        tar -cf - "data/data/$app" "data/data/$app/"!(@(cache|code_cache|no_backup)) | \
            progress_cmd -s "${app_data_sizes[$app]}" |
            zstd -T0 - | \
            encrypt_to_file "$appout/data.tar.zst.enc"
        popd > /dev/null

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
    local apps=()
    local appdir
    for appdir in "$backup_dir/"*
    do
        if [[ ! -d "$appdir" ]]; then
            dbg "Ignoring non-directory $appdir"
            continue
        fi

        dbg "Discovered app $appdir"
        app="$(basename "$appdir")"
        apps+=("$app")
    done

    ask_password false

    echo "Apps to restore:"
    tr ' ' '\n' <<< "${apps[@]}"
    echo
    echo

    local installed_apps
    installed_apps="$(pm list packages --user 0 | sed 's/package://g')"

    local app
    for app in "${apps[@]}"
    do
        local appdir="$backup_dir/$app"
        msg "Restoring $app..."

        # Check version
        if [[ ! -f "$appdir/backup_version.txt" ]]; then
            die "Backup version is missing"
        else
            local bver
            bver="$(cat "$appdir/backup_version.txt")"
            if [[ "$bver" != "$BACKUP_VERSION" ]]; then
                die "Incompatible backup version $bver, expected $BACKUP_VERSION"
            fi
        fi

        # Check password canary
        if [[ "$(decrypt_file "$appdir/password_canary.bin")" != "$PASSWORD_CANARY" ]]; then
            die "Incorrect password or corrupted backup!"
        fi

        # Check whether we need special in-place restoration for Termux
        local termux_inplace
        if [[ "$PREFIX" == *"com.termux"* ]] && [[ "$app" == "com.termux" ]]; then
            termux_inplace=true
            dbg "Performing in-place Termux restore"
        else
            termux_inplace=false
        fi

        # APKs
        msg "    • APK"
        if $termux_inplace; then
            echo "      > Skipped because we're running in Termux"
        else
            # Proceed with APK installation

            # Uninstall old app if already installed
            # We don't just clear data because there are countless other Android
            # metadata values that are hard to clean: SSAIDs, permissions, special
            # permissions, etc.
            if grep -q "$app" <<< "$installed_apps"; then
                dbg "Uninstalling old copy of app"
                pm uninstall --user 0 "$app"
            fi

            # Install reason 2 = device restore
            local pm_install_args=(--install-reason 2 --restrict-permissions --user 0 --pkg "$app")
            # Installer name
            if [[ -f "$appdir/installer_name.txt" ]]; then
                pm_install_args+=(-i "$(cat "$appdir/installer_name.txt")")
            fi
            dbg "PM install args: ${pm_install_args[*]}"

            # Install split APKs
            local pm_session
            pm_session="$(pm install-create "${pm_install_args[@]}" | sed 's/^.*\[\([[:digit:]]*\)\].*$/\1/')"
            dbg "PM session: $pm_session"

            local apk
            for apk in "$appdir/apk/"*
            do
                # We need to specify size because we're streaming it to pm through stdin
                # to avoid creating a temporary file
                local apk_size split_name
                apk_size="$(wc -c "$apk" | cut -d' ' -f1)"
                split_name="$(basename "$apk")"

                dbg "Writing $apk_size-byte APK $apk with split name $split_name to session $pm_session"
                cat "$apk" | pm install-write -S "$apk_size" "$pm_session" "$split_name" > /dev/null
            done

            pm install-commit "$pm_session" > /dev/null
        fi

        # Get info of newly installed app
        local appinfo
        appinfo="$(dumpsys package "$app")"

        # Data
        msg "    • Data"
        local datadir="/data/data/$app"

        # We can't delete and extract directly to the Termux root because we
        # need to use Termux-provided tools for extracting app data
        local out_root_dir
        if $termux_inplace; then
            # This temporary output directory must be in /data/data to apply the
            # correct FBE key, so we can avoid a copy when swapping directories
            out_root_dir="$(dirname "$datadir")/._cbackup_termux_inplace_restore"
            rm -fr "$out_root_dir"
            mkdir -p "$out_root_dir"
        else
            out_root_dir="/"

            # At this point, we can delete Android's placeholder app data for
            # normal apps, but deleting it for Termux is NOT safe!
            dbg "Clearing placeholder app data"
            rm -fr "${datadir:?}/"*
        fi

        # Create new data directory for in-place Termux restore
        # No extra slash here because both are supposed to be absolute paths
        local new_data_dir="$out_root_dir$datadir"
        mkdir -p "$new_data_dir"
        chmod 700 "$new_data_dir"

        # Get UID and GIDs
        local uid
        uid="$(grep "userId=" <<< "$appinfo" | head -1 | sed 's/^\s*userId=//')"
        local gid_cache="$((uid + 10000))"

        # Get SELinux context from the system-created data directory
        local secontext
        # There's no other way to get the SELinux context.
        # shellcheck disable=SC2012
        secontext="$(/system/bin/ls -a1Z "$datadir" | head -1 | cut -d' ' -f1)"

        # Finally, extract the app data
        dbg "Extracting data with encryption args: ${encryption_args[*]}"
        decrypt_file "$appdir/data.tar.zst.enc" | \
            zstd -d -T0 - | \
            progress_cmd | \
            tar -C "$out_root_dir" -xf -

        # Fix ownership
        dbg "Updating data owner to $uid and cache to $gid_cache"
        chown -R "$uid:$uid" "$new_data_dir"
        chown -R "$uid:$gid_cache" "$new_data_dir/"*cache*

        # Fix SELinux context
        dbg "Updating SELinux context to $secontext"
        # We need to use Android chcon to avoid "Operation not supported on transport endpoint" errors
        /system/bin/chcon -hR "$secontext" "$new_data_dir"

        # Perform in-place Termux hotswap if necessary
        if $termux_inplace; then
            dbg "Hotswapping Termux data for in-place restore"

            # Swap out the old one immediately and defer cleanup to later
            # This does leave a small window during which no directory is present,
            # but we can't get around that without using the relatively new
            # renameat(2) syscall, which isn't exposed by coreutils.
            dbg "Swapping out current data directory"
            mv "$datadir" "$out_root_dir/_old_data"

            # ---------------------- DANGER DANGER DANGER ----------------------
            # We need to be careful with the commands we use here because Termux
            # executables are no longer available! This backup script will crash
            # and the user will be left with a broken Termux install (among other
            # unrestored apps) if anything in here breaks. Only Android system
            # executables and shell builtins are safe to use in here.
            # ---------------------- DANGER DANGER DANGER ----------------------

            # Swap in the new one ASAP
            dbg "Switching to new data directory"
            LD_PRELOAD= /system/bin/mv "$new_data_dir" "$datadir"

            # Update cwd for the new directory inode
            # Fall back to Termux HOME if cwd doesn't exist in the restored env
            cd "$PWD" || cd "$HOME"

            # Rehash PATH cache since we might have new executable paths now
            hash -r

            # Check for the presence of optional commands again
            check_optional_cmds

            # ------------------------- END OF DANGER --------------------------
            # At this point, the backup's Termux install has been restored and
            # our shell state has been updated to account for the new environment,
            # so we can safely use all commands again.
            # ------------------------- END OF DANGER --------------------------

            # Clean up temporary directory structures and old data directory left
            # over from swapping
            dbg "Deleting old app data directory"
            rm -fr "$out_root_dir"

            # Set flag to print Termux restoration warning
            termux_restored=true
        fi

        # Permissions
        msg "    • Other"
        local perm
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

    if [[ "$0" == *"restore"* ]]; then
        do_restore
    else
        echo "No action specified, defaulting to backup"
        do_backup
    fi
else
    set -u

    if [[ "$1" == "backup" ]]; then
        do_backup
    elif [[ "$1" == "restore" ]]; then
        do_restore
    else
        die "Unknown action '$1'"
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
    warn "SSAIDs were restored
====================
Warning: Restored SSAIDs will be lost if you do not reboot IMMEDIATELY!"
fi

if [[ "$termux_restored" == "true" ]]; then
    warn "Termux was restored
===================
Please restart Termux as soon as possible to apply all changes.
If you cannot restart now, running the 'cd' command will will fix your current shell instance."
fi
