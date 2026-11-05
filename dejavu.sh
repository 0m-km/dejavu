#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROGS_FILE="${1:-$SCRIPT_DIR/static/progs.csv}"
SRC_DIR="$HOME/.config/build"
DOTFILES_REPO="https://github.com/me0mar/dotfiles"
BETTERFOX_REPO="https://github.com/yokoffing/Betterfox"
WALLPAPER_URL="https://raw.githubusercontent.com/dracula/wallpaper/master/first-collection/arch.png"
DRACULA_GTK_URL="https://raw.githubusercontent.com/0m-km/dejavu/main/static/gtk/dracula-gtk.zip"
failed=()

check_not_root() {
  if [[ $EUID -eq 0 ]]; then
    printf 'Run this script as your normal user, not root; it uses sudo when needed.\n' >&2
    exit 1
  fi
}

keep_sudo_alive() {
  sudo -v
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
}

configure_pacman() {
  local conf=/etc/pacman.conf

  [[ -e "$conf.bak" ]] || sudo cp "$conf" "$conf.bak"
  sudo sed -i \
    -e 's/^#VerbosePkgLists$/VerbosePkgLists/' \
    -e 's/^#\?ParallelDownloads = .*/ParallelDownloads = 10/' \
    "$conf"
  # Guard the append so reruns don't add a second ILoveCandy line.
  if ! grep -q '^ILoveCandy$' "$conf"; then
    sudo sed -i '/^ParallelDownloads = 10$/a ILoveCandy' "$conf"
  fi
}

install_prerequisites() {
  sudo pacman -Syu --needed --noconfirm base-devel git
}

clone_or_pull() {
  local repository="$1"
  local project_dir="$2"

  if [[ -d "$project_dir/.git" ]]; then
    git -C "$project_dir" pull --ff-only
  elif [[ -e "$project_dir" ]]; then
    printf 'Cannot clone %s: %s exists but is not a Git repository.\n' "$repository" "$project_dir" >&2
    return 1
  else
    git clone "$repository" "$project_dir"
  fi
}

install_paru() {
  local project_dir="$SRC_DIR/paru-bin"

  if command -v paru >/dev/null; then
    return
  fi

  clone_or_pull https://aur.archlinux.org/paru-bin.git "$project_dir"
  (cd "$project_dir" && makepkg -si --noconfirm)
}

main_install() {
  sudo pacman -S --needed --noconfirm "$1"
}

aur_install() {
  paru -S --needed --noconfirm --skipreview "$1"
}

git_make_install() {
  local repository="$1"
  local project_dir="$SRC_DIR/$(basename "$repository" .git)"

  # set -e is off inside a function called with ||, so stop on each failure.
  clone_or_pull "$repository" "$project_dir" || return 1
  make -C "$project_dir" || return 1
  sudo make -C "$project_dir" install
}

installation_loop() {
  local rows
  local row
  local tag
  local program
  local purpose
  local n=0

  if [[ ! -f "$PROGS_FILE" ]]; then
    printf 'Package list not found: %s\n' "$PROGS_FILE" >&2
    exit 1
  fi

  mkdir -p "$SRC_DIR"
  mapfile -t rows < <(grep -v -e '^#' -e '^[[:space:]]*$' "$PROGS_FILE")

  for row in "${rows[@]}"; do
    IFS=, read -r tag program purpose <<<"$row"
    purpose="${purpose#\"}"
    purpose="${purpose%\"}"
    n=$((n + 1))
    printf '\n[%d/%d] %s %s\n' "$n" "${#rows[@]}" "$program" "$purpose"

    case "$tag" in
      A) aur_install "$program" || failed+=("$program") ;;
      G) git_make_install "$program" || failed+=("$program") ;;
      *) main_install "$program" || failed+=("$program") ;;
    esac
  done
}

link_file() {
  local source="$1"
  local target="$2"

  if [[ -L "$target" && "$(readlink -- "$target")" == "$source" ]]; then
    return
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    mv -- "$target" "$target.bak"
    printf 'Backed up %s to %s.bak\n' "$target" "$target"
  fi

  mkdir -p -- "$(dirname -- "$target")"
  ln -s -- "$source" "$target"
}

deploy_dotfiles() {
  local dotfiles_dir="$SRC_DIR/dotfiles"
  local file

  clone_or_pull "$DOTFILES_REPO" "$dotfiles_dir"

  while IFS= read -r -d '' file; do
    [[ $file == README.md || $file == LICENSE ]] && continue
    link_file "$dotfiles_dir/$file" "$HOME/$file"
  done < <(git -C "$dotfiles_dir" ls-files -z)
}

