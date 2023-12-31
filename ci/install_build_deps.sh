#!/usr/bin/env bash
#!/bin/bash

set -e
# set -u
. $(dirname $(realpath "$BASH_SOURCE"))/head.sh

APT_CONF_FILE=/etc/apt/apt.conf.d/50build-deb-action

export DEBIAN_FRONTEND=noninteractive

cat | sudo tee "$APT_CONF_FILE" <<-EOF
APT::Get::Assume-Yes "yes";
APT::Install-Recommends "no";
Acquire::Languages "none";
quiet "yes";
EOF

# debconf has priority “required” and is indirectly depended on by some
# essential packages. It is reasonably safe to blindly assume it is installed.
printf "man-db man-db/auto-update boolean false\n" | sudo debconf-set-selections

# add repository for install missing depends
grep -r "/ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*.list >/dev/null 2>&1 ||
    sudo add-apt-repository ppa:ondrej/php -y

sudo apt-get update

# shellcheck disable=SC2086
sudo apt-get build-dep $INPUT_APT_OPTS -- "./$INPUT_SOURCE_DIR"

# In theory, explicitly installing dpkg-dev would not be necessary. `apt-get
# build-dep` will *always* install build-essential which depends on dpkg-dev.
# But let’s be explicit here.
# shellcheck disable=SC2086
sudo apt-get install $INPUT_APT_OPTS -- dpkg-dev libdpkg-perl dput $INPUT_EXTRA_BUILD_DEPS
