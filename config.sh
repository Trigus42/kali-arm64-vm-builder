# Build configuration for the custom Kali VM image.
#
# This file is pure data (sourced by build.sh) — edit the values here, no logic.
# It is the one place to change WHAT goes into the image.

# --- Image basics -----------------------------------------------------------
USERNAME=kali            # primary user
PASSWORD=kali            # its password (change me for anything real)
HOSTNAME=kali
DESKTOP=xfce             # e17 | gnome | i3 | kde | lxde | mate | xfce | none
TOOLSET=default          # default | everything | headless | large | none
LOCALE=en_US.UTF-8
KEYBOARD=us
TIMEZONE=America/New_York

# Virtual disk size. debos builds a full-size raw image first (not sparse
# through mkfs/deploy), then compresses to qcow2 — so this must fit the build
# scratch AND hold the installed system (~16.5GB) plus kernel/grub headroom.
# Grow later with 'qemu-img resize' + expanding the root partition (see README).
IMAGESIZE=28GB

# --- Base / arch (rarely changed) -------------------------------------------
ARCH=arm64
BRANCH=kali-rolling      # kali-dev | kali-last-snapshot | kali-rolling
VERSION=rolling
MIRROR=http://http.kali.org/kali

# Extra apt packages (sliver, ffuf, docker's friends, guest agents, …) are NOT
# here — they live in overlay/opt/ansible/playbook.yml (extra_packages), so a
# tool-list change is a fast './build.sh --from-rootfs' rather than a full
# rootfs rebuild. Non-apt tools (docker-ce, VS Code, starship, mise, uv,
# jwt_tool) are installed by scripts/third-party-install.sh.
