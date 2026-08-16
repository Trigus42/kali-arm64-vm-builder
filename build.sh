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
#   BACKEND=lima      (default) dedicated, disposable Debian builder VM via lima.
#                     Does NOT touch your colima setup.                 [FAST]
#   BACKEND=colima              run debos inside your existing colima VM
#                               (shares it).                            [FAST]
#   BACKEND=container           debos in a container via the qemu fakemachine
#                               backend (TCG).                          [SLOW fallback]
#
# Modes:
#   ./build.sh                 full build (rootfs + image)
#   ./build.sh --stage-rootfs  build ONLY the reusable rootfs tarball (once)
#   ./build.sh --from-rootfs   fast image build reusing the staged rootfs,
#                              re-applying config-only customizations
#   ./build.sh --update-upstream   bump kali-vm submodule + re-check patches
#
# Env:
#   BACKEND=lima|colima|container
#   LIMA_VM=kali-builder       (lima instance name)
#   COLIMA_PROFILE=default     (colima backend only)
#   DEBOS_IMAGE=godebos/debos  (source of the debos binary; container backend)
#   CONTAINER=docker|podman    (container backend only, auto-detected)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KALIVM_DIR="${HERE}/ext/kali-vm"     # upstream submodule (pristine)
PATCHES_DIR="${HERE}/patches"        # our changes on top of upstream

BACKEND="${BACKEND:-lima}"
COLIMA_PROFILE="${COLIMA_PROFILE:-default}"

# Ensure the upstream submodule is present (checked out).
if [ ! -e "${KALIVM_DIR}/main.yaml" ]; then
    echo "==> Fetching kali-vm submodule..."
    git -C "${HERE}" submodule update --init --recursive
fi

# --- Mode parsing -----------------------------------------------------------
MODE=full
PASSTHRU=()
while [ $# -gt 0 ]; do
    case "$1" in
        --stage-rootfs) MODE=stage-rootfs ;;
        --from-rootfs)  MODE=from-rootfs ;;
        --update-upstream) MODE=update-upstream ;;
        --) shift; PASSTHRU+=("$@"); break ;;
        *)  PASSTHRU+=("$1") ;;
    esac
    shift
done

# --- Upstream update helper -------------------------------------------------
# Bump the submodule to latest upstream, then check our patch still applies.
if [ "${MODE}" = update-upstream ]; then
    echo "==> Updating kali-vm submodule to latest upstream..."
    git -C "${HERE}" submodule update --remote --recursive ext/kali-vm
    NEW=$(git -C "${KALIVM_DIR}" rev-parse --short HEAD)
    echo "    now at ${NEW}: $(git -C "${KALIVM_DIR}" log -1 --format='%s')"
    echo "==> Checking our patches still apply..."
    fail=0
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
    [ $fail -eq 0 ] && echo "==> All patches apply. Commit the submodule bump when ready." \
                    || { echo "==> Resolve patch conflicts before building." >&2; exit 1; }
    exit 0
fi

# --- Build parameters -------------------------------------------------------
ARCH=arm64
BRANCH=kali-rolling
VERSION=rolling
DESKTOP=xfce
TOOLSET=default
VARIANT=qemu
FORMAT=qemu
HOSTNAME=kali
USERNAME=kali
PASSWORD=kali
LOCALE=en_US.UTF-8
KEYBOARD=us
TIMEZONE=America/New_York
# Virtual disk size of the image. Kept modest because debos builds a full-size
# *raw* image first (not sparse through mkfs/deploy), then converts to qcow2 —
# so IMAGESIZE must fit in the VM's build scratch AND hold the installed system
# plus room for the in-image kernel/grub install. The installed rootfs is
# ~16.5GB; 28GB leaves ~11GB in-image headroom, and 28GB raw + ~7GB qcow2 fits
# the build scratch. Grow later with 'qemu-img resize' + expanding the root
# partition, or by attaching a bigger disk (see README).
IMAGESIZE=28GB
IMAGENAME="kali-linux-${VERSION}-${VARIANT}-${ARCH}"
ROOTFS_NAME="rootfs-${VERSION}-${ARCH}"

