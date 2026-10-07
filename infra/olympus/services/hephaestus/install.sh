#!/bin/sh
# Run as root inside the hephaestus LXC, from this directory.
set -eu

BLENDER_VERSION=4.5.14
SERIES=${BLENDER_VERSION%.*}
NAME=blender-${BLENDER_VERSION}-linux-x64
BASE=https://download.blender.org/release/Blender${SERIES}

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xz-utils rsync \
  libx11-6 libxext6 libxi6 libxxf86vm1 libxfixes3 libxrender1 libxkbcommon0 \
  libsm6 libgl1 libegl1

if [ ! -x /opt/${NAME}/blender ]; then
  cd /tmp
  curl -fsSLO ${BASE}/${NAME}.tar.xz
  curl -fsSL ${BASE}/blender-${BLENDER_VERSION}.sha256 | grep " ${NAME}.tar.xz\$" | sha256sum -c -
  tar -C /opt -xf ${NAME}.tar.xz
  rm ${NAME}.tar.xz
fi
ln -sfn /opt/${NAME}/blender /usr/local/bin/blender

install -d /root/work /root/out
/usr/local/bin/blender -b --version | head -1
