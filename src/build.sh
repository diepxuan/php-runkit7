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
    param=$1
    value="${@:2}"
    grep -q "^$param=" $GITHUB_ENV &&
        sed -i "s|^$param=.*|$param=$value|" $GITHUB_ENV ||
        echo "$param=$value" >>$GITHUB_ENV
    export $param="$value"
    echo $param: $value
}

start_group "Dynamically set environment variable"
env source_dir $(dirname $(realpath "$BASH_SOURCE"))
env debian_dir $(realpath $source_dir/debian)
env dists_dir $(realpath $source_dir/dists)

# user evironment
env email ductn@diepxuan.com
env DEBEMAIL ductn@diepxuan.com
env EMAIL ductn@diepxuan.com
env DEBFULLNAME Tran Ngoc Duc
env NAME Tran Ngoc Duc

# debian
env changelog $(realpath $debian_dir/changelog)
env control $(realpath $debian_dir/control)
env controlin $(realpath $debian_dir/control.in)
env rules $(realpath $debian_dir/rules)
env timelog "$(Lang=C date -R)"

# plugin
env repository $repository
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
DISTRIB=$(echo "$DISTRIB" | awk '{print tolower($0)}')

env CODENAME $CODENAME
env RELEASE $RELEASE
env DISTRIB $DISTRIB
end_group

start_group "add apt source"
APT_CONF_FILE=/etc/apt/apt.conf.d/50build-deb-action

cat | sudo tee "$APT_CONF_FILE" <<-EOF
APT::Get::Assume-Yes "yes";
APT::Install-Recommends "no";
Acquire::Languages "none";
quiet "yes";
EOF

# debconf has priority “required” and is indirectly depended on by some
# essential packages. It is reasonably safe to blindly assume it is installed.
printf "man-db man-db/auto-update boolean false\n" | sudo debconf-set-selections

# curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
# curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list

# add repository for install missing depends
sudo apt install software-properties-common
# sudo add-apt-repository ppa:ondrej/php -y
end_group

start_group "Install Build Dependencies"
sudo apt update
# shellcheck disable=SC2086
cat $controlin | tee $control
sudo apt build-dep $INPUT_APT_OPTS -- "$source_dir"

# In theory, explicitly installing dpkg-dev would not be necessary. `apt-get
# build-dep` will *always* install build-essential which depends on dpkg-dev.
# But let’s be explicit here.
# shellcheck disable=SC2086
sudo apt install $INPUT_APT_OPTS -- dpkg-dev unixodbc-dev libdpkg-perl dput devscripts $INPUT_EXTRA_BUILD_DEPS
end_group

start_group "extract package source"
stability=$(pecl search $module 2>/dev/null | grep ^$module | awk '{print $3}' | sed 's|[()]||g')
pecl download $module-$stability
# pecl download runkit7-alpha
package_dist=$(ls | grep $module)
tar xvzf $package_dist -C $source_dir
package_clog=$(php -r "echo simplexml_load_file('$source_dir/package.xml')->notes;" 2>/dev/null)
end_group

start_group "view source"
echo $source_dir
ls -la $source_dir
echo $debian_dir
ls -la $debian_dir
end_group

_project=$(echo $project | sed 's|_|-|g')

start_group "update control"
sed -i -e "s|_PROJECT_|$_project|g" $controlin
sed -i -e "s|_MODULE_|$module|g" $controlin
cat $controlin | tee $control
end_group

start_group "create php config files"
cat | tee "$debian_dir/$module.ini" <<-EOF
; configuration for pecl $module module
; priority=20
extension=$module.so
EOF
cat | tee "$debian_dir/$_project.php" <<-EOF
mod debian/$module.ini
EOF
[[ -f "$debian_dir/$module.rules" ]] && cat "$debian_dir/$module.rules" >>"$rules"
[[ -f "$debian_dir/extend.$module.ini" ]] && cat "$debian_dir/extend.$module.ini" >>"$debian_dir/$module.ini"
end_group

start_group "update package config"
cd $source_dir
release_tag=$(echo $package_dist | sed 's|.tgz||g' | cut -d '-' -f2)
release_tag="$release_tag+$DISTRIB~$RELEASE"
old_project=$(cat $changelog | head -n 1 | awk '{print $1}' | sed 's|[()]||g')
old_release_tag=$(cat $changelog | head -n 1 | awk '{print $2}' | sed 's|[()]||g')
old_codename_os=$(cat $changelog | head -n 1 | awk '{print $3}' | sed 's|;||g')

sed -i -e "s|$old_project|$_project|g" $changelog
sed -i -e "s|$old_release_tag|$release_tag|g" $changelog
sed -i -e "s|$old_codename_os|$CODENAME|g" $changelog
sed -i -e "s|<$email>  .*|<$email>  $timelog|g" $changelog
dch -a $package_clog -m
cd -
end_group

rm -rf "$control-e"
rm -rf "$controlin-e"
rm -rf "$changelog-e"

start_group log
echo $control
cat $control
echo $controlin
cat $controlin
echo $rules
cat $rules
end_group

start_group changelog
cat $changelog
end_group

start_group "log package changelog"
echo $package_clog
end_group

start_group Building package binary
dpkg-buildpackage --force-sign
end_group

start_group Building package source
dpkg-buildpackage --force-sign -S
end_group

start_group "Move build artifacts"
regex='^php.*(.deb|.ddeb|.buildinfo|.changes|.dsc|.tar.xz|.tar.gz|.tar.[[:alpha:]]+)$'
mkdir -p $dists_dir
while read -r file; do
    mv -vf "$source_dir/$file" "$dists_dir/" || true
done < <(ls $source_dir/ | grep -E $regex)

while read -r file; do
    mv -vf "$pwd_dir/$file" "$dists_dir/" || true
done < <(ls $pwd_dir/ | grep -E $regex)

ls -la $dists_dir
end_group

start_group "Publish Package to Launchpad"
cat | tee ~/.dput.cf <<-EOF
[caothu91ppa]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~caothu91/ubuntu/ppa/
login = anonymous
allow_unsigned_uploads = 0
EOF

package=$(ls -a $dists_dir | grep _source.changes | head -n 1)

[[ -n $package ]] &&
    package=$dists_dir/$package &&
    [[ -f $package ]] &&
    dput caothu91ppa $package || true
end_group

start_group "Publish package to Personal Package archives"
git clone --depth=1 --branch=main git@github.com:diepxuan/ppa.git

rm -rf ppa/src/$repository
mkdir -p ppa/src/$repository/
cp -r $source_dir/. ppa/src/$repository/

cd ppa
if [ -n "$(git status --porcelain=v1 2>/dev/null)" ]; then
    git add src/
    git commit -m "${GIT_COMMITTER_MESSAGE:-'Auto-commit'}"
    if ! git push; then
        git stash
        git pull --rebase
        git stash pop
        git push || true
    fi
fi
end_group