setup_firefox() {
  local firefox_dir="${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"
  local betterfox_dir="$SRC_DIR/Betterfox"
  local screenshot_dir
  local profile

  # Firefox keeps using ~/.mozilla if it already exists; new installs use XDG.
  if [[ -d "$HOME/.mozilla/firefox" ]]; then
    firefox_dir="$HOME/.mozilla/firefox"
  fi

  if [[ ! -f "$firefox_dir/installs.ini" ]]; then
    # A headless start creates the default-release profile, then exits after the screenshot.
    screenshot_dir="$(mktemp -d)"
    firefox --headless --screenshot "$screenshot_dir/blank.png" about:blank >/dev/null 2>&1 || true
    rm -rf -- "$screenshot_dir"
  fi

  profile="$(sed -n '/^Default=/{s///p;q}' "$firefox_dir/installs.ini" 2>/dev/null || true)"
  if [[ -z $profile ]]; then
    printf 'No default Firefox profile found in %s.\n' "$firefox_dir" >&2
    return 1
  fi
  [[ $profile == /* ]] || profile="$firefox_dir/$profile"

  clone_or_pull "$BETTERFOX_REPO" "$betterfox_dir"
  link_file "$betterfox_dir/user.js" "$profile/user.js"
}

setup_wallpaper() {
  local wallpaper="$HOME/.local/share/wallpapers/dracula-arch.png"

  if [[ ! -f "$wallpaper" ]]; then
    curl -fsSL --create-dirs -o "$wallpaper.part" "$WALLPAPER_URL"
    mv -- "$wallpaper.part" "$wallpaper"
  fi

  # ~/.xinitrc runs ~/.fehbg; this is the same script `feh --bg-fill` writes.
  printf '#!/bin/sh\nfeh --no-fehbg --bg-fill %q\n' "$wallpaper" >"$HOME/.fehbg"
  chmod +x "$HOME/.fehbg"
}

setup_gtk_theme() {
  local theme_dir="$HOME/.local/share/themes/Dracula"
  local download_dir
  local file
  local settings
  local version

  if [[ ! -d "$theme_dir" ]]; then
    download_dir="$(mktemp -d)"
    curl -fsSL -o "$download_dir/dracula.zip" "$DRACULA_GTK_URL"
    unzip -q "$download_dir/dracula.zip" -d "$download_dir"
    mkdir -p -- "$(dirname -- "$theme_dir")"
    mv -- "$download_dir/gtk-master" "$theme_dir"
    rm -rf -- "$download_dir"
  fi

  # libadwaita apps ignore the theme name and load this CSS, which points at ../assets.
  link_file "$theme_dir/assets" "$HOME/.config/assets"
  for file in gtk.css gtk-dark.css; do
    link_file "$theme_dir/gtk-4.0/$file" "$HOME/.config/gtk-4.0/$file"
  done

  # dwm has no settings daemon, so GTK apps read settings.ini instead of gsettings.
  for version in 3.0 4.0; do
    settings="$HOME/.config/gtk-$version/settings.ini"
    if [[ -f "$settings" ]]; then
      # shortcut: a file without a gtk-theme-name line stays unthemed, add the line if that ever happens.
      sed -i 's/^gtk-theme-name=.*/gtk-theme-name=Dracula/' "$settings"
    else
      mkdir -p -- "$(dirname -- "$settings")"
      printf '[Settings]\ngtk-theme-name=Dracula\n' >"$settings"
    fi
  done
  gsettings set org.gnome.desktop.interface gtk-theme Dracula
}

setup_ufw() {
  sudo systemctl enable --now ufw.service
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw --force enable
}

setup_docker() {
  # Bind published ports to localhost by default; Docker's NAT rules bypass UFW.
  sudo install -Dm644 "$SCRIPT_DIR/static/docker/daemon.json" /etc/docker/daemon.json
  sudo systemctl enable --now docker.service
  sudo usermod -aG docker "$USER"
}

setup_kvm() {
  local net_info

  sudo systemctl enable --now libvirtd.service
  sudo usermod -aG libvirt "$USER"

  sudo virsh net-autostart default
  net_info="$(sudo virsh net-info default)"
  if ! grep -Eq '^Active:[[:space:]]+yes' <<<"$net_info"; then
    sudo virsh net-start default
  fi

  # Let VMs reach dnsmasq on the host and route out through the NAT network.
  sudo ufw allow in on virbr0
  sudo ufw route allow in on virbr0
  sudo ufw route allow out on virbr0

  mkdir -p "$HOME/.config/libvirt"
  printf 'uri_default = "qemu:///system"\n' >"$HOME/.config/libvirt/libvirt.conf"
}

fix_screen_tearing() {
  sudo install -Dm644 \
    "$SCRIPT_DIR/fix-screen-tearing/20-amd-gpu.conf" \
    /etc/X11/xorg.conf.d/20-amd-gpu.conf
}

setup_oom_protection() {
  # dwm apps share one session cgroup, so systemd-oomd could kill the whole X session.
  sudo install -Dm644 "$SCRIPT_DIR/static/earlyoom/earlyoom" /etc/default/earlyoom
  sudo install -Dm644 "$SCRIPT_DIR/static/zram/zram-generator.conf" /etc/systemd/zram-generator.conf
  sudo systemctl daemon-reload
  sudo systemctl enable earlyoom.service
  sudo systemctl restart earlyoom.service
  # shortcut: start is a no-op if zram0 is already active, so a resize waits for the next reboot.
  sudo systemctl start systemd-zram-setup@zram0.service
}

print_summary() {
  if ((${#failed[@]})); then
    printf '\nThese entries failed to install: %s\n' "${failed[*]}" >&2
  fi
  printf '\nDocker and libvirt group membership was added for %s; log out and back in to use them without sudo.\n' "$USER"
}

main() {
  check_not_root
  keep_sudo_alive
  configure_pacman
  install_prerequisites
  install_paru
  installation_loop
  deploy_dotfiles
  setup_firefox
  setup_wallpaper
  setup_gtk_theme
  setup_ufw
  setup_docker
  setup_kvm
  fix_screen_tearing
  setup_oom_protection
  print_summary
}

main "$@"
