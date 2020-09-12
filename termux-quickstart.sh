#!/usr/bin/env sh

# cbackup Termux quickstart script
# https://git.io/JUl3K

# Install dependencies
pkg install -y tsu tar sed zstd openssl-tool pv curl

# Download main script
curl -O https://raw.githubusercontent.com/kdrag0n/cbackup/master/cbackup.sh

# We don't use binfmt_script to here, but add the execute permission so the user can manually run it later
chmod +x cbackup.sh

# Finally, run the downloaded script and replace the quickstart script's shell with it
exec sudo bash cbackup.sh
