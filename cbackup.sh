#!/usr/bin/env bash

# cbackup: Simple full app + data + metadata backup/restore script for Android
#
# Required Termux packages: tsu tar sed zstd openssl-tool
# Optional packages: pv
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
BACKUP_VERSION="0"
PASSWORD_CANARY="cbackup-valid"

# Settings
tmp_dir="/data/local/tmp/._cbackup_tmp"
backup_dir="${2:-/sdcard/cbackup}"
encryption_args=(-pbkdf2 -iter 200001 -aes-256-ctr)
debug=false
# WARNING: Hardcoded password FOR TESTING ONLY!
#password="cbackup-test!"
# Known broken/problemtic apps to ignore entirely
app_blacklist=(
    # Restoring Magisk Manager may cause problems with root access
    com.topjohnwu.magisk
)

# Select default action based on filename, because we self-replicate to restore.sh in backups
action="${1:-$([[ "$0" == *"restore"* ]] && echo restore || echo backup)}"

# Prints an error in bold red
function err() {
    echo -e "\e[1;31m$*\e[0m"
}

# Prints an error in bold red and exits the script
function die() {
    echo
    err "$*"
    echo

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

    # Fall back to an empty string to avoid unbound variable errors
    if [[ -z "${password:-}" ]]; then
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
}

function encrypt_to_file() {
    PASSWORD="$password" openssl enc -out "$1" "${encryption_args[@]}" -pass env:PASSWORD
}

function decrypt_file() {
    PASSWORD="$password" openssl enc -d -in "$1" "${encryption_args[@]}" -pass env:PASSWORD
}