# qcow2 is sparse; --scratchsize only needs to exceed the *written* data.
MEMORY=4G
SCRATCHSIZE=20G

# Extra apt packages: the "keep" list of tools ported from the reference image
# that ARE available in Kali's arm64 repositories. (docker-ce, VS Code,
# starship, mise, uv, jwt_tool are handled in scripts/third-party-install.sh.)
PACKAGES="sliver ffuf burpsuite bloodhound crackmapexec netexec evil-winrm \
hashcat git git-lfs zsh-autosuggestions zsh-syntax-highlighting nano \
fuse-overlayfs openssh-server"

DEBOS_IMAGE="${DEBOS_IMAGE:-godebos/debos}"

# Normalise the package list: comma+space separated, sorted, deduped
PACKAGES_CSV=$(echo "${PACKAGES}" \
    | tr ', ' '\n\n' | sed '/^$/d' | LC_ALL=C sort -u \
    | awk 'ORS=", "' | sed 's/, $//')

mkdir -p "${HERE}/images"

# --- Assemble debos template vars per mode ----------------------------------
DEBOS_COMMON=(
    -t arch:"${ARCH}"
    -t branch:"${BRANCH}"
    -t desktop:"${DESKTOP}"
    -t hostname:"${HOSTNAME}"
    -t keyboard:"${KEYBOARD}"
    -t locale:"${LOCALE}"
    -t mirror:http://http.kali.org/kali
    -t packages:"${PACKAGES_CSV}"
    -t password:"${PASSWORD}"
    -t timezone:"${TIMEZONE}"
    -t toolset:"${TOOLSET}"
    -t username:"${USERNAME}"
    -t keep:false
    -t zip:false
    -t uefi:true
)

case "${MODE}" in
    stage-rootfs)
        DEBOS_MODE_ARGS=( -t rootfs:"${ROOTFS_NAME}" -t variant:rootfs -t format: -t imagename: -t imagesize: )
        SUMMARY="stage rootfs -> images/${ROOTFS_NAME}.tar.gz"
        ;;
    from-rootfs)
        if [ ! -f "${HERE}/images/${ROOTFS_NAME}.tar.gz" ]; then
            echo "ERROR: images/${ROOTFS_NAME}.tar.gz not found — run './build.sh --stage-rootfs' first" >&2
            exit 1
        fi
        DEBOS_MODE_ARGS=( -t rootfs:"${ROOTFS_NAME}" -t variant:"${VARIANT}" -t format:"${FORMAT}" -t imagename:"${IMAGENAME}" -t imagesize:"${IMAGESIZE}" )
        SUMMARY="fast image from rootfs -> images/${IMAGENAME}.qcow2"
        ;;
    full)
        DEBOS_MODE_ARGS=( -t rootfs: -t variant:"${VARIANT}" -t format:"${FORMAT}" -t imagename:"${IMAGENAME}" -t imagesize:"${IMAGESIZE}" )
        SUMMARY="full build (rootfs + image) -> images/${IMAGENAME}.qcow2"
        ;;
esac

echo "==> Kali VM build [backend: ${BACKEND}, mode: ${MODE}]"
echo "    ${SUMMARY}"
echo "    arch=${ARCH} desktop=${DESKTOP} toolset=${TOOLSET}"
[ "${MODE}" != from-rootfs ] && echo "    extra packages: ${PACKAGES_CSV}"
echo

# The in-VM build script, shared by the lima and colima backends. It receives
# "$PROJ $MODE <debos args...>" and: picks a VM-native ext4 work dir (NOT the
# virtiofs mount — tar can't honour its file ops), assembles the debos work tree
# (submodule + patches + overlay/scripts), runs debos --disable-fakemachine, and
# copies artifacts back to the mounted project images/ dir.
read -r -d '' REMOTE_BUILD <<'REMOTE' || true
set -euo pipefail
PROJ="$1"; shift
MODE="$1"; shift    # informational; debos args follow

