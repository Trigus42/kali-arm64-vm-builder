#!/usr/bin/env bash
#
# Build a custom Kali Linux VM image (arm64 qcow2) using debos.
#
# Adapted from Kali's official kali-vm build scripts, with two adaptations for
# an Apple-Silicon (arm64) host:
#
#   1. Targets arm64 (upstream build.sh only supports amd64).
#   2. Runs debos with --disable-fakemachine directly inside a real Linux VM
#      (HVF-accelerated). This avoids a NESTED VM: debos' normal fakemachine
#      would launch a QEMU VM inside our VM, and with no /dev/kvm available
#      (Apple nested virt needs M3+) that inner VM falls back to slow TCG. A
#      real VM also gives systemd-nspawn a proper mount-namespace root and loop
#      devices — both of which a container lacks — so --disable-fakemachine works.
#
# Backends:
#   BACKEND=lima      (default) dedicated, disposable Debian builder VM.  [FAST]
#   BACKEND=container           debos in a container via the qemu fakemachine
#                               backend (TCG).                   [SLOW fallback]
#
# Modes:
#   ./build.sh                     full build (rootfs + image)
#   ./build.sh --stage-rootfs      build ONLY the reusable rootfs tarball (once)
#   ./build.sh --from-rootfs       fast image build reusing the staged rootfs
#   ./build.sh --update-upstream   bump kali-vm submodule + re-check patches
#   ./build.sh --reset-vm          delete the lima builder VM (reclaim its disk)
#
# Env:
#   BACKEND=lima|container
#   LIMA_VM=kali-builder       (lima instance name)
#   DEBOS_IMAGE=godebos/debos  (debos container image, container backend only)
#   CONTAINER=docker|podman    (container backend only, auto-detected)

set -euo pipefail

# --- Configuration ----------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
KALIVM_DIR="${HERE}/ext/kali-vm"     # upstream submodule (pristine)
PATCHES_DIR="${HERE}/patches"        # our changes on top of upstream
IMAGES_DIR="${HERE}/images"

# User-tunable knobs (packages, user, image size, desktop, …) live in config.sh.
# shellcheck source=config.sh
. "${HERE}/config.sh"

BACKEND="${BACKEND:-lima}"
LIMA_VM="${LIMA_VM:-kali-builder}"
DEBOS_IMAGE="${DEBOS_IMAGE:-godebos/debos}"

# Derived / fixed build parameters (not user knobs).
VARIANT=qemu
FORMAT=qemu
IMAGENAME="kali-linux-${VERSION}-${VARIANT}-${ARCH}"
ROOTFS_NAME="rootfs-${VERSION}-${ARCH}"
MEMORY=4G          # container-backend fakemachine memory
SCRATCHSIZE=20G    # container-backend fakemachine scratch

# --- Small helpers ----------------------------------------------------------

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

ensure_submodule() {
    if [ ! -e "${KALIVM_DIR}/main.yaml" ]; then
        log "Fetching kali-vm submodule..."
        git -C "${HERE}" submodule update --init --recursive
    fi
}

