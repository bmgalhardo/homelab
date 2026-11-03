#!/bin/sh
# Run on hades. apollo:/mnt/immich is the live Immich library.
#   pull  apollo immich/, immich-cache/  -> /odin/photos/   (apollo is the source)
#   push  /odin/photos/archive_public/   -> apollo          (hades is the source)
set -eu

APOLLO=photos-backup@192.168.1.197
ODIN=/odin/photos
KEYS=/etc/photos-mirror
ssh_with() { echo "ssh -i $KEYS/$1 -o UserKnownHostsFile=$KEYS/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes"; }
PULL=$(ssh_with pull)
PUSH=$(ssh_with push)
RSYNC="rsync -aHAX --numeric-ids --delete --max-delete=500"

rsync -e "$PULL" --list-only $APOLLO:immich/upload/ >/dev/null 2>&1 ||
  { echo "apollo unreachable or library not mounted, skipping"; exit 0; }

$RSYNC -e "$PULL" $APOLLO:immich/ $ODIN/immich/
$RSYNC -e "$PULL" $APOLLO:immich-cache/ $ODIN/immich-cache/
$RSYNC -e "$PUSH" --no-owner --no-group $ODIN/archive_public/ $APOLLO:/
echo "photos mirror ok"
