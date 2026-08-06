#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname -- "$SCRIPT_DIR")"

install_packages() {
  sudo pacman -Syu --needed \
    apparmor \
    bat \
    base-devel \
    docker \
    docker-compose \
    dunst \
    firefox \
    git \
    gnome-keyring \
    htop \
    keepassxc \
    lf \
    linux-lts \
    lxappearance \
    lsd \
    man-db \
    neovim \
    numlockx \
    nsxiv \
    p7zip \
    pavucontrol \
    qbittorrent \
    torbrowser-launcher \
    ttf-fira-code \
    ttf-jetbrains-mono-nerd \
    ueberzug \
    ufw \
    unzip \
    vlc \
    nemo \
    xorg-xinit \
    yt-dlp
}

setup_ufw() {
  sudo systemctl enable --now ufw.service
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw --force enable
}

setup_docker() {
  sudo systemctl enable --now docker.service
  sudo usermod -aG docker "$USER"
  printf 'Docker group membership was added for %s; log out and back in before using Docker without sudo.\n' "$USER"
}

setup_kvm() {
  local virtualization_user="${SUDO_USER:-$USER}"

  sudo pacman -S --needed \
    bridge-utils \
    dmidecode \
    dnsmasq \
    edk2-ovmf \
    libguestfs \
    libvirt \
    openbsd-netcat \
    qemu-desktop \
    vde2 \
    virt-manager \
    virt-viewer

  if sudo test -f /etc/libvirt/libvirtd.conf; then
    sudo sed -i \
      -e 's/^#\?unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' \
      -e 's/^#\?unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' \
      /etc/libvirt/libvirtd.conf
  else
    printf 'Warning: /etc/libvirt/libvirtd.conf was not found; socket permissions were not changed.\n' >&2
  fi

  sudo systemctl enable --now libvirtd.service
  sudo usermod -aG libvirt,kvm "$virtualization_user"
  sudo systemctl restart libvirtd.service
  printf 'Libvirt and KVM group membership was added for %s; log out and back in before managing VMs without sudo.\n' "$virtualization_user"
}

setup_suckless_tools() {
  local project
  local repository
  local project_dir

  for project in dmenu dwm st; do
    repository="https://gitlab.com/linux-dejavu/$project"
    project_dir="$BUILD_DIR/$project"

    if [[ -d "$project_dir/.git" ]]; then
      git -C "$project_dir" pull --ff-only
    elif [[ -e "$project_dir" ]]; then
      printf 'Cannot clone %s: %s exists but is not a Git repository.\n' "$project" "$project_dir" >&2
      return 1
    else
      git clone "$repository" "$project_dir"
    fi

    make -C "$project_dir"
    sudo make -C "$project_dir" clean install
  done
}

fix_screen_tearing() {
  sudo install -Dm644 \
    "$SCRIPT_DIR/fix-screen-tearing/20-amd-gpu.conf" \
    /etc/X11/xorg.conf.d/20-amd-gpu.conf
}

main() {
  sudo -v
  install_packages
  setup_ufw
  setup_docker
  setup_kvm
  setup_suckless_tools
  fix_screen_tearing
}

main "$@"
