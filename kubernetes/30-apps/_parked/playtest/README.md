# playtest (parked)

The public host where friends play the Godot prototypes and send playtest
telemetry: `play.bgalhardo.com` on the `external` Gateway. Parked until the
games are ready for outside players. The internal push route it builds on
is live: `system/telemetry.yaml`.

## Before unparking

- **Rate limit the push.** The endpoint is open to the internet and writes
  to Loki. The body cap (`ClientSettingsPolicy`, 1m) is not enough on its
  own. Check what NGF (v2.7) offers for rate limiting. If it has nothing,
  consider a per-friend key in each player link, checked by a header match
  on the push rule.
- **Loki's ingestion limits** on athena (`infra/athena/loki/config.yml`:
  8 MB/s, 16 MB burst) are shared with every homelab log. Junk pushed at
  that rate would crowd them out.
- **Reachability.** Port 443 on the WAN must reach `192.168.1.201`, as it
  does for `home.bgalhardo.com`. external-dns publishes the hostname from
  the route.

## Unpark

1. Move `play-route.yaml` to `kubernetes/30-apps/system/`.
2. Add it to `system/kustomization.yaml`.
3. Add each new game's two `GET`/`HEAD` matches.
