#!/usr/bin/env sh

# Print executed commands and exit on error
set -ve

# cbackup Termux quickstart script
# https://git.io/JUl3K
# Run script: sh -c "$(curl -LSs https://git.io/JUl3K)"
# We use sh -c "$(...)" to mitigate timing attacks

# Install dependencies
pkg install -y tsu tar sed zstd openssl-tool pv curl

# Download main script
curl -O https://raw.githubusercontent.com/kdrag0n/cbackup/master/cbackup.sh

# We don't use binfmt_script to here, but add the execute permission so the user can manually run it later
chmod +x cbackup.sh

# Finally, run the downloaded script and replace the quickstart script's shell with it
# Arguments passed to a `sh -c` pipe start at $0, so we need to include it explicitly
exec sudo bash cbackup.sh "$0" "$@"
