# Applying Container-Optimized OS updates

Two different problems, with two different mechanisms.

| | Mechanism | Covered by |
|---|---|---|
| Patches within your current milestone | staged update + reboot | the timer, below |
| Moving to a newer milestone | rebuild the instance | `upgrade-cos.sh` |

A milestone that has stopped shipping builds needs the second one. The timer
will run correctly and find nothing, indefinitely.

## Where the configuration lives

On Container-Optimized OS, `/etc` is a tmpfs overlay. Files written to
`/etc/systemd/system` work until the first reboot and then disappear. So does
`/etc/fstab`. `/home` and `/var` persist but are mounted `noexec`, so a binary
placed there cannot run either.

Google's documented mechanism is **cloud-init**, supplied through the
instance's `user-data` metadata and reapplied on every boot. Everything this
directory configures, the reboot timer and the vault data disk mount, is
declared there.

`lib-bwgc-cloudinit.sh` generates that cloud-config. The other scripts source
it, so there is one definition rather than several that drift.

## Keeping the deployment private

The deployment holds the vault database, its signing key and `.env`, with the
admin token and the SMTP and backup credentials. Under the home directory
nothing else could reach them. On the data disk, `/mnt/disks/bwgc` is readable
by every local user, so the deployment's own permissions are all that keeps
them private. A clone, and a `.env` copied from `.env.template`, are readable by
everyone.

The stack therefore refuses to start, at boot and at every supervisor run,
while other users can enter the deployment directory or `.env` is not `600`.
`migrate-to-data-disk.sh` and `upgrade-cos.sh` check the same before they
change anything, and stop with nothing done. Set it once, before migrating or
upgrading:

```sh
cd ~/bitwarden_gcloud
chmod o= .
chmod 600 .env
```

`bitwarden/rclone/rclone.conf` and `ddns/ddclient.conf` also hold credentials;
rclone and ddclient write them `600` themselves. When the stack does not come
up, the reason is in the journal:

```sh
journalctl -u bwgc.service -u bwgc-supervise.service --no-pager | grep bwgc:
```

## Install the update timer

```sh
./utilities/install-cos-update-reboot.sh
```

This prints the cloud-config and the `gcloud` command to apply it. It installs
nothing itself, for the reasons above. Run it from Cloud Shell.

Verify after the reboot that applies it:

```sh
systemctl list-timers cos-update-reboot.timer --no-pager
sudo systemctl start cos-update-reboot.service   # force one check
journalctl -u cos-update-reboot.service --no-pager | tail -20
```

With nothing staged, expect `nothing staged, not rebooting` and a clean exit.
A real end-to-end test needs a genuinely staged update, which cannot be forced.

## `reboot-on-update.sh`

`reboot-on-update.sh` blocks on `update_engine_client
--block_until_reboot_is_needed` and then calls `shutdown -r`.

Earlier revisions of this repository stated that nothing invoked it. That was
wrong. On instances configured through GCE `startup-script` metadata it runs at
every boot, and on one host inspected in August 2026 the process had been alive
since 2025:

```
root 15071  update_engine_client --block_until_reboot_is_needed   (started 2025)
```

The mechanism works. It is still worth replacing, for reasons that are about
control rather than correctness:

- It holds a blocking process for the life of the boot, so its state is
  invisible unless you go looking for it in `ps`.
- The reboot window is computed once at boot, so a machine that has been up for
  a year reboots against a stale calculation.
- It cannot be tested without waiting for a real update.
- `startup-script` and `user-data` are separate metadata keys, so a deployment
  can end up with one configuring reboots and the other configuring mounts.

The timer replaces it and is declared in the same cloud-config as everything
else. `reboot-on-update.sh` keeps its `eval` fix and is retained for reference;
`migrate-to-data-disk.sh` removes the `startup-script` key when it runs.

## Image updates

The cloud-config also runs `utilities/autoupdate/autoupdate.sh` every day
between 03:00 and 04:00 (`bwgc-autoupdate.timer`). It keeps every running
container of the stack current, plus `docker:cli`, which `compose.sh` runs
from, and it replaces watchtower: leave the `watchtower` compose profile off.

**The rule.** A new version is installed once this host has seen it for 3
days. The date is this host's own, never the image's `Created` field, which
whoever publishes the image writes and can backdate. Watchtower's cooldown
relies on that field.

On every run, a version waiting its turn is kept only while upstream still
points to it: through the followed tag, or through one of the precise tags
that pointed to it when it was first seen, such as `1.37.3-alpine` for
`latest-alpine`, or `master-20260923-153117` for `master`.

- A tag that moves every day still gets updated: the version from three days
  ago keeps its precise tag, and the newest version past its delay is
  installed.
- A version pulled or overwritten during its delay, as a compromised release
  would be once noticed, is dropped and never installed. The next version
  waits only its own delay.
- A version is the image's digest for this host's platform (amd64). A rebuild
  of another platform does not count as a new version.

**Installing.** The version is pulled by digest and the tag the compose file
uses is moved to it. Its services are then recreated. A container that does
not become healthy gets the previous image back. For a container without a
healthcheck, the test is that it is still running after 30 seconds.

**Mails** go to `AUTOUPDATE_EMAIL_TO`, or else to `BACKUP_EMAIL_TO`, through
the stack's `msmtpd` relay, which holds the SMTP credentials for every service.
You get one when:

- an update fails and the previous image is put back;
- a tag that should never move (a commit, a linuxserver `-ls` build, a build
  date) points to another image;
- a tag has had nothing installable for 7 days;
- a registry cannot be read.

**After a boot disk rebuild** (`upgrade-cos.sh`), the images are gone. Before
the stack starts, `bwgc.service` puts back the exact versions that were
installed, pulled by digest. Otherwise compose would pull whatever the tags
point to that day, with no quarantine. The quarantine state and the list of
installed versions live on the data disk, in `/mnt/disks/bwgc/autoupdate`.

```sh
journalctl -u bwgc-autoupdate.service --no-pager | tail -30
sudo systemctl start bwgc-autoupdate.service     # run now
sudo DRY_RUN=1 bash ~/bitwarden_gcloud/utilities/autoupdate/autoupdate.sh   # decide, change nothing
sudo bash ~/bitwarden_gcloud/utilities/autoupdate/autoupdate.sh --test-mail
```

**Updating by hand** (`docker compose pull` then `up -d`) bypasses the
quarantine. It is a deliberate act, so the next run notices the change and
starts tracking from the new version.

**Limit.** A compromised version whose publisher leaves its precise tag in
place is installed once its delay is over. The delay gives the publisher
time to clean up; it does not replace that.

`tests/autoupdate-docker.sh` covers each case against a real Docker daemon and
a local registry. It removes containers and images, so it only runs on a
throwaway machine.

## Limits

This applies updates **within the current milestone only**. COS does not move a
running instance across milestones, so a box on 109 stays on 109 no matter how
reliably this timer runs. Use `upgrade-cos.sh` for that, and see the wiki page
[Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS).

## Removal

Remove the `user-data` metadata key, or edit the cloud-config to drop the
`write_files` and `runcmd` entries, then reboot. The host simply stops
rebooting itself. No container or vault data is affected.
