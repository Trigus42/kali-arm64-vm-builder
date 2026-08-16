# Custom Kali Linux VM image (arm64)

A native **arm64** Kali Linux VM image (qcow2) for Apple Silicon, built with
[debos](https://github.com/go-debos/debos) on top of Kali's official
[`kali-vm`](https://gitlab.com/kalilinux/build-scripts/kali-vm) recipe, with a
curated set of tools and config preinstalled.

> Kali only publishes pre-built VM images for **amd64** — there's no arm64
> pre-built VM, only an installer ISO. So on Apple Silicon we build a native
> arm64 image instead of downloading one.

## Build

Requires **lima** (`limactl`). The build runs in a dedicated, disposable lima
VM — it does **not** touch your Docker/colima setup.

```console
$ git submodule update --init --recursive   # first time only (fetches kali-vm)
$ ./build.sh
```

Output: `images/kali-linux-rolling-qemu-arm64.qcow2` (~6.5 GB, zlib-compressed).

> **Keep ~60 GB free on the host.** A full build's peak scratch is ~40-55 GB
> inside the builder VM, whose disk is a qcow2 on your Mac. If the Mac fills up
> mid-build, the guest fails with "Input/output error".

### Faster rebuilds

Most of a build is debootstrap + installing the desktop and tools, which rarely
change. Build the reusable rootfs once, then iterate on config quickly:

```console
$ ./build.sh --stage-rootfs   # once: build the reusable rootfs tarball (slow)
$ ./build.sh --from-rootfs     # each iteration: fast image build
```

`--from-rootfs` reuses `images/rootfs-rolling-arm64.tar.gz` and re-applies only
the config (overlay files + the Ansible playbook), so edits to the **package
list** (in the playbook), dotfiles, sshd/sudoers, or any playbook task
take effect in a few minutes. Only changing the base/desktop/toolset or the
third-party installers (`scripts/third-party-install.sh`) needs a fresh
`--stage-rootfs`.

### Options

```console
$ ./build.sh --reset-vm            # delete the builder VM (reclaim its disk)
$ BACKEND=container ./build.sh     # build without lima (slow TCG fallback)
$ LIMA_VM=my-builder ./build.sh    # use a differently-named lima instance
```

> The builder VM's disk grows with use and doesn't auto-shrink. `build.sh`
> trims it after each build; if it still balloons, `--reset-vm` deletes it and
> the next build recreates it fresh.

## Run

```console
$ FW=$(dirname $(command -v qemu-system-aarch64))/../share/qemu/edk2-aarch64-code.fd
$ qemu-system-aarch64 \
    -machine virt -accel hvf -cpu host -smp 4 -m 4096 \
    -bios "$FW" \
    -drive if=virtio,file=images/kali-linux-rolling-qemu-arm64.qcow2,format=qcow2 \
    -device virtio-gpu-pci -display default,show-cursor=on \
    -device qemu-xhci -device usb-kbd -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=n0
```

Log in as `kali` / `kali`. SSH: `ssh -p 2222 kali@localhost` (key-only — add
your key to the guest's `~/.ssh/authorized_keys` first, or log in at the
console). qemu-guest-agent and spice-vdagent are preinstalled.

### Growing the disk

The image ships at 28 GB. To enlarge it, grow the qcow2 (host, VM shut down)
then expand the filesystem (in the guest):

```console
$ qemu-img resize images/kali-linux-rolling-qemu-arm64.qcow2 +80G
# then, in the guest:
$ sudo growpart /dev/vda 1 && sudo resize2fs /dev/vda1
```

## What's in the image

- **Pentest tools**: sliver, ffuf, burpsuite, bloodhound, crackmapexec,
  netexec, evil-winrm, hashcat.
- **Dev tools**: docker-ce, VS Code, git-lfs, fuse-overlayfs, nano,
  zsh-autosuggestions, zsh-syntax-highlighting.
- **Toolchain**: starship, mise, uv, jwt_tool.
- **Shell**: zsh default; custom `.zshrc` + `starship.toml` for `kali` and `root`.
- **System**: passwordless sudo for `kali`; key-only SSH; ssh + docker enabled
  on boot; `kali` in the docker group; qemu/spice guest agents.
- **Desktop**: KDE Plasma (Wayland); power management disabled; autologin as `kali`.

To add/remove tools, edit `extra_packages` in
**`overlay/opt/ansible/playbook.yml`**; for user, image size, desktop, or
toolset, edit **`config.sh`**.

## Configuration model

Customizations live in four clearly-separated places, so it's obvious where to
change each kind of thing:

| File | Owns |
|---|---|
| `config.sh` | knobs: user, image size, desktop, toolset, arch/branch |
| `overlay/opt/ansible/playbook.yml` | extra apt packages + idempotent system config (services, groups, shells, perms, dotfiles, autostarts) |
| `scripts/third-party-install.sh` | non-apt installs (docker-ce/VS Code repos, starship, mise, uv, jwt_tool) |
| `overlay/` | static config files, dropped in verbatim (dotfiles, sshd, sudoers, sddm) |

## How it's built

The repo layers our changes on top of upstream `kali-vm` (a **pinned git
submodule** we never edit), like a Docker `FROM`:

```
ext/kali-vm/           # upstream submodule (pristine, pinned)
patches/               # small changes to upstream recipes (arm64 kernel,
                       #   recustomize hook, qcow2 -c compression)
overlay/               # our static files → dropped in as overlays/custom
scripts/               # third-party-install.sh, run-ansible.sh
config.sh              # user-tunable knobs
lima/kali-builder.yaml # the builder VM definition
build.sh               # assembles the above + runs debos
```

At build time `build.sh` assembles a work tree (`ext/kali-vm` + `patches/*` +
`overlay/` + `scripts/`) inside the lima VM and runs debos on it; upstream is
never modified in place.

`build.sh` runs debos with `--disable-fakemachine` inside the lima VM (Debian 13
trixie under `vz`/HVF, so near-native arm64 speed). A real VM is required
because debos needs `systemd-nspawn` (a proper mount-namespace root, which
containers lack) and loop devices; its default fakemachine would nest a slow
TCG VM (Apple nested virt needs M3+). debos itself is installed from Debian's
apt repo by the VM's provision step. The VM uses the Debian `generic` image
(not `genericcloud`, which lacks the virtiofs module lima needs).

### Updating upstream

```console
$ ./build.sh --update-upstream
```

Bumps the `ext/kali-vm` submodule to latest and dry-runs `patches/*` against it.
If all apply, commit the bump (`git add ext/kali-vm && git commit`) and rebuild.
If a patch conflicts, upstream changed a file we patch — regenerate that patch
by hand (only the few patched hunks can ever conflict; the rest of upstream is
used verbatim).
