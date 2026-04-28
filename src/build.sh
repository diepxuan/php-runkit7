#!/usr/bin/env bash
#!/bin/bash

set -e
# set -u

export DEBIAN_FRONTEND=noninteractive

# Usage:
#   error MESSAGE
error() {
    echo "::error::$*"
}

# Usage:
#   end_group
end_group() {
    echo "::endgroup::"
}

# Usage:
#   start_group GROUP_NAME
start_group() {
    echo "::group::$*"
}

env() {
    GITHUB_ENV=${GITHUB_ENV:-.env}
    param=$1
    value="${@:2}"
    grep -q "^$param=" $GITHUB_ENV &&
        sed -i "s|^$param=.*|$param=$value|" $GITHUB_ENV ||
        echo "$param=$value" >>$GITHUB_ENV
    export $param="$value"
    echo $param: $value
}
# SUDO=sudo
# command -v sudo &>/dev/null || SUDO=''
run_as_sudo() {
    _SUDO=sudo
    command -v sudo &>/dev/null || _SUDO=''
    echo "Running as sudo: $*"
    if [[ $EUID -ne 0 ]]; then
        $_SUDO $@
    else
        $@
    fi
}
SUDO=${SUDO:-'run_as_sudo'}

start_group "Dynamically set environment variable"
# directory
env source_dir $(dirname $(realpath "$BASH_SOURCE"))
env debian_dir $(realpath $source_dir/debian)
env build_dir $(realpath $source_dir/build)
env pwd_dir $(realpath $(dirname $source_dir))
env dists_dir $(realpath $pwd_dir/dists)
env ppa_dir $(realpath $pwd_dir/ppa)

# user evironment
env email ductn@diepxuan.com
env DEBEMAIL ductn@diepxuan.com
env EMAIL ductn@diepxuan.com
env DEBFULLNAME Tran Ngoc Duc
env NAME Tran Ngoc Duc

# gpg key
env GPG_KEY_ID $GPG_KEY_ID
env GPG_KEY $GPG_KEY
env DEB_SIGN_KEYID $DEB_SIGN_KEYID

# debian
env changelog $(realpath $debian_dir/changelog)
env control $(realpath $debian_dir/control)
env controlin $(realpath $debian_dir/control.in)
env rules $(realpath $debian_dir/rules)
env timelog "$(Lang=C date -R)"

# plugin
env repository ${repository:-diepxuan/$MODULE}
env owner $(echo $repository | cut -d '/' -f1)
env project $(echo $repository | cut -d '/' -f2)
env module $(echo $project | sed 's/^php-//g')

# os evironment
[[ -f /etc/os-release ]] && . /etc/os-release
[[ -f /etc/lsb-release ]] && . /etc/lsb-release
CODENAME=${CODENAME:-$DISTRIB_CODENAME}
CODENAME=${CODENAME:-$VERSION_CODENAME}
CODENAME=${CODENAME:-$UBUNTU_CODENAME}

