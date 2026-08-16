# Custom Kali Linux VM image (arm64)

A [debos](https://github.com/go-debos/debos)-built custom Kali Linux VM image
(native **arm64** qcow2), based on Kali's official
[`kali-vm`](https://gitlab.com/kalilinux/build-scripts/kali-vm) build recipe,
with the same customizations as the reference RDP container **minus** the
container/RDP-specific plumbing.

## Why debos + arm64

Kali only publishes pre-built VM images (QEMU/VMware/VirtualBox/Hyper-V) for
**amd64** — there is no arm64 pre-built VM, only an arm64 installer ISO. On an
Apple-Silicon Mac a native arm64 image runs fast under HVF. debos is the tool
Kali itself uses to build its images and produces a native arm64 rootfs
directly (no install-boot cycle).

## What's customized

Ported from the reference image (genuine customizations only):

- **Pentest tools** (Kali apt): sliver, ffuf, burpsuite, bloodhound,
  crackmapexec, netexec, evil-winrm, hashcat.
- **Dev tools**: docker-ce (upstream repo), VS Code (Microsoft repo), git-lfs,
  fuse-overlayfs, nano, zsh-autosuggestions, zsh-syntax-highlighting.
- **Toolchain**: starship prompt, mise, uv, jwt_tool (uv tool).
- **Shell**: custom `.zshrc` + `starship.toml` for `kali` and `root`; default
  shell zsh.
- **System**: passwordless sudo for `kali`; key-only SSH (`sshd_config`);
  ssh + docker enabled on boot; `kali` in the docker group.
- **Desktop**: XFCE `xfwm4` tweaks (compositing **on** for a local VM);
  screensaver / locker / power-manager autostarts disabled.

**Deliberately dropped** (container/RDP-only): xrdp, tigervnc, supervisor,
bwrap-shim, gocryptfs, syncthing, autopsy, and all `startup/*.sh` init scripts.

## Layout

This repo layers our customizations on top of Kali's official
[`kali-vm`](https://gitlab.com/kalilinux/build-scripts/kali-vm) build scripts —
the same idea as a Docker `FROM`. Upstream is a **pinned git submodule** that we
never edit; our changes live in three clearly-separated places:

```
ext/kali-vm/             # UPSTREAM submodule (pristine, pinned — never edited)
patches/
  0001-arm64-recustomize-compression.patch
                         # our small changes to upstream recipe files:
                         #   - image.yaml:  linux-image-arm64 (upstream is amd64-only)
                         #   - main.yaml:   pass username + recustomize flag to image stage
                         #   - rootfs.yaml: hook in our overlay + third-party + ansible
                         #   - export-qemu.sh: qcow2 -c compression
overlay/                 # OUR config files (dropped in as overlays/custom):
  etc/skel/.zshrc, .config/starship.toml
  etc/ssh/sshd_config, etc/sudoers.d/kali-nopasswd
  etc/xdg/.../xfwm4.xml, opt/ansible/playbook.yml
scripts/                 # OUR scripts (merged into the recipe scripts/):
  third-party-install.sh # docker-ce, VS Code, starship, mise, uv, jwt_tool
  run-ansible.sh         # runs the Ansible playbook, then purges ansible
build.sh                 # assembles submodule + patches + overlay/scripts, runs debos
```

At build time `build.sh` assembles a work tree = `ext/kali-vm` → apply
`patches/*` → drop `overlay/` into `overlays/custom/` and `scripts/*` into
`scripts/` → run debos. Nothing in `ext/kali-vm` is modified in place.

## Build

Requires **colima** (an HVF-accelerated arm64 Linux VM) — which you already
use as your Docker backend. Docker is only needed once, to extract the debos
binary into the VM.

Clone with the submodule (or `build.sh` will fetch it on first run):

```console
$ git clone --recurse-submodules <this-repo>
# or, in an existing clone:
$ git submodule update --init --recursive
```

```console
$ ./build.sh
```

Output: `images/kali-linux-rolling-qemu-arm64.qcow2` (~6.5 GB — the qcow2 is
zlib-compressed via `qemu-img convert -c`; a full desktop+toolset install is
~17 GB uncompressed).

### How it runs (and why it's fast)

`build.sh` runs debos with `--disable-fakemachine` **directly inside the colima
Linux VM**. That VM is accelerated by Apple's Hypervisor.framework (HVF), so
the build runs at near-native arm64 speed. The first run bootstraps the VM
(installs the debos binary + `debootstrap`, `systemd-container`, `parted`,
`qemu-utils`, … via apt) — subsequent runs skip that.

> **Why not debos' default (fakemachine)?** debos normally spins up its *own*
> QEMU VM. Inside the colima VM that would be a **nested** VM, and Apple only
> supports the nested virtualization that exposes `/dev/kvm` on **M3+** — on an
> M1/M2 the inner VM falls back to slow TCG software emulation (≈5× slower).
> Running debos natively in the colima VM avoids the nesting entirely:
> systemd-nspawn works there because the VM has a real systemd, `/dev/disk`
> and loop devices.
>
> A container-based TCG fallback is available via `BACKEND=container ./build.sh`
> if colima isn't usable.

### Faster rebuilds (rootfs reuse)

Most of a full build is debootstrap + installing the desktop, the Kali toolset
and our extra packages — which rarely change. Split the build so you only pay
that cost once:

```console
$ ./build.sh --stage-rootfs   # once: build the reusable rootfs tarball
$ ./build.sh --from-rootfs    # each iteration: fast image build (skips debootstrap+apt)
```

`--from-rootfs` unpacks `images/rootfs-rolling-arm64.tar.gz`, then re-applies
the **config-only** customizations (the `overlays/custom` files + the Ansible
playbook) before partitioning and exporting the qcow2. So edits to dotfiles,
sshd/sudoers config, xfwm4 settings or the Ansible tasks take effect quickly.
Changing the **package list** (or the third-party installers) means re-running
`--stage-rootfs`.

Env overrides:

```console
$ BACKEND=container ./build.sh    # TCG fallback, no colima
$ COLIMA_PROFILE=myprofile ./build.sh
```

### Updating upstream kali-vm

Because upstream is a pinned submodule and our changes are a patch, staying
current is a two-step check — no manual merge of copied files:

```console
$ ./build.sh --update-upstream
```

This bumps `ext/kali-vm` to the latest upstream commit and dry-runs every
`patches/*.patch` against it:

- **All patches apply** → commit the submodule bump (`git add ext/kali-vm && git commit`) and rebuild.
- **A patch conflicts** → upstream changed a file we patch. Regenerate that
  patch: apply the old one to a copy, redo the edit by hand, `diff -u` the
  result back into `patches/`. Only the ~4 small hunks can ever conflict; the
  other 37 upstream files are used verbatim and never conflict.

This replaces the old "vendored copy" approach (where upstream changes were
invisible). We rebase our *own* feature work normally; we do **not** rebase
onto upstream history — the submodule+patch model tracks upstream without
rewriting our history.

## Run (Apple Silicon, HVF-accelerated)

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
your key to `~/.ssh/authorized_keys` in the guest first, or log in at the
console).

## Growing the disk

The image ships at 28 GB (debos builds a full-size raw image first, so a huge
virtual size would need a huge build scratch — see the size note in
`build.sh`). To give the VM more room later, grow the qcow2 and expand the
filesystem from inside the guest:

```console
# on the host, with the VM shut down:
$ qemu-img resize images/kali-linux-rolling-qemu-arm64.qcow2 +80G

# then in the running guest (root partition is the last partition):
$ sudo growpart /dev/vda 1        # from the cloud-guest-utils package
$ sudo resize2fs /dev/vda1
```

