#!/bin/sh
# Non-apt tooling install, run inside the target rootfs (chroot).
#
# Scope: ONLY software that isn't a plain Kali apt package —
#   - docker-ce from Docker's upstream apt repo (parity with the reference)
#   - VS Code from Microsoft's apt repo
#   - starship, mise, uv (upstream install scripts)
#   - jwt_tool (installed as a uv tool)
#
# System CONFIG (services, groups, shells, dotfiles, autostarts) is NOT done
# here — that's the Ansible playbook's job (overlay/opt/ansible/playbook.yml).
# Plain Kali apt packages are installed by debos (config.sh PACKAGES).

set -eu

USERNAME="${1:-kali}"
export DEBIAN_FRONTEND=noninteractive

# Debian codename of the current Kali rolling base, used for the docker repo.
# Kali rolling tracks Debian testing; the reference pinned this to trixie.
DEBIAN_CODENAME=trixie
ARCH=$(dpkg --print-architecture)

echo "INFO: non-apt install for user '${USERNAME}' (arch ${ARCH})"

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

echo "INFO: non-apt install complete"
