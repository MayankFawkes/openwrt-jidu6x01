#!/bin/bash
set -e

REPO_DIR=$(pwd)
CCACHE_DIR="${CCACHE_DIR}"

sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
python3-setuptools rsync swig unzip zlib1g-dev file wget ccache tree

git clone https://github.com/openwrt/openwrt.git
cd openwrt

git checkout v25.12.4

git config --global user.email "ci@build.local"
git config --global user.name "CI Builder"

# Fetch the PR
git fetch origin pull/23510/head:pr-23510 --force

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
make -j$(nproc)

echo "Build completed successfully! Artifacts are located in bin/targets/mediatek/filogic/"