RELEASE=${RELEASE:-$(echo $DISTRIB_DESCRIPTION | awk '{print $2}')}
RELEASE=${RELEASE:-$(echo $VERSION | awk '{print $1}')}
RELEASE=${RELEASE:-$(echo $PRETTY_NAME | awk '{print $2}')}
RELEASE=${RELEASE:-${DISTRIB_RELEASE}}
RELEASE=${RELEASE:-${VERSION_ID}}
# RELEASE=$(echo "$RELEASE" | awk -F. '{print $1"."$2}')
RELEASE=$(echo "$RELEASE" | cut -d. -f1-2)
RELEASE=$(echo "$RELEASE" | tr '[:upper:]' '[:lower:]')
RELEASE=${RELEASE//[[:space:]]/}
RELEASE=${RELEASE%.}

DISTRIB=${DISTRIB:-$DISTRIB_ID}
DISTRIB=${DISTRIB:-$ID}
DISTRIB=$(echo "$DISTRIB" | tr '[:upper:]' '[:lower:]')

env CODENAME $CODENAME
env RELEASE $RELEASE
env DISTRIB $DISTRIB
end_group

cd $source_dir

start_group "Install Build Dependencies"
APT_CONF_FILE=/etc/apt/apt.conf.d/50build-deb-action

cat | $SUDO tee "$APT_CONF_FILE" <<-EOF
APT::Get::Assume-Yes "yes";
APT::Install-Recommends "no";
Acquire::Languages "none";
quiet "yes";
EOF

# debconf has priority “required” and is indirectly depended on by some
# essential packages. It is reasonably safe to blindly assume it is installed.
printf "man-db man-db/auto-update boolean false\n" | $SUDO debconf-set-selections

$SUDO apt update
$SUDO apt-get install -y build-essential debhelper fakeroot gnupg reprepro wget curl git sudo vim locales lsb-release
$SUDO apt-get -y install lsb-release ca-certificates curl

[[ ! -f /usr/share/keyrings/microsoft-prod.gpg ]] && {
    [[ ! -f /etc/apt/trusted.gpg.d/microsoft.asc ]] && {
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
            $SUDO tee /etc/apt/trusted.gpg.d/microsoft.asc >/dev/null ||
            echo "Failed to download Microsoft key to /etc/apt/trusted.gpg.d/microsoft.asc"
    }

    [[ -f /etc/apt/trusted.gpg.d/microsoft.asc ]] && {
        cat /etc/apt/trusted.gpg.d/microsoft.asc |
            $SUDO gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg ||
            echo "Failed to dearmor key from /etc/apt/trusted.gpg.d/microsoft.asc"
    } || {
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
            $SUDO gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg ||
            echo "Failed to download and dearmor Microsoft key to /usr/share/keyrings/microsoft-prod.gpg"
    }
}

[[ ! -f /etc/apt/sources.list.d/prod.list ]] &&
    ! grep -q 'https://packages.microsoft.com' /etc/apt/sources.list /etc/apt/sources.list.d/* &&
    echo https://packages.microsoft.com/config/$DISTRIB/$RELEASE/prod.list &&
    curl -fsSL https://packages.microsoft.com/config/$DISTRIB/$RELEASE/prod.list |
    $SUDO tee /etc/apt/sources.list.d/prod.list >/dev/null

# add repository for install missing depends
if [[ $DISTRIB == "ubuntu" ]]; then
    $SUDO apt install software-properties-common
    $SUDO add-apt-repository ppa:ondrej/php -y
elif [[ $DISTRIB == "debian" ]]; then
    ${SUDO} curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    ${SUDO} dpkg -i /tmp/debsuryorg-archive-keyring.deb
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $CODENAME main" |
        $SUDO tee /etc/apt/sources.list.d/php.list >/dev/null
fi

$SUDO apt update || true
# In theory, explicitly installing dpkg-dev would not be necessary. `apt-get
# build-dep` will *always* install build-essential which depends on dpkg-dev.
# But let’s be explicit here.
# shellcheck disable=SC2086
$SUDO apt install -y debhelper-compat dpkg-dev libdpkg-perl dput tree devscripts libdistro-info-perl
$SUDO apt install -y unixodbc-dev php-pear
$SUDO apt install -y dh-php php-all-dev
$SUDO apt install $INPUT_APT_OPTS -- $INPUT_EXTRA_BUILD_DEPS

# shellcheck disable=SC2086
cat $controlin | tee $control
$SUDO apt build-dep $INPUT_APT_OPTS -- "$source_dir" || true
end_group

start_group "GPG/SSH Configuration"
if ! gpg --list-keys --with-colons | grep -q "fpr"; then
    echo "$GPG_KEY====" | tr -d '\n' | fold -w 4 | sed '$ d' | tr -d '\n' | fold -w 76 | base64 -di | gpg --batch --import || true
fi

#!/bin/bash

# Lấy danh sách tất cả GPG key IDs
KEYS=$(gpg --list-secret-keys --keyid-format=long | awk '/sec/{print $2}' | cut -d'/' -f2)

# Lặp qua từng key và chỉnh sửa
for KEY in $KEYS; do
    # Cập nhật expiration date của subkey
    gpg --batch --command-fd 0 --edit-key "$KEY" <<EOF
key 1
expire
0
save
EOF

    # Cập nhật expiration date của key chính
    gpg --batch --command-fd 0 --edit-key "$KEY" <<EOF
expire
0
save
EOF

    # Đặt key thành Ultimate Trust
    gpg --batch --command-fd 0 --edit-key "$KEY" <<EOF
trust
5
save
EOF
done

if gpg --list-secret-keys --keyid-format=long | grep -q "sec"; then
    export DEB_SIGN_KEYID=$(gpg --list-keys --with-colons --fingerprint | awk -F: '/fpr:/ {print $10; exit}')
fi
gpg --list-secret-keys --keyid-format=long
end_group

start_group "extract package source"

# Doc module-specific source config
if [[ -f "$debian_dir/$module/source" ]]; then
    source "$debian_dir/$module/source"
fi

if [[ -n "$SOURCE_URL" ]]; then
    # Extract owner/repo from SOURCE_URL (e.g., https://github.com/diepxuan/runkit7.git)
    _repo_path=$(echo "$SOURCE_URL" | sed 's|https://github.com/||;s|\.git$||')
    _repo_owner=$(echo "$_repo_path" | cut -d '/' -f1)
    _repo_project=$(echo "$_repo_path" | cut -d '/' -f2)

    # Get latest release version (similar to pecl search)
    stability=$(curl -s "https://api.github.com/repos/${_repo_owner}/${_repo_project}/releases/latest" | grep -o '"tag_name": *"[^"]*"' | cut -d '"' -f4)

    # Download release tarball (similar to pecl download)
    package_dist="${_repo_project}-${stability}.tgz"
    curl -sL "https://github.com/${_repo_owner}/${_repo_project}/releases/download/${stability}/${package_dist}" -o "$source_dir/${package_dist}"

    # Extract tarball
    tar xvzf "$source_dir/${package_dist}" -C "$source_dir"

    # Read changelog notes
    package_clog=$(php -r "echo simplexml_load_file('$source_dir/package.xml')->notes;" 2>/dev/null)
else
    stability=$(pecl search $module 2>/dev/null | grep ^$module | awk '{print $3}' | sed 's|[()]||g')
    pecl download $module-$stability
    package_dist=$(ls | grep $module)
    tar xvzf $package_dist -C $source_dir
    package_clog=$(php -r "echo simplexml_load_file('$source_dir/package.xml')->notes;" 2>/dev/null)
fi
end_group

start_group "view source"
echo $source_dir
ls -la $source_dir
echo $debian_dir
ls -la $debian_dir
end_group

_project=$(echo $project | sed 's|_|-|g')

start_group update control file
[[ -f $(realpath $debian_dir/$module/control.in) ]] &&
    cat $(realpath $debian_dir/$module/control.in) | tee $controlin
sed -i -e "s|_PROJECT_|$_project|g" $controlin
sed -i -e "s|_MODULE_|$module|g" $controlin
cat $controlin | tee $control
end_group

start_group create build files
cat | tee "$debian_dir/$module.ini" <<-EOF
; configuration for pecl $module module
; priority=20
extension=$module.so
EOF
cat | tee "$debian_dir/$_project.php" <<-EOF
mod debian/$module.ini
EOF
[[ -f "$debian_dir/$module/rules" ]] && cat "$debian_dir/$module/rules" >>"$rules"
[[ -f "$debian_dir/$module/php.ini" ]] && cat "$debian_dir/$module/php.ini" >>"$debian_dir/$module.ini"
[[ -f "$build_dir/$module.config.m4" ]] &&
    cat "$build_dir/$module.config.m4" |
    tee -a "$source_dir/${package_dist%.tgz}/config.m4"
end_group

start_group Update Package Configuration in Changelog
release_tag=$(echo ${package_dist%.tgz} | cut -d '-' -f2)
# release_tag="$release_tag+$DISTRIB~$RELEASE"
# old_project=$(cat $changelog | head -n 1 | awk '{print $1}' | sed 's|[()]||g')
# old_release_tag=$(cat $changelog | head -n 1 | awk '{print $2}' | sed 's|[()]||g')
# old_codename_os=$(cat $changelog | head -n 1 | awk '{print $3}' | sed 's|;||g')

# sed -i -e "s|$old_project|$_project|g" $changelog
# sed -i -e "s|$old_release_tag|$release_tag|g" $changelog
# sed -i -e "s|$old_codename_os|$CODENAME|g" $changelog
# sed -i -e "s|<$email>  .*|<$email>  $timelog|g" $changelog
# dch -a $package_clog -m
dch --package $_project --newversion $release_tag+$DISTRIB~$RELEASE --distribution $CODENAME "$package_clog"
end_group

rm -rf "$control-e"
rm -rf "$controlin-e"
rm -rf "$changelog-e"

start_group Show log
echo $control
cat $control || true
echo $controlin
cat $controlin || true
echo $rules
cat $rules || true
end_group

start_group Show changelog
cat $changelog
end_group

start_group Show package changelog
echo $package_clog
end_group

start_group log GPG key before build
gpg --list-secret-keys --keyid-format=long
end_group

start_group Building package binary
dpkg-parsechangelog
# shellcheck disable=SC2086
dpkg-buildpackage --force-sign || dpkg-buildpackage --force-sign -d
# shellcheck disable=SC2086
dpkg-buildpackage --force-sign -S || dpkg-buildpackage --force-sign -S -d
end_group

start_group Move build artifacts
regex='^php.*(.deb|.ddeb|.buildinfo|.changes|.dsc|.tar.xz|.tar.gz|.tar.[[:alpha:]]+)$'
regex='.*(.deb|.ddeb|.buildinfo|.changes|.dsc|.tar.xz|.tar.gz|.tar.[[:alpha:]]+)$'
mkdir -p $dists_dir
while read -r file; do
    mv -vf "$source_dir/$file" "$dists_dir/" || true
done < <(ls $source_dir/ | grep -E $regex)

while read -r file; do
    mv -vf "$pwd_dir/$file" "$dists_dir/" || true
done < <(ls $pwd_dir/ | grep -E $regex)

ls -la $dists_dir
end_group

start_group Publish Package to Launchpad
cat | tee ~/.dput.cf <<-EOF
[caothu91ppa]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~caothu91/ubuntu/ppa/
login = anonymous
allow_unsigned_uploads = 0
EOF

# package=$(ls -a $dists_dir | grep _source.changes | head -n 1)

# [[ -n $package ]] &&
#     package=$dists_dir/$package &&
#     [[ -f $package ]] &&
#     dput caothu91ppa $package || true
while read -r package; do
    dput caothu91ppa $dists_dir/$package || true
done < <(ls $dists_dir | grep -E '.*(_source.changes)$')
end_group
