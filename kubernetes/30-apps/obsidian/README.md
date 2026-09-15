# obsidian

Obsidian served in the browser (`lscr.io/linuxserver/obsidian` — the desktop
app over KasmVNC), at `https://obsidian.bgalhardo.internal`.

## Placement and storage

| | choice | why |
|---|---|---|
| node | **apollo** | notes must stay reachable when hades is asleep |
| vault | **local-path**, `/config/vault` | virtiofs exists only on elysium-hades |

## ⚠️ There is no backup yet

**The vault is on local-path: a plain node-local directory with no
replication. If the Apollo node is lost, the notes are lost.** Nothing in
this directory backs them up today — deliberately deferred to get the app
deployed; see the backup item in `.claude/context/todos.md`.

Until that lands, keep your own copy of anything you cannot lose (Obsidian
Sync, or clone the vault out periodically).

The design that was worked out and deferred: a git-push CronJob. Git rather
than a copy to hades because virtiofs volumes mount on **elysium-hades only**
and a local-path PVC can only be mounted from the node holding it — no single
pod can mount both, so an Apollo→hades file copy is impossible in-cluster. The
backup has to leave the node over the network, and for markdown git also buys
per-change history. Full reasoning in todos.md.

## Restore (once backups exist)

```sh
kubectl -n obsidian scale deploy/obsidian --replicas=0
# restore the vault into the PVC, then
kubectl -n obsidian scale deploy/obsidian --replicas=1
```
Obsidian reopens the vault in place; there is no import step.

## Container notes — each of these costs an evening if missed

- **`seccompProfile: Unconfined`** — Obsidian is Electron and will not start
  under the default seccomp profile.
- **`/dev/shm` is a 1Gi memory emptyDir** — the 64Mi default makes the
  Chromium renderer crash on larger vaults.
- **`strategy: Recreate`** — the PVC is RWO and local-path pins it to one
  node, so a rolling update would deadlock waiting for the volume.

## If you want native clients instead

This runs the Obsidian *app* on the server. If you would rather keep Obsidian
on a laptop/phone and sync between them, that is **Obsidian LiveSync** (a
CouchDB backend) — a different deployment. The two can coexist; the vault here
is just a directory.
