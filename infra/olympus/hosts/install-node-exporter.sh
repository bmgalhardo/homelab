#!/bin/sh
set -eu

version=1.12.1
sha256=b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63
archive="node_exporter-${version}.linux-amd64.tar.gz"
destination="/usr/local/lib/node_exporter/${version}"

[ "$(id -u)" -eq 0 ]
[ "$(uname -m)" = x86_64 ]
systemctl cat prometheus-node-exporter.service >/dev/null

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
  "https://github.com/prometheus/node_exporter/releases/download/v${version}/${archive}" \
  -o "$workdir/$archive"
printf '%s  %s\n' "$sha256" "$workdir/$archive" | sha256sum -c -
tar -xzf "$workdir/$archive" -C "$workdir"
install -d "$destination"
install -m 0755 "$workdir/node_exporter-${version}.linux-amd64/node_exporter" \
  "$destination/node_exporter"
"$destination/node_exporter" --version

install -d /etc/systemd/system/prometheus-node-exporter.service.d
cat > /etc/systemd/system/prometheus-node-exporter.service.d/binary.conf <<EOF
[Service]
ExecStart=
ExecStart=$destination/node_exporter \$ARGS
EOF
systemctl daemon-reload
systemctl restart prometheus-node-exporter.service
systemctl is-active prometheus-node-exporter.service
