# system

Always-on tier, pinned to the Apollo worker.

## couchdb — Obsidian LiveSync backend

Sync hub for Obsidian across desktop and iOS. **It is not the vault.** The
vault is the folder of markdown on each device; CouchDB holds a replica that
keeps them converged. If it is lost, re-seed it from a device — which is why
its `local-path` PVC being unbacked is acceptable, unlike a real data store.

Exposed on the **external** Gateway (`couchdb.bgalhardo.com`) so the phone
syncs away from home. Enable LiveSync's End-to-End Encryption: the server
then stores only ciphertext.

### Why it runs as 5984 and not root

The image runs as root by default and its entrypoint does
`find /opt/couchdb \! \( -user couchdb -group couchdb \) -exec chown -f ...`.
Kubernetes mounts ConfigMap volumes **read-only**, so that chown fails on the
mounted `local.ini`. `-f` suppresses the error *message* but not the exit
status, and the script runs under `set -e` — so the container exits 1 having
printed **nothing at all**, on stdout or stderr.

Running as 5984 skips the entire root-only block. Verified by reproducing it
with docker on athena: identical config exits 1 silently with `:ro`, exits 0
with `:rw`, and exits 0 with `:ro` plus `--user 5984:5984`.

### Before first use

```sh
vault kv put kv/apps/couchdb username=admin password="$(openssl rand -base64 24)"
```

Then create the system databases once (CouchDB 3 does not do this itself):

```sh
kubectl -n system exec deploy/couchdb -- \
  curl -s -XPUT http://$USER:$PASS@127.0.0.1:5984/{_users,_replicator}
```

### Desktop client

1. Community plugins → **Self-hosted LiveSync** → install, enable
2. Setup wizard → remote type **CouchDB**
   - URI `https://couchdb.bgalhardo.com`
   - Username / password from `kv/apps/couchdb`
   - Database name e.g. `obsidian`
3. Set an **E2E passphrase** and keep it — it is not recoverable
4. `Check database configuration` → fix anything it flags
5. First device: **Copy setup URI** (the plugin generates one)

### iOS client

Install Obsidian from the App Store, create an empty vault, install the same
plugin, then **Open setup URI** and paste the URI from the desktop. That
carries the endpoint, credentials and passphrase across — do not retype them.

The `[cors] origins` in the ConfigMap already lists `capacitor://localhost`
(iOS) and `app://obsidian.md` (desktop); without those the clients fail to
connect with an opaque CORS error.

## Git, alongside LiveSync

LiveSync keeps devices converged. Git provides history and backup — they are
different jobs and do not conflict, because git only ever sees the files
LiveSync has already written to disk.

**Commit from the PC.** It is the only device with a real filesystem and git;
do not try to git from the phone. The vault folder on the PC is an ordinary
repo — `git add`/`commit`/`push`, or the Obsidian Git plugin on desktop only
for periodic auto-commits.

**`.gitignore` is not optional here:**

```
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/plugins/obsidian-livesync/data.json
.trash/
```

That third line matters most: LiveSync stores the CouchDB URI, credentials
and the E2E passphrase in `data.json`. Committing it publishes them.
