#!/bin/sh
# Run as root inside the cerberus LXC, from this directory.
set -eu

GO2RTC_VERSION=1.9.9

apt-get update
apt-get install -y --no-install-recommends cage chromium fonts-dejavu-core ca-certificates curl

curl -fsSL -o /usr/local/bin/go2rtc \
  "https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/go2rtc_linux_amd64"
chmod 755 /usr/local/bin/go2rtc

id kiosk >/dev/null 2>&1 || useradd --system --create-home --groups video,render kiosk

install -d -m 755 /etc/cerberus
install -m 644 go2rtc.yaml /etc/cerberus/go2rtc.yaml
install -m 600 .env /etc/cerberus/env
install -m 644 go2rtc.service kiosk.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now go2rtc.service kiosk.service