# Bump the submodule to latest upstream, then verify our patches still apply.
update_upstream() {
    log "Updating kali-vm submodule to latest upstream..."
    git -C "${HERE}" submodule update --remote --recursive ext/kali-vm
    local new; new=$(git -C "${KALIVM_DIR}" rev-parse --short HEAD)
    echo "    now at ${new}: $(git -C "${KALIVM_DIR}" log -1 --format='%s')"

    log "Checking our patches still apply..."
    local fail=0 p tmp
    for p in "${PATCHES_DIR}"/*.patch; do
        [ -e "$p" ] || continue
        tmp=$(mktemp -d); cp -a "${KALIVM_DIR}/." "$tmp/"
        if patch -p1 --dry-run -s -d "$tmp" < "$p" >/dev/null 2>&1; then
            echo "    OK: $(basename "$p")"
        else
            echo "    CONFLICT: $(basename "$p") — upstream changed a file we patch; update the patch." >&2
            fail=1
        fi
        rm -rf "$tmp"
    done
    [ $fail -eq 0 ] || die "Resolve patch conflicts before building."
    log "All patches apply. Commit the submodule bump when ready."
}

# Echo the debos -t template args for the given mode (stage-rootfs|from-rootfs|full).
debos_mode_args() {
    local mode=$1
    case "$mode" in
        stage-rootfs)
            printf '%s\n' -t "rootfs:${ROOTFS_NAME}" -t variant:rootfs \
                          -t format: -t imagename: -t imagesize: ;;
        from-rootfs)
            [ -f "${IMAGES_DIR}/${ROOTFS_NAME}.tar.gz" ] \
                || die "images/${ROOTFS_NAME}.tar.gz not found — run './build.sh --stage-rootfs' first"
            printf '%s\n' -t "rootfs:${ROOTFS_NAME}" -t "variant:${VARIANT}" \
                          -t "format:${FORMAT}" -t "imagename:${IMAGENAME}" -t "imagesize:${IMAGESIZE}" ;;
        full)
            printf '%s\n' -t rootfs: -t "variant:${VARIANT}" \
                          -t "format:${FORMAT}" -t "imagename:${IMAGENAME}" -t "imagesize:${IMAGESIZE}" ;;
    esac
}

# Common debos -t template args (shared by all modes).
debos_common_args() {
    printf '%s\n' \
        -t "arch:${ARCH}" -t "branch:${BRANCH}" -t "desktop:${DESKTOP}" \
        -t "hostname:${HOSTNAME}" -t "keyboard:${KEYBOARD}" -t "locale:${LOCALE}" \
        -t "mirror:${MIRROR}" -t packages: \
        -t "password:${PASSWORD}" -t "timezone:${TIMEZONE}" -t "toolset:${TOOLSET}" \
        -t "username:${USERNAME}" -t keep:false -t zip:false -t uefi:true
}

# The build script that runs INSIDE the builder (lima VM or container). It:
#   - picks a native ext4 work dir (NOT the shared mount — tar can't honour its
#     file ops), with the most free space (avoids the small root disk filling)
#   - assembles the debos work tree in three layers, like a Docker image build:
#       1. ext/kali-vm  — pristine upstream submodule
#       2. patches/*    — our changes to upstream files
#       3. overlay/ + scripts/ — our files, at the paths the patched recipes use
#   - runs debos --disable-fakemachine, then copies artifacts back to $PROJ/images
# Invoked as: bash -s -- "$PROJ" <debos args...>   (project dir mounted at $PROJ)
REMOTE_BUILD='
set -euo pipefail
PROJ="$1"; shift

WORKBASE=$(df -PT 2>/dev/null | awk '\''$2=="ext4"{print $5, $7}'\'' | sort -rn | awk '\''NR==1{print $2}'\'')
[ -n "${WORKBASE:-}" ] && [ -w "$WORKBASE" ] || WORKBASE=/var/tmp
[ -d "$WORKBASE" ] && [ -w "$WORKBASE" ] || WORKBASE=/tmp
echo "INFO: using work base $WORKBASE ($(df -h "$WORKBASE" | awk '\''NR==2{print $4}'\'') free)"

WORK=$(mktemp -d "$WORKBASE/debos.XXXXXX")
trap '\''rm -rf "$WORK"'\'' EXIT

cp -a "$PROJ/ext/kali-vm/." "$WORK/"
for p in "$PROJ"/patches/*.patch; do
    [ -e "$p" ] || continue
    echo "INFO: applying patch $(basename "$p")"
    patch -p1 -s -d "$WORK" < "$p"
done
mkdir -p "$WORK/overlays/custom"
cp -a "$PROJ/overlay/." "$WORK/overlays/custom/"
cp -a "$PROJ/scripts/." "$WORK/scripts/"

mkdir -p "$WORK/images"
cp -a "$PROJ/images/." "$WORK/images/" 2>/dev/null || true   # seed staged rootfs (from-rootfs)

cd "$WORK"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"   # keep debos scratch off the small root /tmp
debos --disable-fakemachine --artifactdir="$WORK/images" "$@" main.yaml

mkdir -p "$PROJ/images"
cp -a "$WORK/images/." "$PROJ/images/" 2>/dev/null || true
'

# --- Backends ---------------------------------------------------------------
# Each backend runs REMOTE_BUILD in its environment, passing the debos args.

# Dedicated, disposable Debian builder VM under lima (vz/HVF). Real VM, so
# nspawn + loop devices both work; debos comes from Debian trixie's apt repo
# (installed by the VM's provision step). Does NOT touch colima/Docker.
run_lima() {
    command -v limactl >/dev/null || die "limactl not found (install lima)"
    ensure_lima_vm
    limactl shell "${LIMA_VM}" command -v debos >/dev/null 2>&1 \
        || die "debos not present in '${LIMA_VM}' — provisioning failed. Try: limactl delete -f ${LIMA_VM} && ./build.sh"

    limactl shell "${LIMA_VM}" sudo bash -s -- "${HERE}" "$@" <<<"${REMOTE_BUILD}" \
        || die "debos build failed in the lima VM"
    trim_lima_vm   # return build scratch space to the host
}

ensure_lima_vm() {
    if ! limactl list --quiet 2>/dev/null | grep -qx "${LIMA_VM}"; then
        log "Creating lima builder VM '${LIMA_VM}' (Debian 13 + debos)..."
        limactl start --tty=false --name="${LIMA_VM}" "${HERE}/lima/kali-builder.yaml"
    elif [ "$(limactl list --format '{{.Status}}' "${LIMA_VM}" 2>/dev/null)" != "Running" ]; then
        log "Starting lima builder VM '${LIMA_VM}'..."
        limactl start --tty=false "${LIMA_VM}"
    fi
}

# Delete the builder VM so the next build recreates it fresh. The VM's disk is a
# qcow2 on the host that grows with use and doesn't auto-shrink; over many builds
# it can balloon (tens of GB). Run './build.sh --reset-vm' to reclaim that.
reset_lima_vm() {
    command -v limactl >/dev/null || die "limactl not found"
    log "Deleting lima builder VM '${LIMA_VM}' (frees its disk on the host)..."
    limactl delete -f "${LIMA_VM}" 2>/dev/null || true
}

# Return space freed inside the VM back to the host (lima qcow2 disks are
# trim-capable). Cheap; run after each build.
trim_lima_vm() {
    limactl shell "${LIMA_VM}" sudo fstrim -a 2>/dev/null || true
}

# Fallback: debos in a privileged container via the qemu fakemachine backend
# (TCG, ~5x slower). Needed because --disable-fakemachine can't run nspawn in a
# container, so we let debos spin up its own (emulated) VM instead. The extra
# -b/--memory/--scratchsize args steer that fakemachine VM.
run_container() {
    local engine="${CONTAINER:-}"
    if [ -z "${engine}" ]; then
        if   command -v docker >/dev/null 2>&1; then engine=docker
        elif command -v podman >/dev/null 2>&1; then engine=podman
        else die "neither docker nor podman found"; fi
    fi
    exec "${engine}" run --rm --privileged \
        --platform linux/arm64 --network host --entrypoint bash \
        -v "${HERE}:${HERE}:ro" -v "${IMAGES_DIR}:${IMAGES_DIR}" \
        "${DEBOS_IMAGE}" -s -- "${HERE}" \
        -b qemu --memory="${MEMORY}" --scratchsize="${SCRATCHSIZE}" "$@" \
        <<<"${REMOTE_BUILD}"
}

# --- Main -------------------------------------------------------------------

main() {
    local mode=full
    local passthru=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --stage-rootfs)    mode=stage-rootfs ;;
            --from-rootfs)     mode=from-rootfs ;;
            --update-upstream) mode=update-upstream ;;
            --reset-vm)        mode=reset-vm ;;
            --) shift; passthru+=("$@"); break ;;
            *)  passthru+=("$1") ;;
        esac
        shift
    done

    [ "${mode}" = reset-vm ] && { reset_lima_vm; exit 0; }

    ensure_submodule
    [ "${mode}" = update-upstream ] && { update_upstream; exit 0; }

    mkdir -p "${IMAGES_DIR}"

    # Collect debos args for this mode into an array.
    local args=()
    while IFS= read -r a; do args+=("$a"); done < <(debos_common_args)
    while IFS= read -r a; do args+=("$a"); done < <(debos_mode_args "${mode}")

    local target
    case "${mode}" in
        stage-rootfs) target="images/${ROOTFS_NAME}.tar.gz" ;;
        *)            target="images/${IMAGENAME}.qcow2" ;;
    esac
    log "Kali VM build [backend: ${BACKEND}, mode: ${mode}] -> ${target}"
    echo "    arch=${ARCH} desktop=${DESKTOP} toolset=${TOOLSET}"
    echo

    case "${BACKEND}" in
        lima)      run_lima "${args[@]}" "${passthru[@]}" ;;
        container) run_container "${args[@]}" "${passthru[@]}" ;;
        *) die "unknown BACKEND '${BACKEND}' (use lima|container)" ;;
    esac

    echo
    log "Done. Artifacts in ${IMAGES_DIR}/:"
    ls -lah "${IMAGES_DIR}/" | sed 's/^/    /'
}

main "$@"
