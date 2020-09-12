# cbackup

cbackup is a simple backup/restore script for rooted Android devices. It backs up apps, full app data, and some Android metadata.

## Quickstart

Run the following command in Termux to take a backup:

```bash
sh -c "$(curl -LSs https://git.io/JUl3K)"
```

If you're worried about piping and running a random script, the [quickstart script](https://github.com/kdrag0n/cbackup/blob/master/termux-quickstart.sh) is short and thoroughly commented, so feel free to download it and read it yourself before running it.

## Storage format

The preliminary v0 storage format is currently used by the cbackup shell script.

### v0 (preliminary)

All data related to each app is stored in a folder with the app's package name. The following files will always be present:

- `backup_version.txt`: plain-text file containing `0\n`
- `password_canary.enc`: encrypted file containing `cbackup-valid`
- `base.apk`: unencrypted base APK file
- `data.tar.zst.enc`: encrypted tarball archive containing app data, compressed with Zstandard before encrypting

The following files may or may not be present, depending on what data is associated with the app that is being backed up:

- `split_config.*.apk`: unencrypted additional split APKs with resources
- `permissions.list`: unencrypted list of granted runtime permissions
- `ssaid.xml`: system-generated SSAID entry from the SSAID settings XML
- `battery_opt_disabled`: empty file, the presence of this file indicates that battery optimization is disabled
- `installer_name.txt`: unencrypted plain-text file containing the installer app's package name

All encrypted files are encrypted using the OpenSSL CLI tool with the AES-256-CTR block cipher and 32-byte key derived from the user's password using 200,001 iterations of PBKDF2 and a random salt stored in the file's header.

App data includes both main CE-encrypted data as well as DE-encrypted (Direct Boot) data. App, code, and shader caches are always excluded, as well as files placed by apps in the dedicated no-backup folder.
