# AGENTS.md — handover notes for this repo

Context for AI agents (and humans) working on this project. Read this first.

## What this is

A build system for a native **arm64 Kali Linux VM image** (qcow2) for Apple
Silicon. It layers our customizations on top of Kali's official upstream
[`kali-vm`](https://gitlab.com/kalilinux/build-scripts/kali-vm) debos recipe,
which is pinned as a git submodule at `ext/kali-vm` and **never edited in
place** — changes go in `patches/`, `overlay/`, `scripts/`, and `config.sh`.

The build runs [debos](https://github.com/go-debos/debos) inside a disposable
**lima** VM (Debian 13 trixie under `vz`/HVF), NOT in a container and NOT in
your Docker/colima setup. See README.md for the full user-facing docs.

## Repo layout

```
build.sh                 # entry point: assembles work tree + runs debos in lima
config.sh                # user knobs: username, image size, desktop, toolset, arch/branch
ext/kali-vm/             # upstream submodule (pristine, pinned — DO NOT EDIT)
patches/                 # small diffs applied to upstream recipes at build time
overlay/                 # static files dropped verbatim into the rootfs (overlays/custom)
scripts/                 # build-time + host-side helper scripts
lima/kali-builder.yaml   # the disposable debos builder VM definition
images/                  # build output (gitignored)
```

### The four-place configuration model (important)

Each kind of change has exactly ONE home. When editing, put things in the
right place:

| File | Owns |
|---|---|
| `config.sh` | knobs: user, image size, desktop, toolset, arch/branch |
| `overlay/opt/ansible/playbook.yml` | extra apt packages + idempotent system config (services, groups, shells, perms, dotfiles, autostarts) |
| `scripts/third-party-install.sh` | non-apt installs (docker-ce/VS Code repos, starship, mise, uv, jwt_tool) |
| `overlay/` | static config files, dropped in verbatim (dotfiles, sshd, sudoers, sddm, on-demand installers) |

## Build modes (and which to use)

- `./build.sh` — full build (rootfs + image), slow.
- `./build.sh --stage-rootfs` — build the reusable rootfs tarball once (slow).
- `./build.sh --from-rootfs` — **fast** image rebuild reusing the staged rootfs.
  Use this for iterating on overlay files, the Ansible playbook, package list,
  dotfiles, sshd/sudoers. Takes a few minutes.
- `./build.sh --update-upstream` — bump the `ext/kali-vm` submodule and dry-run
  the patches against it.
- `./build.sh --reset-vm` — delete the builder VM to reclaim its disk.

Only base/desktop/toolset changes or `scripts/third-party-install.sh` edits
need a fresh `--stage-rootfs`. Everything else is `--from-rootfs`.

> **Keep ~60 GB free on the host.** Peak build scratch is ~40-55 GB inside the
> builder VM (a qcow2 on the Mac). If the Mac fills up, the build fails with
> "Input/output error".

Optional: `./scripts/apt-cache.sh start` runs a persistent apt-cacher-ng on the
host; `build.sh` auto-detects it at `host.lima.internal:3142`.

## Running the built image

Target runtime is **UTM** (chosen over lima because lima/vz has no clipboard
sharing and audio was flaky). See README.md "Run" section.

- `./scripts/make-seed-iso.sh` generates `images/seed.iso`, a cloud-init
  "cidata" ISO. Attach it as a second drive in UTM. On first boot cloud-init
  injects your SSH key and installs the host-share mount service.
- Clipboard sharing works via `spice-vdagent` (preinstalled) in UTM's SPICE
  display; no lima equivalent. Under a **Wayland** session spice-vdagent can't
  read the Wayland clipboard (guest->host copy breaks), so we also ship a
  Wayland->X11 bridge (vendored from `chrisbelson/wayland-spice-clipboard-fix`):
  `/usr/local/bin/wayland-spice-clipboard` + a globally-enabled user unit
  (`/etc/systemd/user/` symlinked into `default.target.wants`). Deps
  (`wl-clipboard`, `xclip`) and enablement live in the playbook. Note: we do
  NOT ship the upstream repo's `spice-vdagent-manual.desktop` autostart — the
  Kali `spice-vdagent` package already ships & enables its own user unit
  (`/usr/lib/systemd/user/spice-vdagent.service`, running `spice-vdagent -x`);
  the upstream .desktop only existed for its ad-hoc Fedora per-user install.

### cloud-init seed — hard-won gotchas (READ before editing make-seed-iso.sh)

This script went through many iterations. The current shape is deliberate:

1. **SSH key MUST go via `write_files`, not the `users:` block.** cloud-init's
   `users` module SKIPS `ssh_authorized_keys` injection for a user that already
   exists in the image (kali is created at build time). Writing
   `/home/kali/.ssh/authorized_keys` directly via `write_files` is the only
   reliable path. `runcmd` then fixes the `.ssh` dir ownership/permissions.
2. **The `users:` block is still needed for `lock_passwd: false`.** Debian's
   cloud-init default (`/etc/cloud/cloud.cfg`) has `lock_passwd: True` for the
   default user, which LOCKS the kali password and breaks **desktop (SDDM)
   login** while leaving SSH working. Keeping `users: [{name: kali,
   lock_passwd: false}]` prevents that. Symptom if this regresses:
   `unix_chkpwd: password check failed for user (kali)` in the journal, and
   `passwd -S kali` shows `L` (locked).
3. **`instance-id` must change each run** (`kali-vm-$(date +%s)`), or cloud-init
   treats a re-attached ISO as the same instance and SKIPS re-running — your
   edits appear to do nothing. Verify with `sudo cat
   /var/lib/cloud/data/instance-id` in the guest vs. the ISO's meta-data.
4. **hdiutil vs mkisofs**: on macOS with no mkisofs/genisoimage, we fall back to
   `hdiutil makehybrid -ov`. The volume label MUST be exactly `cidata` for
   cloud-init's NoCloud datasource to find it.
5. **Host share mount**: shipped as `utm-share.service` (a oneshot) that tries
   `9p` (UTM QEMU backend) then `virtiofs` (UTM Apple VZ backend), silently
   no-ops if neither is present. Mounts at `~/Share`.

**When debugging the guest**, the source-of-truth files are:
- `/var/lib/cloud/instance/user-data.txt` — what cloud-init actually read
- `/var/lib/cloud/data/instance-id` — cached instance id (governs re-run)
- `/var/log/cloud-init.log` — grep for `write_files|runcmd|WARN|ERROR`
If these don't exist / weren't updated, the new seed ISO was NOT picked up
(almost always the instance-id or the ISO attachment).

## How the build works (mechanics)

`build.sh` assembles a work tree — `ext/kali-vm` (upstream) + `patches/*`
applied + `overlay/` copied to `overlays/custom` + `scripts/` — inside the lima
VM, then runs `debos --disable-fakemachine` on it. Upstream is never modified
in place.

- Real VM (not container) is required: debos needs `systemd-nspawn` (proper
  mount-namespace root) and loop devices. `--disable-fakemachine` avoids
  nesting a slow TCG VM (Apple nested virt needs M3+).
- The builder uses Debian `generic` (not `genericcloud`, which lacks the
  virtiofs module lima needs to share the project dir).
- The overlay is applied in BOTH build paths: `rootfs.yaml` (full) and
  `image.yaml`'s recustomize block (from-rootfs), via
  `patches/0001-arm64-recustomize-compression.patch`. So overlay files are
  present regardless of build mode.

## Things that will bite you

- Editing `ext/kali-vm/` directly — don't. Use `patches/`.
- Assuming `--from-rootfs` picks up a base/desktop/toolset change — it won't;
  those need `--stage-rootfs`.
- cloud-init changes "not working" — see the seed gotchas above (instance-id).
- Desktop login breaking after cloud-init — the `lock_passwd` issue above.
