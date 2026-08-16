#!/bin/sh
# Third-party tooling install, run inside the target rootfs (chroot).
#
# Everything here is a genuine customization ported from the reference image
# that is NOT available as a plain Kali apt package:
#   - docker-ce from Docker's upstream apt repo (parity with the reference)
#   - VS Code from Microsoft's apt repo
#   - starship, mise, uv (upstream install scripts)
#   - jwt_tool (installed as a uv tool)
#   - place the ported dotfiles for root and the primary user
#   - disable screensaver / locker / power-manager desktop autostarts
#   - enable ssh + docker services
#
# Container-only pieces from the reference (bwrap-shim, supervisor, xrdp,
# gocryptfs, syncthing, autopsy) are intentionally NOT ported.

set -eu

USERNAME="${1:-kali}"
USERHOME="/home/${USERNAME}"
export DEBIAN_FRONTEND=noninteractive

# Debian codename of the current Kali rolling base, used for the docker repo.
# Kali rolling tracks Debian testing; the reference pinned this to trixie.
DEBIAN_CODENAME=trixie
ARCH=$(dpkg --print-architecture)

echo "INFO: third-party install for user '${USERNAME}' (arch ${ARCH})"

# ---------------------------------------------------------------------------
# APT repositories: Docker CE (upstream) + VS Code (Microsoft)
# ---------------------------------------------------------------------------
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings

# Docker CE upstream repo
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${DEBIAN_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# VS Code (Microsoft) repo
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod a+r /etc/apt/keyrings/microsoft.gpg
cat > /etc/apt/sources.list.d/vscode.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF

apt-get update
apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    code
apt-get clean

# ---------------------------------------------------------------------------
# starship prompt (system-wide binary)
# ---------------------------------------------------------------------------
curl -sS https://starship.rs/install.sh | sh -s -- --yes

# ---------------------------------------------------------------------------
# mise (tool version manager) - system-wide binary
# ---------------------------------------------------------------------------
curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# ---------------------------------------------------------------------------
# uv / uvx (system-wide) + jwt_tool as a uv tool
# ---------------------------------------------------------------------------
curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
# Install jwt_tool for the primary user so the tool lives in their profile
su -s /bin/sh -c "/usr/local/bin/uv tool install --no-cache git+https://github.com/Trigus42/jwt_tool.git" "${USERNAME}" || \
    /usr/local/bin/uv tool install --no-cache git+https://github.com/Trigus42/jwt_tool.git

# ---------------------------------------------------------------------------
# Dotfiles: the overlay dropped them into /etc/skel; place copies for the
# already-created primary user and for root.
# ---------------------------------------------------------------------------
for target in "${USERHOME}" /root; do
    mkdir -p "${target}/.config"
    cp /etc/skel/.zshrc "${target}/.zshrc"
    cp /etc/skel/.config/starship.toml "${target}/.config/starship.toml"
done
chown -R "${USERNAME}:${USERNAME}" "${USERHOME}"

# ---------------------------------------------------------------------------
# Desktop QoL: disable screensaver / locker / power management autostarts
# (parity with the reference; harmless if a file is absent)
# ---------------------------------------------------------------------------
rm -f /etc/xdg/autostart/xfce4-screensaver.desktop \
      /etc/xdg/autostart/light-locker.desktop \
      /etc/xdg/autostart/xfce4-power-manager.desktop

# ---------------------------------------------------------------------------
# Services: enable ssh + docker so they start on boot
# ---------------------------------------------------------------------------
systemctl enable ssh.service || true
systemctl enable docker.service || true

# Add the primary user to the docker group
usermod -aG docker "${USERNAME}" || true

echo "INFO: third-party install complete"
