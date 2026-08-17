#!/usr/bin/env bash
# Generate a cloud-init "cidata" seed ISO for the Kali VM.
#
# Attach as a second drive in UTM. On first boot cloud-init:
#   - injects your SSH public key into /home/kali/.ssh/authorized_keys
#   - keeps the kali password intact and non-expiring
#   - installs a service that mounts UTM's host share at ~/Share on boot,
#     trying virtio-9p (QEMU backend) then virtiofs (Apple VZ backend);
#     silently does nothing if sharing is not configured
#
# Usage:
#   ./scripts/make-seed-iso.sh                     # uses ~/.ssh/id_ed25519.pub
#   SSH_KEY=~/.ssh/other.pub ./scripts/make-seed-iso.sh
#
# Output: images/seed.iso  (safe to re-run — overwrites the previous seed)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMAGES_DIR="${HERE}/images"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519.pub}"

if [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH public key not found at ${SSH_KEY}" >&2
    echo "       Set SSH_KEY=/path/to/key.pub or generate one with: ssh-keygen -t ed25519" >&2
    exit 1
fi

PUBKEY="$(cat "${SSH_KEY}")"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/cidata"

cat > "${TMP}/cidata/meta-data" <<META
instance-id: kali-vm-$(date +%s)
local-hostname: kali
META

cat > "${TMP}/cidata/user-data" <<USERDATA
#cloud-config
users:
  - name: kali
    lock_passwd: false
    no_create_home: true

write_files:
  - path: /home/kali/.ssh/authorized_keys
    permissions: '0600'
    owner: kali:kali
    content: |
      ${PUBKEY}

  - path: /usr/local/sbin/mount-utm-share
    permissions: '0755'
    content: |
      #!/bin/sh
      mountpoint -q /home/kali/Share && exit 0
      if mount -t 9p -o trans=virtio,version=9p2000.L,rw share /home/kali/Share 2>/dev/null; then
        exit 0
      fi
      mount -t virtiofs share /home/kali/Share 2>/dev/null || true

  - path: /etc/systemd/system/utm-share.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Mount UTM host share (9p or virtiofs)
      After=local-fs.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/mount-utm-share
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

runcmd:
  - mkdir -p /home/kali/.ssh
  - chown kali:kali /home/kali/.ssh
  - chmod 700 /home/kali/.ssh
  - mkdir -p /home/kali/Share
  - chown kali:kali /home/kali/Share
  - systemctl daemon-reload
  - systemctl enable utm-share.service
USERDATA

mkdir -p "${IMAGES_DIR}"

# Build a plain ISO9660 image with mkisofs/genisoimage if available,
# otherwise fall back to hdiutil. The label must be exactly "cidata".
if command -v mkisofs >/dev/null 2>&1; then
    mkisofs -quiet -joliet -rock -volid cidata \
        -output "${IMAGES_DIR}/seed.iso" "${TMP}/cidata"
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -joliet -rock -volid cidata \
        -output "${IMAGES_DIR}/seed.iso" "${TMP}/cidata"
else
    hdiutil makehybrid -ov -o "${IMAGES_DIR}/seed.iso" \
        -joliet -iso -default-volume-name cidata \
        "${TMP}/cidata"
fi

echo "Created ${IMAGES_DIR}/seed.iso"
echo "  Key: ${SSH_KEY}"