# Pick the writable ext4 mount with the most free space (avoids the small root
# disk overflowing during image-partition / qemu-img convert).
WORKBASE=$(df -PT 2>/dev/null | awk '$2=="ext4"{print $5, $7}' | sort -rn | awk 'NR==1{print $2}')
[ -n "${WORKBASE:-}" ] && [ -w "$WORKBASE" ] || WORKBASE=/var/tmp
[ -d "$WORKBASE" ] && [ -w "$WORKBASE" ] || WORKBASE=/tmp
echo "INFO: using work base $WORKBASE ($(df -h "$WORKBASE" | awk 'NR==2{print $4}') free)"

WORK=$(mktemp -d "$WORKBASE/debos.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Assemble the debos work tree from three layers (like a Docker image build):
#   1. ext/kali-vm  — pristine upstream submodule (never edited)
#   2. patches/*    — our small changes to upstream files (arm64 kernel,
#                     recustomize hook, qcow2 -c compression), applied on top
#   3. overlay/ + scripts/ — OUR files, at the paths the patched recipes expect
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
# Seed with any already-staged artifacts (e.g. the rootfs tarball for --from-rootfs)
cp -a "$PROJ/images/." "$WORK/images/" 2>/dev/null || true

cd "$WORK"
# Keep debos' temp/scratch on the work volume too (not the small root /tmp).
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
debos --disable-fakemachine --artifactdir="$WORK/images" "$@" main.yaml

mkdir -p "$PROJ/images"
cp -a "$WORK/images/." "$PROJ/images/" 2>/dev/null || true
REMOTE

# Extract the debos binary from the godebos/debos OCI image to a host temp file.
# (go-debos ships no release binaries and it's not in Debian; the OCI image has
# the arm64 build at /usr/local/bin/debos.) Echoes the temp path.
extract_debos_binary() {
    command -v docker >/dev/null || { echo "ERROR: need docker once to extract the debos binary" >&2; return 1; }
    local tmp cid
    tmp=$(mktemp)
    cid=$(docker create --platform linux/arm64 "${DEBOS_IMAGE}")
    docker cp "${cid}:/usr/local/bin/debos" "${tmp}" >/dev/null
    docker rm "${cid}" >/dev/null
    echo "${tmp}"
}

# ============================================================================
# Backend: lima (default) — dedicated, disposable Debian builder VM.
# Does NOT touch colima. Real VM under vz/HVF: nspawn + loop devices both work.
# ============================================================================
run_lima() {
    command -v limactl >/dev/null || { echo "ERROR: limactl not found (install lima)" >&2; exit 1; }
    local vm="${LIMA_VM:-kali-builder}"

    if ! limactl list --quiet 2>/dev/null | grep -qx "${vm}"; then
        echo "==> Creating lima builder VM '${vm}' (Debian 13 + debos, ~409MB base)..."
        limactl start --tty=false --name="${vm}" "${HERE}/lima/kali-builder.yaml"
    elif [ "$(limactl list --format '{{.Status}}' "${vm}" 2>/dev/null)" != "Running" ]; then
        echo "==> Starting lima builder VM '${vm}'..."
        limactl start --tty=false "${vm}"
    fi

    # debos is installed by the template's provision step (apt, from Debian
    # trixie) — no docker needed. Fail loudly if it's somehow missing rather
    # than silently "succeeding" with no build.
    if ! limactl shell "${vm}" command -v debos >/dev/null 2>&1; then
        echo "ERROR: debos not present in '${vm}' — provisioning failed. Try: limactl delete -f ${vm} && ./build.sh" >&2
        exit 1
    fi

    if ! limactl shell "${vm}" sudo bash -s -- \
        "${HERE}" "${MODE}" "${DEBOS_COMMON[@]}" "${DEBOS_MODE_ARGS[@]}" "${PASSTHRU[@]}" <<<"${REMOTE_BUILD}"
    then
        echo "ERROR: debos build failed in the lima VM" >&2
        exit 1
    fi
}

# ============================================================================
# Backend: colima — run debos inside your existing colima VM (shares it).
# ============================================================================
run_colima() {
    command -v colima >/dev/null || { echo "ERROR: colima not found" >&2; exit 1; }
    colima status "${COLIMA_PROFILE}" >/dev/null 2>&1 || \
        { echo "ERROR: colima profile '${COLIMA_PROFILE}' not running (try: colima start)" >&2; exit 1; }

    echo "==> Ensuring debos is installed in the colima VM..."
    if ! colima ssh --profile "${COLIMA_PROFILE}" -- command -v debos >/dev/null 2>&1; then
        local tmp; tmp=$(extract_debos_binary) || exit 1
        colima ssh --profile "${COLIMA_PROFILE}" -- sudo tee /usr/local/bin/debos >/dev/null < "${tmp}"
        colima ssh --profile "${COLIMA_PROFILE}" -- sudo chmod +x /usr/local/bin/debos
        rm -f "${tmp}"
        colima ssh --profile "${COLIMA_PROFILE}" -- sudo bash -c \
            'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq \
                debootstrap systemd-container dosfstools e2fsprogs parted qemu-utils \
                libostree-1-1 zerofree xz-utils patch >/dev/null'
    fi

    if ! colima ssh --profile "${COLIMA_PROFILE}" -- sudo bash -s -- \
        "${HERE}" "${MODE}" "${DEBOS_COMMON[@]}" "${DEBOS_MODE_ARGS[@]}" "${PASSTHRU[@]}" <<<"${REMOTE_BUILD}"
    then
        echo "ERROR: debos build failed in the colima VM" >&2
        exit 1
    fi
}

# ============================================================================
# Backend: container (TCG fallback) — debos in a container, qemu fakemachine.
# Slow (~5x) but needs no VM. Uses the qemu backend because --disable-fakemachine
# can't run systemd-nspawn inside a container.
# ============================================================================
run_container() {
    local CONTAINER="${CONTAINER:-}"
    if [ -z "${CONTAINER}" ]; then
        if command -v docker >/dev/null 2>&1; then CONTAINER=docker
        elif command -v podman >/dev/null 2>&1; then CONTAINER=podman
        else echo "ERROR: neither docker nor podman found" >&2; exit 1; fi
    fi
    exec "${CONTAINER}" run --rm --privileged \
        --platform linux/arm64 --network host --entrypoint bash \
        -v "${HERE}:/proj:ro" -v "${HERE}/images:/out" \
        "${DEBOS_IMAGE}" \
        -c '
            set -e
            mkdir -p /work && cp -a /proj/ext/kali-vm/. /work/
            for p in /proj/patches/*.patch; do
                [ -e "$p" ] || continue
                echo "INFO: applying patch $(basename "$p")"
                patch -p1 -s -d /work < "$p"
            done
            mkdir -p /work/overlays/custom
            cp -a /proj/overlay/. /work/overlays/custom/
            cp -a /proj/scripts/. /work/scripts/
            mkdir -p /work/images
            cp -a /out/. /work/images/ 2>/dev/null || true
            cd /work
            debos "$@"
            cp -a /work/images/. /out/ 2>/dev/null || true
        ' bash \
        -b qemu --memory="${MEMORY}" --scratchsize="${SCRATCHSIZE}" \
        --artifactdir=/work/images \
        "${DEBOS_COMMON[@]}" "${DEBOS_MODE_ARGS[@]}" "${PASSTHRU[@]}" main.yaml
}

case "${BACKEND}" in
    lima)      run_lima ;;
    colima)    run_colima ;;
    container) run_container ;;
    *) echo "ERROR: unknown BACKEND '${BACKEND}' (use lima|colima|container)" >&2; exit 1 ;;
esac

echo
echo "==> Done. Artifacts in ${HERE}/images/:"
ls -lah "${HERE}/images/" | sed 's/^/    /'
