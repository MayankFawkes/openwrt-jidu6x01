#!/bin/bash
set -e

REPO_DIR=$(pwd)

sudo apt update
sudo apt install -y build-essential clang flex bison g++ gawk \
gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev \
python3-setuptools rsync swig unzip zlib1g-dev file wget ccache tree

git clone https://github.com/immortalwrt/immortalwrt.git
cd immortalwrt

git checkout v25.12.2

# Backport all three commits from OpenWrt PR #23510 to this release.
# The upstream commits conflict with ImmortalWrt's U-Boot configuration and
# DEVICE_PACKAGES, so use a rebased patch that preserves its automount package.
JIO_PATCH="$REPO_DIR/patches/immortalwrt-25.12.2-jiorouter.patch"
if git apply --reverse --check "$JIO_PATCH" 2>/dev/null; then
  echo "JioRouter backport already applied, skipping"
else
  git apply --check "$JIO_PATCH"
  git apply "$JIO_PATCH"
fi

echo "==============================adding initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01=============================="
# Add initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01
FILOGIC_MK="target/linux/mediatek/image/filogic.mk"

for DEV in jiorouter_ax6000-jidu6101 jiorouter_ax6000-jidu6j01; do
  if ! grep -Fxq "define Device/$DEV" "$FILOGIC_MK"; then
    echo "ERROR: missing device definition for $DEV" >&2
    exit 1
  fi

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

  if ! awk "/^define Device\/${DEV}\$/,/^endef/" "$FILOGIC_MK" | grep -q "ARTIFACT/initramfs-factory.ubi"; then
    echo "ERROR: failed to add initramfs-factory.ubi for $DEV" >&2
    exit 1
  fi
done
echo "==============================finished adding initramfs-factory.ubi artifact to JIDU6101 and JIDU6J01=============================="

cat <<-EOF >> feeds.conf.default
src-git --root=feeds fantastic_packages https://github.com/fantastic-packages/packages.git;master
EOF

./scripts/feeds update -a
./scripts/feeds install -a

# Copy config and inject ccache dir dynamically
cp $REPO_DIR/${DEVICE_CONFIG} .config

make defconfig

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

make -j$(nproc)

echo "Build completed successfully! Artifacts are located in bin/targets/mediatek/filogic/"
