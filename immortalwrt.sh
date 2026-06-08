#!/bin/bash
set -e

REPO_DIR=$(pwd)
CCACHE_DIR="${CCACHE_DIR}"

sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
python3-setuptools rsync swig unzip zlib1g-dev file wget ccache tree

git clone https://github.com/immortalwrt/immortalwrt.git
cd immortalwrt

git checkout v25.12.0

git config --global user.email "ci@build.local"
git config --global user.name "CI Builder"

# Fetch the PR
git fetch https://github.com/openwrt/openwrt.git pull/23510/head:pr-23510

# Get only Jio-related commits and cherry-pick them dynamically
git log pr-23510 --oneline --grep="jio\|jidu" --regexp-ignore-case --format="%H"| tac | \
  grep -v $(git log --format="%H" | head -100 | tr '\n' '\|' | sed 's/|$//') | \
  xargs git cherry-pick -X theirs

./scripts/feeds update -a
./scripts/feeds install -a

# Copy config and inject ccache dir dynamically
cp $REPO_DIR/${DEVICE_CONFIG} .config

sed -i '/CONFIG_CCACHE_DIR/d' .config
echo "CONFIG_CCACHE_DIR=\"${CCACHE_DIR}\"" >> .config

echo "ccache dir set to: ${CCACHE_DIR}"

make defconfig

# Verify after defconfig
echo "=== CCACHE config in .config ==="
grep "CCACHE" .config

echo "=== CCACHE_DIR env ==="
echo $CCACHE_DIR

echo "=== Cache dir contents BEFORE build ==="
ls -la ${CCACHE_DIR} 2>/dev/null || echo "Cache dir is EMPTY or does not exist"

# Configure ccache properly (OpenWrt official approach)
CCACHE_CONF="staging_dir/host/etc/ccache.conf"
mkdir -p staging_dir/host/etc
touch $CCACHE_CONF

echo "compiler_type=gcc" >> $CCACHE_CONF
echo "depend_mode=true" >> $CCACHE_CONF
echo "sloppiness=file_macro,locale,time_macros,include_file_ctime,include_file_mtime" >> $CCACHE_CONF

make -j$(nproc)

echo "Build completed successfully! Artifacts are located in bin/targets/mediatek/filogic/"
