#!/bin/sh
# Run the Ansible customization playbook inside the target rootfs (chroot),
# then remove Ansible and the playbook so they don't bloat the final image.
#
# The playbook was placed at /opt/ansible/playbook.yml by the custom overlay.

set -eu

USERNAME="${1:-kali}"
export DEBIAN_FRONTEND=noninteractive

PLAYBOOK=/opt/ansible/playbook.yml
if [ ! -f "${PLAYBOOK}" ]; then
    echo "ERROR: ${PLAYBOOK} not found (custom overlay didn't apply?)" >&2
    exit 1
fi

echo "INFO: installing ansible (build-time only)"
apt-get update
apt-get install -y --no-install-recommends ansible

echo "INFO: running playbook"
ansible-playbook -c local -i 'localhost,' "${PLAYBOOK}" -e "target_user=${USERNAME}"

echo "INFO: removing ansible + playbook (keep image lean)"
apt-get purge -y ansible
apt-get autoremove -y --purge
apt-get clean
rm -rf /opt/ansible

echo "INFO: ansible pass complete"
