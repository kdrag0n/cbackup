#!/usr/bin/env sh

# cbackup Termux quickstart script
# https://git.io/cbackup-quick

# Print executed commands and exit on error
set -ve

# Install dependencies
pkg install -y tsu tar sed zstd openssl-tool pv curl

# Download main script
curl -LSsO https://raw.githubusercontent.com/kdrag0n/cbackup/master/cbackup.sh

# We don't use binfmt_script to here, but add the execute permission so the user can manually run it later
chmod +x cbackup.sh

# Arguments passed to a `sh -c` pipe start at $0, so we need to include it explicitly
# $0 is set to "bash" if no arguments were specified, so we need to ignore it in that case
if [[ "$0" == "bash" ]]; then
    args=("$@")
else
    args=("$0" "$@")
fi

# Finally, run the downloaded script and replace the quickstart script's shell with it
exec sudo bash cbackup.sh "${args[@]}"
