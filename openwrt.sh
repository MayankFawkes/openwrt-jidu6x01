#!/bin/bash
set -e

REPO_DIR=$(pwd)

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


echo "==============================adding initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01=============================="
# Add initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"

for DEV in jiorouter_ax6000-jidu6101 jiorouter_ax6000-jidu6j01; do
  # Skip if this device already has the artifact (idempotent)
  if awk "/^define Device\/${DEV}\$/,/^endef/" "$FILOGIC_MK" | grep -q "initramfs-factory.ubi"; then
    echo "[$DEV] initramfs-factory.ubi already present, skipping"
    continue
  fi

  echo "[$DEV] adding initramfs-factory.ubi artifact"

  # Insert the artifact block before the sysupgrade line, but ONLY inside this device's block
  awk -v dev="$DEV" '
    $0 == "define Device/" dev { indev=1 }
    indev && /^  IMAGE\/sysupgrade\.bin := sysupgrade-tar \| append-metadata$/ {
      print "ifeq ($(IB),)"
      print "ifneq ($(CONFIG_TARGET_ROOTFS_INITRAMFS),)"
      print "  ARTIFACTS := initramfs-factory.ubi"
      print "  ARTIFACT/initramfs-factory.ubi := append-image-stage initramfs-kernel.bin | ubinize-kernel"
      print "endif"
      print "endif"
      indev=0
    }
    { print }
  ' "$FILOGIC_MK" > "${FILOGIC_MK}.tmp" && mv "${FILOGIC_MK}.tmp" "$FILOGIC_MK"
done
echo "==============================finished adding initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01=============================="

echo "==============================adding fantastic package feeds=============================="
# --- Add fantastic-packages runtime feed (baked into firmware) ---
VER="25.12"
ARCH="aarch64_cortex-a53"
KEYID="20241123170031"   # from the grep above, WITHOUT the .pub extension

mkdir -p files/etc/apk/repositories.d
mkdir -p files/etc/apk/keys

# Correct feed URLs (github.io, not openwrt.org)
cat > files/etc/apk/repositories.d/customfeeds.list <<EOF
https://fantastic-packages.github.io/releases/${VER}/packages/${ARCH}/luci/packages.adb
https://fantastic-packages.github.io/releases/${VER}/packages/${ARCH}/packages/packages.adb
https://fantastic-packages.github.io/releases/${VER}/packages/${ARCH}/special/packages.adb
EOF

# Public key so apk trusts the feed (no --allow-untrusted needed)
curl -sSL -o "files/etc/apk/keys/${KEYID}.pem" \
  "https://fantastic-packages.github.io/releases/${VER}/${KEYID}.pub"

# Fail loudly if the key didn't download — don't ship a feed with no key
if [ ! -s "files/etc/apk/keys/${KEYID}.pem" ]; then
  echo "ERROR: fantastic-packages key download failed or empty"
  exit 1
fi
echo "Successfully added fantastic-packages feed with key ${KEYID}.pem"
echo "==============================finished adding fantastic package feeds=============================="


./scripts/feeds update -a
./scripts/feeds install -a

# Copy config and inject ccache dir dynamically
cp $REPO_DIR/${DEVICE_CONFIG} .config

make defconfig

make -j$(nproc)

echo "Build completed successfully! Artifacts are located in bin/targets/mediatek/filogic/"