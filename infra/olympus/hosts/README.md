# Proxmox hosts — apollo, hades

Host-level agents on the Proxmox nodes themselves (not VMs). Debian 13 / PVE 9.

| Agent | Port | Ships to |
|-------|------|----------|
| `prometheus-node-exporter` (Debian package) | 9100 | scraped by Prometheus on athena |
| `alloy` (apt.grafana.com) | 127.0.0.1:12345 | journald → Loki on athena |

| repo | on host |
|------|---------|
| `config.alloy` | `/etc/alloy/config.alloy` |
| `alloy-limits.conf` | `/etc/systemd/system/alloy.service.d/limits.conf` |
| `cpu-governor.service` | `/etc/systemd/system/cpu-governor.service` (apollo) |

## Install

```sh
H=apollo   # or hades
ssh $H '
  apt-get install -y prometheus-node-exporter gpg &&
  mkdir -p /etc/apt/keyrings &&
  wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg &&
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list &&
  apt-get update -o Dir::Etc::sourcelist=sources.list.d/grafana.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0;
  apt-get install -y alloy &&
  usermod -aG systemd-journal alloy &&
  mkdir -p /etc/systemd/system/alloy.service.d
'
scp infra/olympus/hosts/config.alloy      $H:/etc/alloy/config.alloy
scp infra/olympus/hosts/alloy-limits.conf $H:/etc/systemd/system/alloy.service.d/limits.conf
ssh $H "grep -q ^HOSTNAME= /etc/default/alloy || echo HOSTNAME=$H >> /etc/default/alloy &&
  alloy validate /etc/alloy/config.alloy &&
  systemctl daemon-reload && systemctl enable --now alloy && systemctl restart alloy"
```

Then add `<ip>:9100` to the `node` job in `infra/athena/prometheus/prometheus.yml`.

## CPU governor (apollo)

```sh
scp infra/olympus/hosts/cpu-governor.service apollo:/etc/systemd/system/
ssh apollo 'systemctl daemon-reload && systemctl enable --now cpu-governor &&
  cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
```

Anything else that sets the governor at boot wins over this unit:
`crontab -l` (`@reboot ... performance`), `/etc/default/cpufrequtils`.