function expect_output() {
    grep -v "$@" || true
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
app_install_failed=false
android_version="$(getprop ro.build.version.release | cut -d'.' -f1)"
rm -fr "$tmp_dir"
mkdir -p "$tmp_dir"

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

function do_backup() {
    rm -fr "$backup_dir"
    mkdir -p "$backup_dir"

    ask_password true

    # Get list of user app package names
    pm list packages --user 0 > "$tmp_dir/pm_all_pkgs.list"
    pm list packages -s --user 0 > "$tmp_dir/pm_sys_pkgs.list"
    local apps
    apps="$(grep -vf "$tmp_dir/pm_sys_pkgs.list" "$tmp_dir/pm_all_pkgs.list" | sed 's/package://g')"

    # Remove ignored apps
    dbg "Ignoring apps: ${app_blacklist[*]}"
    tr ' ' '\n' <<< "${app_blacklist[*]}" > "$tmp_dir/pm_ignored.list"
    apps="$(grep -vf "$tmp_dir/pm_ignored.list" <<< "$apps")"

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

        local app_out app_info
        app_out="$backup_dir/$app"
        mkdir "$app_out"
        app_info="$(dumpsys package "$app")"

        # cbackup metadata
        echo "$BACKUP_VERSION" > "$app_out/backup_version.txt"
        echo -n "$PASSWORD_CANARY" | encrypt_to_file "$app_out/password_canary.enc"

        # APKs
        msg "    • APK"
        mkdir "$app_out/apk"
        local apk_dir
        apk_dir="$(grep "codePath=" <<< "$app_info" | sed 's/^\s*codePath=//')"
        cp "$apk_dir/"*.apk "$app_out/apk"

        # Data
        msg "    • Data"
        pushd / > /dev/null

        # Collect list of files
        local files=(
            # CE data for user 0
            "data/data/$app/"!(@(cache|code_cache|no_backup)) \
            # DE data for user 0
            "data/user_de/0/$app/"!(@(cache|code_cache|no_backup))
        )

        # Skip backup if file list is empty
        if [[ ${#files[@]} -eq 0 ]]; then
            echo "Skipping data backup because this app has no data"
        else
            # Suspend app if possible
            local suspended=false
            if [[ "$PREFIX" == *"com.termux"* ]] && [[ "$app" == "com.termux" ]]; then
                dbg "Skipping app suspend for Termux because we're running inside it"
            elif [[ "$android_version" -ge 9 ]]; then
                dbg "Suspending app"
                pm suspend --user 0 "$app" | expect_output 'new suspended state: true'
                suspended=true
            else
                dbg "Skipping app suspend due to old Android version $android_version"
            fi

            # Finally, perform backup if we have files to back up
            tar -cf - "${files[@]}" | \
                progress_cmd -s "${app_data_sizes[$app]:-0}" |
                zstd -T0 - | \
                encrypt_to_file "$app_out/data.tar.zst.enc"

            # Unsuspend the app now that data backup is done
            if $suspended; then
                dbg "Unsuspending app"
                pm unsuspend --user 0 "$app" | expect_output 'new suspended state: false'
            fi
        fi

        popd > /dev/null

        # Permissions
        msg "    • Other"
        grep "granted=true, flags=" <<< "$app_info" | \
            sed 's/^\s*\(.*\): granted.*$/\1/g' | \
            sort | \
            uniq > "$app_out/permissions.list" \
            || true

        # SSAID
        if grep -q 'package="'"$app"'"' /data/system/users/0/settings_ssaid.xml; then
            grep 'package="'"$app"'"' /data/system/users/0/settings_ssaid.xml > "$app_out/ssaid.xml"
        fi

        # Battery optimization
        if [[ -f /data/system/deviceidle.xml ]] && grep -q "$app" /data/system/deviceidle.xml; then
            touch "$app_out/battery_opt_disabled"
        fi

        # Installer name
        if grep -q "installerPackageName=" <<< "$app_info"; then
            grep "installerPackageName=" <<< "$app_info" | \
                sed 's/^\s*installerPackageName=//' > "$app_out/installer_name.txt"
        fi

        echo
    done

    # Copy script into backup for easy restoration
    cp "$0" "$backup_dir/restore.sh"
}

function do_restore() {
    # First pass to show the user a list of apps to restore
    local apps=()
    local app_dir
    for app_dir in "$backup_dir/"*
    do
        if [[ ! -d "$app_dir" ]]; then
            dbg "Ignoring non-directory $app_dir"
            continue
        fi

        dbg "Discovered app $app_dir"
        app="$(basename "$app_dir")"
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
        local app_dir="$backup_dir/$app"
        msg "Restoring $app..."

        # Check version
        if [[ ! -f "$app_dir/backup_version.txt" ]]; then
            die "Backup version is missing"
        else
            local bver
            bver="$(cat "$app_dir/backup_version.txt")"
            if [[ "$bver" != "$BACKUP_VERSION" ]]; then
                die "Incompatible backup version $bver, expected $BACKUP_VERSION"
            fi
        fi

        # Check password canary
        if [[ "$(decrypt_file "$app_dir/password_canary.enc")" != "$PASSWORD_CANARY" ]]; then
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
        local suspended=false
        if $termux_inplace; then
            echo "Skipped because we're running in Termux"
        else
            # Proceed with APK installation

            # Uninstall old app if already installed
            # We don't just clear data because there are countless other Android
            # metadata values that are hard to clean: SSAIDs, permissions, special
            # permissions, etc.
            if grep -q "$app" <<< "$installed_apps"; then
                dbg "Uninstalling old copy of app"
                pm uninstall --user 0 "$app" | expect_output Success
            fi

            # Prepare to invoke pm install
            local pm_install_args=(
                # Allow test packages (i.e. ones installed by Android Studio's "Run" button)
                -t
                # Only install for user 0
                --user 0
                # Set expected package name
                --pkg "$app"
            )

            # Installed due to device restore (on Android 10+)
            if [[ "$android_version" -ge 10 ]]; then
                pm_install_args+=(--install-reason 2)
            fi

            # Installer name
            if [[ -f "$app_dir/installer_name.txt" ]]; then
                pm_install_args+=(-i "$(cat "$app_dir/installer_name.txt")")
            fi
            dbg "PM install args: ${pm_install_args[*]}"

            # Install split APKs
            local pm_session
            pm_session="$(pm install-create "${pm_install_args[@]}" | sed 's/^.*\[\([[:digit:]]*\)\].*$/\1/')"
            dbg "PM session: $pm_session"

            local apk
            for apk in "$app_dir/apk/"*
            do
                # We need to specify size because we're streaming it to pm through stdin
                # to avoid creating a temporary file
                local apk_size split_name
                apk_size="$(wc -c "$apk" | cut -d' ' -f1)"
                split_name="$(basename "$apk")"

                dbg "Writing $apk_size-byte APK $apk with split name $split_name to session $pm_session"
                cat "$apk" | pm install-write -S "$apk_size" "$pm_session" "$split_name" | expect_output Success
            done

            pm install-commit "$pm_session" | expect_output Success || {
                err "Installation failed; skipping app"
                app_install_failed=true
                echo

                continue
            }

            if [[ "$android_version" -ge 9 ]]; then
                pm suspend --user 0 "$app" | expect_output 'new suspended state: true'
                suspended=true
            else
                dbg "Skipping app suspend due to old Android version $android_version"
            fi
        fi

        # Get info of newly installed app
        local app_info
        app_info="$(dumpsys package "$app")"

        # Data
        msg "    • Data"
        local data_dir="/data/data/$app"
        local de_data_dir="/data/user_de/0/$app"

        # We can't delete and extract directly to the Termux root because we
        # need to use Termux-provided tools for extracting app data
        local out_root_dir
        if $termux_inplace; then
            # This temporary output directory must be in /data/data to apply the
            # correct FBE key, so we can avoid a copy when swapping directories
            out_root_dir="$(dirname "$data_dir")/._cbackup_termux_inplace_restore"

            dbg "Using $out_root_dir for temporary in-place operations"
            rm -fr "$out_root_dir"
            mkdir -p "$out_root_dir"
        else
            out_root_dir="/"
        fi

        # Create new data directory for in-place Termux restore
        # No extra slash here because both are supposed to be absolute paths
        local new_data_dir="$out_root_dir$data_dir"
        dbg "New temporary data directory is $new_data_dir"
        mkdir -p "$new_data_dir"
        chmod 700 "$new_data_dir"

        # Get UID and GIDs
        local uid
        uid="$(grep "userId=" <<< "$app_info" | head -1 | sed 's/^\s*userId=//')"
        dbg "App UID/GID is $uid"
        local gid_cache="$((uid + 10000))"
        dbg "App cache GID is $gid_cache"

        # Get SELinux context from the system-created data directory
        # Parsing the output of ls is not ideal, but Termux doesn't come with any
        # tools for this.
        # TODO: Fix the sporadic failure codes instead of silencing them with a declaration
        # shellcheck disable=SC2012
        local secontext="$(/system/bin/ls -a1Z "$data_dir" | head -1 | cut -d' ' -f1)"
        dbg "App SELinux context is $secontext"

        # Finally, extract the app data
        local data_archive="$app_dir/data.tar.zst.enc"
        if [[ -f "$data_archive" ]]; then
            dbg "Extracting data with encryption args: ${encryption_args[*]}"
            decrypt_file "$app_dir/data.tar.zst.enc" | \
                zstd -d -T0 - | \
                progress_cmd | \
                tar -C "$out_root_dir" -xf -
        else
            echo "No data backup found"
        fi

        # Fix ownership
        dbg "Updating data owner to $uid"
        chown -R "$uid:$uid" "$new_data_dir" "$de_data_dir"
        local cache_dirs=("$new_data_dir/"*cache* "$de_data_dir/"*cache*)
        if [[ ${#cache_dirs[@]} -ne 0 ]]; then
            dbg "Updating cache owner group to $gid_cache"
            chown -R "$uid:$gid_cache" "$new_data_dir/"*cache* "$de_data_dir/"*cache*
        fi

        # Fix SELinux context
        dbg "Updating SELinux context to $secontext"
        # We need to use Android chcon to avoid "Operation not supported on transport endpoint" errors
        /system/bin/chcon -hR "$secontext" "$new_data_dir" "$de_data_dir"

        # Perform in-place Termux hotswap if necessary
        if $termux_inplace; then
            dbg "Hotswapping Termux data for in-place restore"

            # Swap out the old one immediately and defer cleanup to later
            # This does leave a small window during which no directory is present,
            # but we can't get around that without using the relatively new
            # renameat(2) syscall, which isn't exposed by coreutils.
            dbg "Swapping out current data directory"
            mv "$data_dir" "$out_root_dir/_old_data"

            # ---------------------- DANGER DANGER DANGER ----------------------
            # We need to be careful with the commands we use here because Termux
            # executables are no longer available! This backup script will crash
            # and the user will be left with a broken Termux install (among other
            # unrestored apps) if anything in here breaks. Only Android system
            # executables and shell builtins are safe to use in here.
            # ---------------------- DANGER DANGER DANGER ----------------------

            # Swap in the new one ASAP
            # LD_PRELOAD points to a file in Termux, so we need to unset it temporarily
            dbg "Switching to new data directory"
            (unset LD_PRELOAD; /system/bin/mv "$new_data_dir" "$data_dir")

            # Update cwd for the new directory inode
            # Fall back to Termux HOME if cwd doesn't exist in the restored env
            dbg "Updating $PWD CWD"
            cd "$PWD" || cd "$HOME"

            # Rehash PATH cache since we might have new executable paths now
            dbg "Refreshing shell PATH cache"
            hash -r

            # Check for the presence of optional commands again
            dbg "Re-checking for optional commands"
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
        for perm in $(cat "$app_dir/permissions.list")
        do
            dbg "Granting permission $perm"
            pm grant --user 0 "$app" "$perm" || warn "Failed to grant permission $perm!"
        done

        # SSAID
        if [[ -f "$app_dir/ssaid.xml" ]]; then
            dbg "Restoring SSAID: $(cat "$app_dir/ssaid.xml")"
            cat "$app_dir/ssaid.xml" >> /data/system/users/0/settings_ssaid.xml
            ssaid_restored=true
        fi

        # Battery optimization
        if [[ -f "$app_dir/battery_opt_disabled" ]]; then
            dbg "Whitelisting in deviceidle"
            dumpsys deviceidle whitelist "+$app" | expect_output Added
        fi

        # Unsuspend app now that restoration is finished
        if $suspended; then
            dbg "Unsuspending app"
            pm unsuspend --user 0 "$app" | expect_output 'new suspended state: false'
        fi

        echo
    done
}

# Run action
echo "Performing action '$action'"
if [[ "$action" == "backup" ]]; then
    do_backup
elif [[ "$action" == "restore" ]]; then
    do_restore
else
    die "Unknown action '$action'"
fi

# Cleanup
rm -fr "$tmp_dir"

echo
echo
msg "========================"
msg "Backup/restore finished!"
msg "========================"
echo
echo

if [[ "$ssaid_restored" == "true" ]]; then
    warn "SSAIDs were restored
====================
Warning: Restored SSAIDs will be lost if you do not reboot IMMEDIATELY!"
fi

if [[ "$termux_restored" == "true" ]]; then
    warn "Termux was restored
===================
Please restart Termux as soon as possible to apply all changes.
If you cannot restart now, running the 'cd' command will fix your current shell instance."
fi

if [[ "$app_install_failed" == "true" ]]; then
    warn "One or more apps failed to install
==================================
Some apps failed to install, so data was not restored for them.
You may want to check what happened in case you are expecting their data to be restored."
fi
