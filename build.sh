#!/usr/bin/env bash
#
# Build a custom Kali Linux VM image (arm64 qcow2) using debos.
#
# Adapted from Kali's official kali-vm build scripts, with two adaptations for
# an Apple-Silicon (arm64) host:
#
#   1. Targets arm64 (upstream build.sh only supports amd64).
#   2. Runs debos with --disable-fakemachine directly inside the colima Linux
#      VM (which is itself HVF-accelerated). This avoids a NESTED VM: debos'
#      normal fakemachine would launch a QEMU VM inside the colima VM, and with
#      no /dev/kvm available (Apple nested virt needs M3+) that inner VM falls
#      back to slow TCG emulation. Running debos natively in the colima VM keeps
#      everything at HVF speed — systemd-nspawn works there because it has a
#      real systemd + /dev/disk + loop devices.
#
# Backends:
#   BACKEND=colima     (default) run debos natively in the colima VM  [FAST]
#   BACKEND=container            run debos in a container via the qemu
#                                fakemachine backend (TCG)             [SLOW fallback]
#
# Modes:
#   ./build.sh                 full build (rootfs + image)
#   ./build.sh --stage-rootfs  build ONLY the reusable rootfs tarball (once)
#   ./build.sh --from-rootfs   fast image build reusing the staged rootfs,
#                              re-applying config-only customizations
#
# Env:
#   BACKEND=colima|container
#   COLIMA_PROFILE=default     (colima profile to use)
#   DEBOS_IMAGE=godebos/debos  (container backend only)
#   CONTAINER=docker|podman    (container backend only, auto-detected)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KALIVM_DIR="${HERE}/ext/kali-vm"     # upstream submodule (pristine)
PATCHES_DIR="${HERE}/patches"        # our changes on top of upstream

BACKEND="${BACKEND:-colima}"
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

# ============================================================================
# Backend: colima (native, fast) — run debos inside the HVF-accelerated VM
# ============================================================================
run_colima() {
    command -v colima >/dev/null || { echo "ERROR: colima not found" >&2; exit 1; }
    colima status "${COLIMA_PROFILE}" >/dev/null 2>&1 || \
        { echo "ERROR: colima profile '${COLIMA_PROFILE}' not running (try: colima start)" >&2; exit 1; }

    # One-time bootstrap: install the debos binary + build deps into the VM.
    # The binary is lifted from the godebos/debos image (arm64 ELF, glibc).
    echo "==> Ensuring debos is installed in the colima VM..."
    if ! colima ssh --profile "${COLIMA_PROFILE}" -- command -v debos >/dev/null 2>&1; then
        command -v docker >/dev/null || { echo "ERROR: need docker (once) to extract the debos binary" >&2; exit 1; }
        local tmp; tmp=$(mktemp)
        local cid; cid=$(docker create --platform linux/arm64 "${DEBOS_IMAGE}")
        docker cp "${cid}:/usr/local/bin/debos" "${tmp}"
        docker rm "${cid}" >/dev/null
        colima ssh --profile "${COLIMA_PROFILE}" -- sudo tee /usr/local/bin/debos >/dev/null < "${tmp}"
        colima ssh --profile "${COLIMA_PROFILE}" -- sudo chmod +x /usr/local/bin/debos
        rm -f "${tmp}"
        colima ssh --profile "${COLIMA_PROFILE}" -- sudo bash -c \
            'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq \
                debootstrap systemd-container dosfstools e2fsprogs parted qemu-utils \
                libostree-1-1 zerofree xz-utils >/dev/null'
    fi

    # Run debos natively. debos' scratch dir must be on VM-native ext4 (NOT the
    # virtiofs mount, which can't honour tar's file ops), and it must have room
    # for the whole rootfs (~24GB for the full toolset). The colima root disk is
    # small (~20GB); the big data volume (where /var/lib/docker lives) has far
    # more free space, so we place the work dir there. We pick, at runtime, the
    # ext4 mount with the most available space.
    local proj="${HERE}"
    if ! colima ssh --profile "${COLIMA_PROFILE}" -- sudo bash -s -- \
        "${proj}" "${MODE}" "${DEBOS_COMMON[@]}" "${DEBOS_MODE_ARGS[@]}" "${PASSTHRU[@]}" <<'REMOTE'
set -euo pipefail
PROJ="$1"; shift
MODE="$1"; shift    # informational; debos args follow

# Choose the VM-native ext4 mount with the most free space for the work dir.
# The big data volume (holding /var/lib/docker, /var/lib/ramalama) has the most
# room; the root disk is small. Pick the writable ext4 mount with max available.
WORKBASE=$(df -PT 2>/dev/null | awk '$2=="ext4"{print $5, $7}' | sort -rn | awk 'NR==1{print $2}')
[ -n "${WORKBASE:-}" ] && [ -w "$WORKBASE" ] || WORKBASE=/var/lib/ramalama
[ -d "$WORKBASE" ] && [ -w "$WORKBASE" ] || WORKBASE=/tmp
echo "INFO: using work base $WORKBASE ($(df -h "$WORKBASE" | awk 'NR==2{print $4}') free)"

WORK=$(mktemp -d "$WORKBASE/debos.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Assemble the debos work tree from three layers (like a Docker image build):
#   1. ext/kali-vm  — pristine upstream submodule (never edited)
#   2. patches/*    — our small changes to upstream files (arm64 kernel,
#                     recustomize hook, qcow2 -c compression), applied on top
#   3. overlay/ + scripts/ — OUR files, dropped in at the paths the patched
#                     recipes expect (overlays/custom, scripts/*.sh)
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
# Keep ALL of debos' temp/scratch on the big volume too — otherwise it defaults
# to /tmp (the small ~20GB root disk) and the image-partition/qemu-img convert
# steps overflow it ("No space left on device" mid-export). TMPDIR governs
# where debos + qemu-img create their intermediate files.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
debos --disable-fakemachine --artifactdir="$WORK/images" "$@" main.yaml

# Copy artifacts back to the (virtiofs-mounted) project images dir
mkdir -p "$PROJ/images"
cp -a "$WORK/images/." "$PROJ/images/" 2>/dev/null || true
REMOTE
    then
        echo "ERROR: debos build failed in the colima VM" >&2
        exit 1
    fi
}

# ============================================================================
# Backend: container (TCG fallback) — debos in a container, qemu fakemachine
# ============================================================================
run_container() {
    local CONTAINER="${CONTAINER:-}"
    if [ -z "${CONTAINER}" ]; then
        if command -v docker >/dev/null 2>&1; then CONTAINER=docker
        elif command -v podman >/dev/null 2>&1; then CONTAINER=podman
        else echo "ERROR: neither docker nor podman found" >&2; exit 1; fi
    fi
    # Mount the whole project read-only; assemble the work tree inside the
    # container the same way as the colima path (submodule + patch + overlay).
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
    colima)    run_colima ;;
    container) run_container ;;
    *) echo "ERROR: unknown BACKEND '${BACKEND}' (use colima|container)" >&2; exit 1 ;;
esac

echo
echo "==> Done. Artifacts in ${HERE}/images/:"
ls -lah "${HERE}/images/" | sed 's/^/    /'
