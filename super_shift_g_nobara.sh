#!/bin/bash
set -Euo pipefail
# Ensure critical files are created even if the script aborts via set -e
trap 'if [[ "$(id -u)" == "0" ]] && type ensure_critical_permissions &>/dev/null; then ensure_critical_permissions 2>/dev/null; fi' EXIT

Super_Shift_S_VERSION="13.00-fedora-kde"

CONFIG_FILE="/etc/gaming-mode.conf"
[[ -f "$HOME/.gaming-mode.conf" ]] && CONFIG_FILE="$HOME/.gaming-mode.conf"
source "$CONFIG_FILE" 2>/dev/null || true
: "${PERFORMANCE_MODE:=enabled}"

NEEDS_RELOGIN=0
NEEDS_REBOOT=0

info(){ echo "[*] $*"; }
warn(){ echo "[!] $*"; }
err(){ echo "[!] $*" >&2; }

die() {
  local msg="$1"; local code="${2:-1}"
  echo "FATAL: $msg" >&2
  logger -t gaming-mode "Installation failed: $msg"
  exit "$code"
}

dnf_fix_and_retry() {
  local -a packages=("$@")
  local attempt=0
  local max_attempts=3

  info "Cleaning dnf cache and metadata..."
  sudo dnf clean all 2>/dev/null || true

  info "Retrying package install..."
  sudo dnf makecache 2>/dev/null || true
  if sudo dnf install -y "${packages[@]}" 2>/dev/null; then
    info "Packages installed successfully on retry"
    return 0
  fi

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    warn "Retry attempt $attempt/$max_attempts..."

    sudo dnf clean all 2>/dev/null || true
    sudo dnf makecache 2>/dev/null || true

    if sudo dnf install -y --best --allowerasing "${packages[@]}" 2>/dev/null; then
      info "Packages installed successfully on attempt $attempt"
      return 0
    fi

    if sudo dnf install -y --skip-broken "${packages[@]}" 2>/dev/null; then
      info "Packages installed (some may have been skipped) on attempt $attempt"
      return 0
    fi
  done

  warn "Bulk install failed - trying packages individually..."
  local -a still_missing=()
  for pkg in "${packages[@]}"; do
    if ! check_package "$pkg"; then
      if ! sudo dnf install -y "$pkg" 2>/dev/null; then
        still_missing+=("$pkg")
      fi
    fi
  done

  if ((${#still_missing[@]})); then
    err "Failed to install ${#still_missing[@]} package(s) after all retry attempts:"
    for pkg in "${still_missing[@]}"; do
      echo "    - $pkg"
    done
    return 1
  fi

  info "All packages installed (individually)"
  return 0
}

validate_environment() {
  command -v dnf >/dev/null || die "dnf required (not a Fedora-based system)"

  # Check for KDE Plasma / Wayland session
  local de_ok=false
  if [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]] || \
     command -v plasmashell >/dev/null 2>&1 || \
     command -v kwin_wayland >/dev/null 2>&1 || \
     pgrep -x plasmashell >/dev/null 2>&1; then
    de_ok=true
  fi
  if [[ "$de_ok" != "true" ]]; then
    warn "KDE Plasma session not detected (XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset})"
    warn "This script is designed for Fedora with KDE Plasma desktop"
    read -p "Continue anyway? [y/N]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || die "Aborting - KDE Plasma desktop not detected"
  fi

  # Check for plasmalogin display manager (Nobara)
  if ! systemctl list-unit-files plasmalogin.service &>/dev/null || \
     ! systemctl list-unit-files plasmalogin.service 2>/dev/null | grep -q plasmalogin; then
    warn "plasmalogin not detected - session switching requires plasmalogin"
    read -p "Continue anyway? [y/N]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || die "Aborting - plasmalogin not detected"
  fi

  [ -d "$HOME/.config" ] || mkdir -p "$HOME/.config"
}

check_package() { rpm -q "$1" &>/dev/null; }

is_amd_igpu_card() {
  local card_path="$1"
  local device_path="$card_path/device"
  local pci_slot=""
  [[ -L "$device_path" ]] && pci_slot=$(basename "$(readlink -f "$device_path")")
  [[ -z "$pci_slot" ]] && return 1
  local device_info=$(/usr/bin/lspci -s "$pci_slot" 2>/dev/null)
  if echo "$device_info" | grep -iqE 'renoir|cezanne|barcelo|rembrandt|phoenix|raphael|lucienne|picasso|raven|vega.*mobile|vega.*integrated|radeon.*graphics|yellow.*carp|green.*sardine|cyan.*skillfish|vangogh|van gogh|mendocino|hawk.*point|strix.*point|strix.*halo|krackan|sarlak'; then
    return 0
  fi
  if echo "$device_info" | grep -iqE 'radeon rx|navi [0-9]|navi[0-9]|vega 56|vega 64|radeon vii|radeon pro|firepro|polaris|ellesmere|baffin|lexa|radeon [0-9]{3,4}[^0-9]'; then
    return 1
  fi
  return 1
}

check_intel_only() {
  local card_name driver driver_link
  local has_intel=false
  local has_amd_nvidia=false

  for card_path in /sys/class/drm/card[0-9]*; do
    card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    driver=$(basename "$(readlink "$driver_link")")

    case "$driver" in
      i915|xe)
        has_intel=true
        ;;
      nvidia|amdgpu)
        has_amd_nvidia=true
        ;;
    esac
  done

  if $has_intel && ! $has_amd_nvidia; then
    return 0
  fi
  return 1
}

detect_dgpu_monitors() {
  local -n _monitors=$1
  local -n _dgpu_card=$2
  local -n _dgpu_type=$3
  _monitors=()
  _dgpu_card=""
  _dgpu_type=""

  # GPU selection priority: NVIDIA dGPU > AMD dGPU > AMD iGPU (APU)
  # Intel GPUs (iGPU and Arc) are NEVER selected — i915/xe drivers are skipped.
  #
  # Pass 1: collect all candidate cards by priority tier
  local -a nvidia_cards=()
  local -a amd_dgpu_cards=()
  local -a amd_igpu_cards=()

  for card_path in /sys/class/drm/card[0-9]*; do
    local card_name=$(basename "$card_path")
    [[ "$card_name" == render* ]] && continue
    local driver_link="$card_path/device/driver"
    [[ -L "$driver_link" ]] || continue
    local driver=$(basename "$(readlink "$driver_link")")

    case "$driver" in
      nvidia)
        nvidia_cards+=("$card_path")
        ;;
      amdgpu)
        if is_amd_igpu_card "$card_path"; then
          amd_igpu_cards+=("$card_path")
        else
          amd_dgpu_cards+=("$card_path")
        fi
        ;;
      i915|xe)
        # Intel iGPU and Arc dGPU — explicitly skip, never select
        ;;
    esac
  done

  # Pass 2: select best GPU by priority
  local selected_path=""
  if [[ ${#nvidia_cards[@]} -gt 0 ]]; then
    selected_path="${nvidia_cards[0]}"
    _dgpu_type="NVIDIA"
  elif [[ ${#amd_dgpu_cards[@]} -gt 0 ]]; then
    selected_path="${amd_dgpu_cards[0]}"
    _dgpu_type="AMD dGPU"
  elif [[ ${#amd_igpu_cards[@]} -gt 0 ]]; then
    selected_path="${amd_igpu_cards[0]}"
    _dgpu_type="AMD APU"
  fi

  if [[ -z "$selected_path" ]]; then
    return
  fi

  # Pass 3: enumerate connected monitors on the selected GPU
  local card_name=$(basename "$selected_path")
  _dgpu_card="$card_name"

  for connector in "$selected_path"/"$card_name"-*/status; do
    [[ -f "$connector" ]] || continue
    local conn_dir=$(dirname "$connector")
    local conn_name=$(basename "$conn_dir")
    conn_name=${conn_name#card*-}
    [[ "$conn_name" == Writeback* ]] && continue
    local status=$(cat "$connector" 2>/dev/null)
    if [[ "$status" == "connected" ]]; then
      local resolution=""
      local mode_file="$conn_dir/modes"
      [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
      _monitors+=("$conn_name|$resolution")
    fi
  done
}

check_nvidia_kernel_params() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  NVIDIA KERNEL PARAMETER CHECK"
  echo "================================================================"
  echo ""

  if grep -qE "nvidia[-_]drm\.modeset=1" /proc/cmdline 2>/dev/null; then
    info "nvidia-drm.modeset=1 is already configured"
    return 0
  fi

  warn "nvidia-drm.modeset=1 is NOT SET - required for Gaming Mode!"
  echo ""

  if [ -f /etc/default/grub ]; then
    echo ""
    read -p "Add nvidia-drm.modeset=1 to GRUB config? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      configure_grub_nvidia
    else
      warn "Skipping - you'll need to add nvidia-drm.modeset=1 manually"
      show_manual_nvidia_instructions
    fi
  else
    warn "Could not find /etc/default/grub"
    show_manual_nvidia_instructions
  fi
}

configure_grub_nvidia() {
  local grub_default="/etc/default/grub"

  info "Backing up GRUB config..."
  sudo cp "$grub_default" "${grub_default}.backup.$(date +%Y%m%d%H%M%S)" || {
    err "Failed to backup GRUB config"
    return 1
  }

  info "Adding nvidia-drm.modeset=1 to GRUB..."

  if ! grep -q "nvidia-drm.modeset=1" "$grub_default"; then
    sudo sed -i 's/\(GRUB_CMDLINE_LINUX="[^"]*\)/\1 nvidia-drm.modeset=1/' "$grub_default"

    if grep -q "nvidia-drm.modeset=1" "$grub_default"; then
      info "Regenerating GRUB config..."
      sudo grub2-mkconfig -o /boot/grub2/grub.cfg || {
        err "Failed to regenerate GRUB config"
        return 1
      }
      info "Successfully configured GRUB for NVIDIA"
      NEEDS_REBOOT=1
    else
      err "Failed to add parameter to GRUB"
      show_manual_nvidia_instructions
    fi
  fi
}

show_manual_nvidia_instructions() {
  cat <<'MSG'
  Manual configuration required:
  Fedora (GRUB2): Add nvidia-drm.modeset=1 to GRUB_CMDLINE_LINUX in /etc/default/grub
  Then run: sudo grub2-mkconfig -o /boot/grub2/grub.cfg
MSG
  warn "Gaming Mode may not work correctly without nvidia-drm.modeset=1"
}

install_nvidia_deckmode_env() {
  local lspci_output
  lspci_output=$(/usr/bin/lspci 2>/dev/null)
  if ! echo "$lspci_output" | grep -qi nvidia; then
    info "No NVIDIA detected; skipping NVIDIA Deck-mode env."
    return 0
  fi

  local env_file="/etc/environment.d/90-nvidia-gamescope.conf"

  if [ -f "$env_file" ]; then
    info "NVIDIA gamescope env already present: $env_file"
    return 0
  fi

  info "Installing NVIDIA gamescope env (Deck-mode style)..."
  sudo mkdir -p /etc/environment.d

  sudo tee "$env_file" >/dev/null <<'EOF'
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only
EOF

  info "Installed $env_file"
  NEEDS_RELOGIN=1
}

check_steam_dependencies() {
  info "Checking Steam dependencies for Fedora..."

  info "Updating package database..."
  if ! sudo dnf makecache; then
    warn "dnf makecache had errors - cleaning cache and retrying..."
    sudo dnf clean all
    sudo dnf makecache || warn "dnf makecache still has errors - continuing with available data"
  fi

  echo ""
  echo "================================================================"
  echo "  SYSTEM UPDATE RECOMMENDED"
  echo "================================================================"
  echo ""
  echo "  It's recommended to upgrade your system before installing"
  echo "  gaming dependencies to avoid package version conflicts."
  echo ""
  read -p "Upgrade system now? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    info "Upgrading system..."
    if ! sudo dnf upgrade -y; then
      warn "Upgrade failed - attempting to fix..."
      sudo dnf clean all
      sudo dnf makecache 2>/dev/null || true
      if ! sudo dnf upgrade -y --best --allowerasing 2>/dev/null; then
        warn "Upgrade still failing - continuing with package installation"
        warn "Package conflicts will be resolved during dependency install"
      fi
    fi
  fi
  echo ""

  local -a missing_deps=()
  local -a optional_deps=()

  if ! command -v lspci >/dev/null 2>&1; then
    info "Installing pciutils for GPU detection..."
    sudo dnf install -y pciutils || { dnf_fix_and_retry pciutils || die "Failed to install pciutils"; }
  fi

  # No dpkg --add-architecture needed on Fedora; multilib is handled
  # by installing .i686 packages directly. Ensure the repo is available.
  info "Multilib support: Fedora handles 32-bit via .i686 packages natively"

  local -a core_deps=(
    "steam"
    "vulkan-loader"
    "vulkan-loader.i686"
    "mesa-dri-drivers"
    "mesa-dri-drivers.i686"
    "glx-utils"
    "glibc.i686"
    "libgcc.i686"
    "libX11.i686"
    "libXScrnSaver.i686"
    "alsa-plugins-pulseaudio.i686"
    "pulseaudio-libs.i686"
    "openal-soft.i686"
    "nss.i686"
    "cups-libs.i686"
    "sdl2-compat.i686"
    "freetype.i686"
    "fontconfig.i686"
    "NetworkManager-libnm.i686"
    "NetworkManager"
    "gamemode"
    "gamemode.i686"
    "liberation-fonts-all"
    "xdg-user-dirs"
  )

  local gpu_vendor
  gpu_vendor=$(/usr/bin/lspci 2>/dev/null | grep -iE 'vga|3d|display' || echo "")

  local has_nvidia=false has_amd=false

  if echo "$gpu_vendor" | grep -qi nvidia; then
    has_nvidia=true
    info "Detected NVIDIA GPU"
  fi
  if echo "$gpu_vendor" | grep -iqE 'amd|radeon|advanced micro'; then
    has_amd=true
    info "Detected AMD GPU"
  fi
  if echo "$gpu_vendor" | grep -iq intel; then
    info "Detected Intel GPU (iGPU/Arc); Intel is not supported for Gaming Mode — skipping"
  fi

  local primary_gpu="unknown"
  if $has_nvidia; then
    primary_gpu="nvidia"
  elif $has_amd; then
    primary_gpu="amd"
  fi

  PRIMARY_GPU="$primary_gpu"
  info "Primary GPU selection: $PRIMARY_GPU"

  local -a gpu_deps=()

  if $has_nvidia; then
    # Detect installed NVIDIA driver on Fedora (RPM Fusion akmod-nvidia or nvidia-driver)
    local nvidia_installed=false
    if rpm -qa 'nvidia-driver*' 2>/dev/null | grep -q nvidia-driver; then
      nvidia_installed=true
    elif rpm -qa 'akmod-nvidia*' 2>/dev/null | grep -q akmod-nvidia; then
      nvidia_installed=true
    fi

    local nvidia_ver=""
    nvidia_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)
    [[ -n "$nvidia_ver" ]] && info "NVIDIA driver version detected: $nvidia_ver"

    # Nobara uses nvidia-driver instead of xorg-x11-drv-nvidia
    if ! check_package "nvidia-driver" && ! check_package "xorg-x11-drv-nvidia"; then
      gpu_deps+=("nvidia-driver")
    fi
    if ! check_package "nvidia-driver-libs.i686" && ! check_package "xorg-x11-drv-nvidia-libs.i686"; then
      gpu_deps+=("nvidia-driver-libs.i686")
    fi
    if ! check_package "nvidia-settings"; then
      gpu_deps+=("nvidia-settings")
    fi
  fi

  if $has_amd; then
    gpu_deps+=("vulkan-loader" "libvdpau" "libvdpau.i686")
    # Nobara uses mesa-vulkan-drivers-freeworld instead of mesa-vulkan-drivers
    if ! check_package "mesa-vulkan-drivers-freeworld"; then
      if ! check_package "mesa-vulkan-drivers"; then
        gpu_deps+=("mesa-vulkan-drivers-freeworld")
      fi
    fi
    if ! check_package "mesa-vulkan-drivers-freeworld.i686"; then
      if ! check_package "mesa-vulkan-drivers.i686"; then
        gpu_deps+=("mesa-vulkan-drivers-freeworld.i686")
      fi
    fi
  fi

  if ! $has_nvidia && ! $has_amd; then
    info "No NVIDIA/AMD GPU detected; installing Vulkan drivers as fallback..."
    if ! check_package "mesa-vulkan-drivers-freeworld" && ! check_package "mesa-vulkan-drivers"; then
      gpu_deps+=("mesa-vulkan-drivers-freeworld")
    fi
    if ! check_package "mesa-vulkan-drivers-freeworld.i686" && ! check_package "mesa-vulkan-drivers.i686"; then
      gpu_deps+=("mesa-vulkan-drivers-freeworld.i686")
    fi
  fi

  gpu_deps+=("vulkan-tools")
  # Add mesa vulkan drivers if neither variant is installed
  if ! check_package "mesa-vulkan-drivers-freeworld" && ! check_package "mesa-vulkan-drivers"; then
    gpu_deps+=("mesa-vulkan-drivers-freeworld")
  fi

  local -a recommended_deps=(
    "udisks2"
    "libnotify"
  )

  info "Checking core Steam dependencies..."
  for dep in "${core_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking GPU-specific dependencies..."
  for dep in "${gpu_deps[@]}"; do
    if ! check_package "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  info "Checking recommended dependencies..."
  for dep in "${recommended_deps[@]}"; do
    if ! check_package "$dep"; then
      optional_deps+=("$dep")
    fi
  done

  echo ""
  echo "================================================================"
  echo "  STEAM DEPENDENCY CHECK RESULTS"
  echo "================================================================"
  echo ""

  # Remove duplicates from missing_deps
  local -a clean_missing=()
  local -A seen_deps=()
  for item in "${missing_deps[@]}"; do
    if [[ -n "$item" && -z "${seen_deps[$item]:-}" ]]; then
      clean_missing+=("$item")
      seen_deps[$item]=1
    fi
  done
  missing_deps=("${clean_missing[@]+"${clean_missing[@]}"}")

  if ((${#missing_deps[@]})); then
    echo "  MISSING REQUIRED PACKAGES (${#missing_deps[@]}):"
    for dep in "${missing_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install missing required packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      info "Installing missing dependencies..."
      if ! sudo dnf install -y "${missing_deps[@]}"; then
        warn "Initial install failed - attempting recovery..."
        if ! dnf_fix_and_retry "${missing_deps[@]}"; then
          local -a final_missing=()
          for dep in "${missing_deps[@]}"; do
            check_package "$dep" || final_missing+=("$dep")
          done
          if ((${#final_missing[@]})); then
            err "Could not install ${#final_missing[@]} required package(s):"
            for dep in "${final_missing[@]}"; do
              echo "    - $dep"
            done
            echo ""
            echo "  Possible fixes:"
            echo "    1. Check your internet connection"
            echo "    2. Try: sudo dnf clean all && sudo dnf makecache"
            echo "    3. Ensure RPM Fusion repos are enabled (for Steam/NVIDIA)"
            echo "    4. Run: sudo dnf distro-sync --best --allowerasing"
            echo ""
            read -p "Continue anyway with partial install? [y/N]: " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || die "Missing required Steam dependencies"
            warn "Continuing with partial install - some features may not work"
          else
            info "All required packages eventually installed (after recovery)"
          fi
        fi
      else
        info "Required dependencies installed successfully"
      fi
    else
      die "Missing required Steam dependencies"
    fi
  else
    info "All required Steam dependencies are installed!"
  fi

  echo ""
  if ((${#optional_deps[@]})); then
    echo "  RECOMMENDED PACKAGES (${#optional_deps[@]}):"
    for dep in "${optional_deps[@]}"; do
      echo "    - $dep"
    done
    echo ""

    read -p "Install recommended packages? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Installing recommended packages..."
      if ! sudo dnf install -y "${optional_deps[@]}" 2>/dev/null; then
        warn "Some recommended packages failed - attempting recovery..."
        dnf_fix_and_retry "${optional_deps[@]}" || warn "Some recommended packages could not be installed"
      fi
    fi
  else
    info "All recommended packages are already installed!"
  fi

  echo ""
  echo "================================================================"

  check_steam_config
}

check_steam_config() {
  info "Checking Steam configuration..."

  local missing_groups=()

  if ! groups | grep -qw 'video'; then
    missing_groups+=("video")
  fi

  if ! groups | grep -qw 'input'; then
    missing_groups+=("input")
  fi

  if ! groups | grep -qw 'wheel'; then
    missing_groups+=("wheel")
  fi

  if ((${#missing_groups[@]})); then
    echo ""
    echo "================================================================"
    echo "  USER GROUP PERMISSIONS"
    echo "================================================================"
    echo ""
    echo "  Your user needs to be added to the following groups:"
    echo ""
    for group in "${missing_groups[@]}"; do
      case "$group" in
        video) echo "    - video  - Required for GPU hardware access" ;;
        input) echo "    - input  - Required for controller/gamepad support" ;;
        wheel) echo "    - wheel  - Required for NetworkManager control in gaming mode" ;;
      esac
    done
    echo ""
    echo "  NOTE: After adding groups, you MUST log out and log back in"
    echo ""
    read -p "Add user to ${missing_groups[*]} group(s)? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      local groups_to_add=$(IFS=,; echo "${missing_groups[*]}")
      info "Adding user to groups: $groups_to_add"
      if sudo usermod -aG "$groups_to_add" "$USER"; then
        info "Successfully added user to group(s): $groups_to_add"
        NEEDS_RELOGIN=1
      else
        err "Failed to add user to groups"
      fi
    fi
  else
    info "User is in video, input, and wheel groups - permissions OK"
  fi

  if [ -d "$HOME/.steam" ]; then
    info "Steam directory found at ~/.steam"
  fi

  if [ -d "$HOME/.local/share/Steam" ]; then
    info "Steam data directory found at ~/.local/share/Steam"
  fi

  # Check if Steam client is actually bootstrapped
  if check_package "steam"; then
    local steam_bin=""
    if [[ -x /usr/bin/steam ]]; then
      steam_bin="/usr/bin/steam"
    elif command -v steam >/dev/null 2>&1; then
      steam_bin="$(command -v steam)"
    fi

    if [[ -n "$steam_bin" ]] && [[ ! -f "$HOME/.local/share/Steam/ubuntu12_32/steam" ]]; then
      echo ""
      echo "================================================================"
      echo "  STEAM CLIENT BOOTSTRAP REQUIRED"
      echo "================================================================"
      echo ""
      echo "  The Steam package is installed, but the Steam client has not"
      echo "  completed its first-run download (~400MB)."
      echo ""
      echo "  Steam will now launch to download and install the client."
      echo "  Once the login screen appears, you can close it or log in."
      echo ""
      read -p "Bootstrap Steam client now? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        info "Launching Steam to bootstrap client (this may take a few minutes)..."
        $steam_bin &
        local steam_pid=$!
        info "Steam launched (PID: $steam_pid) - waiting for bootstrap to complete..."

        local wait_count=0
        while [[ ! -f "$HOME/.local/share/Steam/ubuntu12_32/steam" ]] && ((wait_count < 120)); do
          sleep 5
          ((wait_count++))
          if ! kill -0 "$steam_pid" 2>/dev/null; then
            sleep 3
            if [[ -f "$HOME/.local/share/Steam/ubuntu12_32/steam" ]]; then
              break
            fi
            local new_pid
            new_pid=$(pgrep -f "steam" 2>/dev/null | head -1)
            if [[ -n "$new_pid" ]]; then
              steam_pid="$new_pid"
            else
              break
            fi
          fi
        done

        if [[ -f "$HOME/.local/share/Steam/ubuntu12_32/steam" ]]; then
          info "Steam client bootstrapped successfully!"
        else
          warn "Steam bootstrap may not have completed - you may need to run 'steam' manually"
        fi

        echo ""
        echo "  You can now log into Steam or close it."
        echo "  The installer will continue once you press Enter."
        echo ""
        read -r -p "Press Enter to continue..."

        pkill -f steam 2>/dev/null || true
        sleep 2
      else
        warn "Skipping Steam bootstrap - run 'steam' manually before using Gaming Mode"
      fi
    elif [[ -f "$HOME/.local/share/Steam/ubuntu12_32/steam" ]]; then
      info "Steam client is fully bootstrapped"
    fi
  fi
}

setup_performance_permissions() {
  local udev_rules_file="/etc/udev/rules.d/99-gaming-performance.rules"
  local sudoers_file="/etc/sudoers.d/gaming-mode-sysctl"
  local needs_setup=false

  if [ ! -f "$udev_rules_file" ] || [ ! -f "$sudoers_file" ]; then
    needs_setup=true
  fi

  if [ "$needs_setup" = false ]; then
    info "Performance permissions already configured"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  PERFORMANCE PERMISSIONS SETUP"
  echo "================================================================"
  echo ""
  echo "  To avoid sudo password prompts during gaming, we need to set"
  echo "  up permissions for CPU and GPU performance control."
  echo ""
  read -p "Set up passwordless performance controls? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping permissions setup"
    return 0
  fi

  if [ ! -f "$udev_rules_file" ]; then
    info "Creating udev rules for CPU/GPU performance control..."

    if sudo tee "$udev_rules_file" > /dev/null <<'UDEV_RULES'
KERNEL=="cpu[0-9]*", SUBSYSTEM=="cpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/devices/system/cpu/%k/cpufreq/scaling_governor"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/device/power_dpm_force_performance_level"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_boost_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_min_freq_mhz"
KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="i915", ACTION=="add", RUN+="/bin/chmod 666 /sys/class/drm/%k/gt_max_freq_mhz"
UDEV_RULES
    then
      info "Udev rules created successfully"
      sudo udevadm control --reload-rules || true
      sudo udevadm trigger --subsystem-match=cpu --subsystem-match=drm || true
    fi
  fi

  if [[ -f "$sudoers_file" ]]; then
    info "Performance sudoers already exist at $sudoers_file"
  else
    info "Creating sudoers rule for Performance Mode sysctl tuning..."

    if sudo tee "$sudoers_file" > /dev/null << 'SUDOERS_PERF'
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_autogroup_enabled=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_migration_cost_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_min_granularity_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_latency_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.swappiness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_background_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_writeback_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_expire_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_watches=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_instances=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.file-max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.rmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.wmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.split_lock_mitigate=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.max_map_count=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.compaction_proactiveness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.nmi_watchdog=*
%video ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS_PERF
    then
      sudo chmod 0440 "$sudoers_file"
      if sudo visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
        info "Performance sudoers created and validated successfully"
      else
        err "Sudoers syntax validation FAILED -- removing broken file"
        sudo rm -f "$sudoers_file"
        return 1
      fi
    else
      err "Failed to create performance sudoers file"
    fi
  fi

  local memlock_file="/etc/security/limits.d/99-gaming-memlock.conf"
  if [ ! -f "$memlock_file" ]; then
    info "Creating memlock limits for gaming performance..."
    if sudo tee "$memlock_file" > /dev/null << 'MEMLOCKCONF'
* soft memlock 2147484
* hard memlock 2147484
MEMLOCKCONF
    then
      info "Memlock limits configured (2GB)"
    fi
  fi

  local pipewire_conf_dir="/etc/pipewire/pipewire.conf.d"
  local pipewire_conf="$pipewire_conf_dir/10-gaming-latency.conf"
  if [ ! -f "$pipewire_conf" ]; then
    info "Creating PipeWire low-latency audio configuration..."
    sudo mkdir -p "$pipewire_conf_dir"
    if sudo tee "$pipewire_conf" > /dev/null << 'PIPEWIRECONF'
context.properties = {
    default.clock.min-quantum = 256
}
PIPEWIRECONF
    then
      info "PipeWire gaming latency configured"
    fi
  fi

  info "Performance permissions configured"
  return 0
}

setup_shader_cache() {
  local env_file="/etc/environment.d/99-shader-cache.conf"

  if [ -f "$env_file" ]; then
    info "Shader cache configuration already exists"
    return 0
  fi

  echo ""
  echo "================================================================"
  echo "  SHADER CACHE OPTIMIZATION"
  echo "================================================================"
  echo ""
  echo "  Configuring shader cache sizes for better gaming performance."
  echo "  This reduces stuttering in games by caching compiled shaders."
  echo ""
  read -p "Configure shader cache optimization? [Y/n]: " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping shader cache configuration"
    return 0
  fi

  info "Creating shader cache configuration..."
  sudo mkdir -p /etc/environment.d || { warn "Failed to create /etc/environment.d"; return 0; }
  local tmp_shader
  tmp_shader=$(mktemp) || { warn "Failed to create temp file"; return 0; }

  cat > "$tmp_shader" << 'SHADERCACHE'
MESA_SHADER_CACHE_MAX_SIZE=12G
MESA_SHADER_CACHE_DISABLE_CLEANUP=1
RADV_PERFTEST=gpl
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SIZE=12884901888
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
DXVK_STATE_CACHE=1
SHADERCACHE

  if sudo cp "$tmp_shader" "$env_file"; then
    rm -f "$tmp_shader"
    sudo chmod 644 "$env_file"
    info "Shader cache configured for all GPUs (AMD/NVIDIA + Proton)"
  else
    rm -f "$tmp_shader"
    warn "Failed to create shader cache configuration"
  fi
}

install_proton_ge() {
  echo ""
  echo "================================================================"
  echo "  PROTON GE (GloriousEggroll) INSTALLATION"
  echo "================================================================"
  echo ""

  local steam_root=""
  if [[ -d "$HOME/.local/share/Steam" ]]; then
    steam_root="$HOME/.local/share/Steam"
  elif [[ -L "$HOME/.steam/root" ]]; then
    steam_root="$(readlink -f "$HOME/.steam/root")"
  elif [[ -d "$HOME/.steam/debian-installation" ]]; then
    steam_root="$HOME/.steam/debian-installation"
  elif [[ -d "$HOME/.steam/steam" ]]; then
    steam_root="$HOME/.steam/steam"
  fi

  if [[ -z "$steam_root" || ! -d "$steam_root" ]]; then
    warn "Steam directory not found"
    warn "Run Steam at least once before installing Proton GE"
    return 0
  fi

  info "Steam installation found at: $steam_root"
  local compat_dir="$steam_root/compatibilitytools.d"

  local existing_ge=()
  if [[ -d "$compat_dir" ]]; then
    while IFS= read -r -d '' dir; do
      existing_ge+=("$(basename "$dir")")
    done < <(find "$compat_dir" -maxdepth 1 -type d -name "GE-Proton*" -print0 2>/dev/null | sort -zV)
  fi

  if ((${#existing_ge[@]})); then
    echo "  Existing Proton GE installations:"
    for ge in "${existing_ge[@]}"; do
      echo "    - $ge"
    done
    echo ""
  else
    echo "  No Proton GE versions currently installed."
    echo ""
  fi

  info "Checking latest Proton GE release..."
  local api_response
  api_response=$(curl -sL --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest" 2>/dev/null)

  if [[ -z "$api_response" ]]; then
    err "Failed to fetch Proton GE release info from GitHub"
    echo "  Check your internet connection and try again."
    return 1
  fi

  local latest_tag latest_url latest_sha_url
  latest_tag=$(echo "$api_response" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)
  latest_url=$(echo "$api_response" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.tar\.gz(?=")' | head -1)
  latest_sha_url=$(echo "$api_response" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+\.sha512sum(?=")' | head -1)

  if [[ -z "$latest_tag" || -z "$latest_url" ]]; then
    err "Could not parse Proton GE release info"
    return 1
  fi

  echo "  Latest release: $latest_tag"
  echo "  Download URL:   $latest_url"
  echo ""

  if [[ -d "$compat_dir/$latest_tag" ]]; then
    info "Proton GE $latest_tag is already installed!"
    read -p "Reinstall $latest_tag? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      return 0
    fi
    info "Removing existing $latest_tag installation..."
    rm -rf "${compat_dir:?}/$latest_tag"
  else
    read -p "Install Proton GE $latest_tag? [Y/n]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
      info "Skipping Proton GE installation"
      return 0
    fi
  fi

  mkdir -p "$compat_dir"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  local tarball="$tmp_dir/${latest_tag}.tar.gz"

  info "Downloading Proton GE $latest_tag (this may take a few minutes)..."
  if ! curl -L --progress-bar --connect-timeout 15 --max-time 600 \
    -o "$tarball" "$latest_url"; then
    err "Failed to download Proton GE"
    rm -rf "$tmp_dir"
    return 1
  fi

  if [[ -n "$latest_sha_url" ]]; then
    info "Verifying download checksum..."
    local sha_file="$tmp_dir/checksum.sha512sum"
    if curl -sL --connect-timeout 10 --max-time 30 -o "$sha_file" "$latest_sha_url" 2>/dev/null; then
      pushd "$tmp_dir" >/dev/null || true
      local expected_name
      expected_name=$(awk '{print $2}' "$sha_file" | tr -d '*')
      if [[ -n "$expected_name" && "$expected_name" != "${latest_tag}.tar.gz" ]]; then
        mv "$tarball" "$tmp_dir/$expected_name"
        tarball="$tmp_dir/$expected_name"
      fi
      if sha512sum -c "$sha_file" >/dev/null 2>&1; then
        info "Checksum verified OK"
      else
        warn "Checksum verification failed - file may be corrupt"
        read -p "Continue anyway? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          rm -rf "$tmp_dir"
          return 1
        fi
      fi
      popd >/dev/null || true
    else
      warn "Could not download checksum file - skipping verification"
    fi
  fi

  info "Extracting Proton GE $latest_tag..."
  if ! tar -xf "$tarball" -C "$compat_dir"; then
    err "Failed to extract Proton GE archive"
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir"

  if [[ -d "$compat_dir/$latest_tag" ]]; then
    info "Proton GE $latest_tag installed successfully to:"
    info "  $compat_dir/$latest_tag"
  else
    local extracted
    extracted=$(ls -td "$compat_dir"/GE-Proton* 2>/dev/null | head -1)
    if [[ -n "$extracted" ]]; then
      info "Proton GE installed successfully to:"
      info "  $extracted"
    else
      err "Extraction completed but Proton GE directory not found"
      return 1
    fi
  fi

  echo ""
  echo "  To use Proton GE in Steam:"
  echo "    1. Restart Steam (if running)"
  echo "    2. Right-click a game > Properties > Compatibility"
  echo "    3. Check 'Force the use of a specific Steam Play compatibility tool'"
  echo "    4. Select '$latest_tag' from the dropdown"
  echo ""

  if ((${#existing_ge[@]})); then
    echo "  You have ${#existing_ge[@]} other Proton GE version(s) installed."
    read -p "Remove old Proton GE versions? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      for old_ge in "${existing_ge[@]}"; do
        if [[ "$old_ge" != "$latest_tag" && -d "$compat_dir/$old_ge" ]]; then
          info "Removing $old_ge..."
          rm -rf "${compat_dir:?}/$old_ge"
        fi
      done
      info "Old Proton GE versions removed"
    fi
  fi

  return 0
}

install_mangoapp() {
  echo ""
  echo "================================================================"
  echo "  MANGOHUD + MANGOAPP INSTALLATION (from source)"
  echo "================================================================"
  echo ""

  # The repo version (0.6.9.1) is too old for gamescope 3.16.x+
  # It fails with "Couldn't create socket pipe at 'mangohud'"
  # Always build from source for compatibility

  # Check if we already have a source-built version at /usr/local
  if [[ -x /usr/local/bin/mangoapp ]]; then
    local mango_ver
    mango_ver=$(/usr/local/bin/mangohud --version 2>&1 | head -1 || echo "unknown")
    info "mangoapp already installed from source (MangoHud version: $mango_ver)"
    return 0
  fi

  # Remove repo versions if installed — they're incompatible with our gamescope
  if rpm -q mangoapp &>/dev/null; then
    info "Removing incompatible repo version of mangohud/mangoapp..."
    sudo dnf remove -y mangohud mangoapp 2>/dev/null || true
  fi

  install_mangoapp_from_source
}

install_mangoapp_from_source() {
  info "Building MangoHud from source to get mangoapp..."

  local -a mangohud_build_deps=(
    "meson"
    "ninja-build"
    "cmake"
    "pkgconf-pkg-config"
    "gcc-c++"
    "libstdc++-static"
    "git"
    "python3-mako"
    "glslang"
    "glew-devel"
    "glfw-devel"
    "libXNVCtrl-devel"
    "dbus-devel"
    "libX11-devel"
    "libxkbcommon-devel"
    "wayland-devel"
    "wayland-protocols-devel"
    "vulkan-loader-devel"
    "spdlog-devel"
    "fmt-devel"
    "appstream"
  )

  info "Installing MangoHud build dependencies..."
  if ! sudo dnf install -y "${mangohud_build_deps[@]}" 2>/dev/null; then
    warn "Some build dependencies failed to install - attempting recovery..."
    dnf_fix_and_retry "${mangohud_build_deps[@]}" || {
      warn "Some build dependencies could not be installed"
      warn "MangoHud build may fail - attempting anyway..."
    }
  fi

  local build_dir
  build_dir=$(mktemp -d)
  local mangohud_src="$build_dir/MangoHud"

  info "Cloning MangoHud from GitHub..."
  if ! git clone --recurse-submodules --depth 1 https://github.com/flightlessmango/MangoHud.git "$mangohud_src"; then
    err "Failed to clone MangoHud repository"
    rm -rf "$build_dir"
    return 1
  fi

  pushd "$mangohud_src" >/dev/null || { rm -rf "$build_dir"; return 1; }

  info "Configuring MangoHud build (with mangoapp)..."
  if ! meson setup build --prefix=/usr/local --buildtype=release \
    -Dwith_wayland=enabled \
    -Dwith_xnvctrl=enabled \
    -Dmangoapp=true \
    -Dmangohudctl=true; then
    err "Meson configure failed"
    popd >/dev/null || true
    rm -rf "$build_dir"
    return 1
  fi

  info "Building MangoHud (this may take a few minutes)..."
  if ! ninja -C build; then
    err "MangoHud build failed"
    popd >/dev/null || true
    rm -rf "$build_dir"
    return 1
  fi

  info "Installing MangoHud..."
  if ! sudo ninja -C build install; then
    err "MangoHud install failed"
    popd >/dev/null || true
    rm -rf "$build_dir"
    return 1
  fi

  sudo ldconfig

  popd >/dev/null || true
  rm -rf "$build_dir"

  if command -v mangoapp >/dev/null 2>&1 || [[ -x /usr/local/bin/mangoapp ]]; then
    info "mangoapp installed successfully at $(command -v mangoapp 2>/dev/null || echo /usr/local/bin/mangoapp)"
  else
    err "mangoapp binary not found after installation"
    return 1
  fi
}

install_gamescope_from_source() {
  echo ""
  echo "================================================================"
  echo "  GAMESCOPE INSTALLATION (from source)"
  echo "================================================================"
  echo ""

  if command -v gamescope >/dev/null 2>&1; then
    local gs_version
    gs_version=$(gamescope --version 2>&1 | head -1 || echo "unknown")
    info "gamescope already installed: $gs_version — skipping source build"
    return 0
  fi

  info "gamescope is not available in Fedora repos - building from source..."
  echo ""

  local -a build_deps=(
    "meson"
    "ninja-build"
    "cmake"
    "pkgconf-pkg-config"
    "gcc-c++"
    "glslang"
    "git"
    "libcap-devel"
    "libdrm-devel"
    "libinput-devel"
    "sdl2-compat-devel"
    "vulkan-loader-devel"
    "wayland-devel"
    "libX11-devel"
    "libX11-xcb"
    "libxcb-devel"
    "libXcomposite-devel"
    "libXcursor-devel"
    "libXdamage-devel"
    "libXext-devel"
    "libXfixes-devel"
    "libXi-devel"
    "libxkbcommon-devel"
    "libXmu-devel"
    "libXrender-devel"
    "libXres-devel"
    "libXtst-devel"
    "libXxf86vm-devel"
    "wayland-protocols-devel"
    "hwdata"
    "pipewire-devel"
    "libavif-devel"
    "libdecor-devel"
    "libdisplay-info-devel"
    "libei-devel"
    "libliftoff-devel"
    "luajit-devel"
    "pixman-devel"
    "stb_image-devel"
    "systemd-devel"
    "libseat-devel"
    "xcb-util-wm-devel"
    "xcb-util-image-devel"
    "xcb-util-renderutil-devel"
    "xcb-util-devel"
    "xorg-x11-server-Xwayland-devel"
    "lcms2-devel"
  )

  info "Installing build dependencies..."
  if ! sudo dnf install -y "${build_deps[@]}" 2>/dev/null; then
    warn "Some build dependencies failed to install - attempting recovery..."
    dnf_fix_and_retry "${build_deps[@]}" || {
      warn "Some build dependencies could not be installed"
      warn "Gamescope build may fail - attempting anyway..."
    }
  fi

  local build_dir
  build_dir=$(mktemp -d)
  local gamescope_src="$build_dir/gamescope"

  local gamescope_tag="3.14.24"
  local wayland_ver
  wayland_ver=$(pkg-config --modversion wayland-server 2>/dev/null || echo "0")
  if [[ "$(printf '%s\n' "1.23" "$wayland_ver" | sort -V | head -1)" == "1.23" ]]; then
    gamescope_tag=""
    info "wayland-server $wayland_ver >= 1.23 - building latest gamescope"
  else
    info "wayland-server $wayland_ver < 1.23 - pinning to gamescope $gamescope_tag"
  fi

  info "Cloning gamescope from GitHub..."
  if [[ -n "$gamescope_tag" ]]; then
    if ! git clone --recursive --branch "$gamescope_tag" --depth 1 https://github.com/ValveSoftware/gamescope.git "$gamescope_src"; then
      err "Failed to clone gamescope $gamescope_tag"
      rm -rf "$build_dir"
      return 1
    fi
  else
    if ! git clone --recursive https://github.com/ValveSoftware/gamescope.git "$gamescope_src"; then
      err "Failed to clone gamescope repository"
      rm -rf "$build_dir"
      return 1
    fi
  fi

  pushd "$gamescope_src" >/dev/null || { rm -rf "$build_dir"; return 1; }

  info "Configuring gamescope build..."
  if ! meson setup build --prefix=/usr/local --buildtype=release -Dpipewire=enabled; then
    err "Meson configure failed"
    popd >/dev/null || true
    rm -rf "$build_dir"
    return 1
  fi

  info "Building gamescope (this may take a few minutes)..."
  if ! ninja -C build; then
    err "Gamescope build failed"
    popd >/dev/null || true
    rm -rf "$build_dir"
    return 1
  fi

  info "Installing gamescope..."
  if ! sudo ninja -C build install; then
    err "Gamescope install failed"
    popd >/dev/null || true
    rm -rf "$build_dir"
    return 1
  fi

  popd >/dev/null || true
  rm -rf "$build_dir"

  if command -v gamescope >/dev/null 2>&1 || [[ -x /usr/local/bin/gamescope ]]; then
    info "gamescope installed successfully at $(command -v gamescope 2>/dev/null || echo /usr/local/bin/gamescope)"
  else
    err "gamescope binary not found after installation"
    return 1
  fi
}

install_chimera_session_scripts() {
  echo ""
  echo "================================================================"
  echo "  CHIMERAOS SESSION SCRIPTS (from source)"
  echo "================================================================"
  echo ""

  local install_dir="/usr/share/gamescope-session-plus"
  local needs_base=false
  local needs_steam=false

  if [[ ! -d "$install_dir" ]] || [[ ! -x "$install_dir/gamescope-session-plus" ]]; then
    needs_base=true
  fi

  local -a required_steam_scripts=(
    "/usr/bin/steamos-session-select"
    "/usr/bin/steamos-update"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-select-branch"
    "$install_dir/sessions.d/steam"
  )

  for script in "${required_steam_scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
      needs_steam=true
      break
    fi
  done

  if [[ "$needs_base" == "false" && "$needs_steam" == "false" ]]; then
    info "ChimeraOS session scripts already installed"
    return 0
  fi

  local build_dir
  build_dir=$(mktemp -d)

  if $needs_base; then
    info "Installing gamescope-session-plus from ChimeraOS..."
    if git clone https://github.com/ChimeraOS/gamescope-session.git "$build_dir/gamescope-session"; then
      pushd "$build_dir/gamescope-session" >/dev/null || true
      sudo mkdir -p "$install_dir"
      if [[ -f "gamescope-session-plus" ]]; then
        sudo cp gamescope-session-plus "$install_dir/gamescope-session-plus"
        sudo chmod 755 "$install_dir/gamescope-session-plus"
      elif [[ -f "usr/share/gamescope-session-plus/gamescope-session-plus" ]]; then
        sudo cp -r usr/share/gamescope-session-plus/* "$install_dir/"
        sudo chmod 755 "$install_dir/gamescope-session-plus"
      else
        find . -name "gamescope-session-plus" -type f | while read -r f; do
          sudo cp "$f" "$install_dir/gamescope-session-plus"
          sudo chmod 755 "$install_dir/gamescope-session-plus"
        done
      fi
      for f in gamescope-session-plus-*.sh; do
        [[ -f "$f" ]] && sudo cp "$f" "$install_dir/" && sudo chmod 755 "$install_dir/$f"
      done
      popd >/dev/null || true
      info "gamescope-session-plus installed"
    else
      err "Failed to clone gamescope-session repository"
    fi
  fi

  if $needs_steam; then
    info "Installing gamescope-session-steam scripts from ChimeraOS..."
    if git clone https://github.com/ChimeraOS/gamescope-session-steam.git "$build_dir/gamescope-session-steam"; then
      pushd "$build_dir/gamescope-session-steam" >/dev/null || true

      sudo mkdir -p "$install_dir/sessions.d"
      if [[ -f "usr/share/gamescope-session-plus/sessions.d/steam" ]]; then
        sudo cp "usr/share/gamescope-session-plus/sessions.d/steam" "$install_dir/sessions.d/steam"
        info "Installed sessions.d/steam config from repo"
      else
        warn "sessions.d/steam not found in repo - creating manually"
      fi

      # Always write our own sessions.d/steam with MangoHud fix
      # This ensures post_gamescope_start enables the overlay on non-SteamOS
      sudo tee "$install_dir/sessions.d/steam" > /dev/null << 'STEAM_SESSION_CONF'
#! /bin/bash

function short_session_recover {
    mkdir -p ~/.local/share/Steam
    rm -rf --one-file-system ~/.local/share/Steam/config/widevine
    steamos-session-select desktop
}

function post_gamescope_start {
    # Run steam-tweaks if exists
    if command -v steam-tweaks > /dev/null; then
        steam-tweaks
    fi

    # On non-SteamOS, Steam may not update the MangoHud config file.
    # Wait for Steam to initialize, then check if the config still has
    # 'no_display'. If so, replace it with a default overlay config.
    if [[ -n "$MANGOHUD_CONFIGFILE" ]]; then
        (sleep 15
         if grep -q "no_display" "$MANGOHUD_CONFIGFILE" 2>/dev/null; then
             cat > "$MANGOHUD_CONFIGFILE" << 'MHCFG'
fps
cpu_temp
gpu_temp
ram
vram
frametime
MHCFG
         fi
        ) &
    fi
}

export STEAM_GAMESCOPE_VRR_SUPPORTED=1
export STEAM_MANGOAPP_PRESETS_SUPPORTED=1
export STEAM_USE_MANGOAPP=1
export STEAM_USE_DYNAMIC_VRS=1
export STEAM_GAMESCOPE_HAS_TEARING_SUPPORT=1
export STEAM_GAMESCOPE_TEARING_SUPPORTED=1
export STEAM_GAMESCOPE_HDR_SUPPORTED=1
export STEAMOS_STEAM_REBOOT_SENTINEL="/tmp/steamos-reboot-sentinel"
export REBOOT_SENTINEL=$STEAMOS_STEAM_REBOOT_SENTINEL
export STEAMOS_STEAM_SHUTDOWN_SENTINEL="/tmp/steamos-shutdown-sentinel"
export SHUTDOWN_SENTINEL=$STEAMOS_STEAM_SHUTDOWN_SENTINEL
export STEAM_ENABLE_VOLUME_HANDLER=1
export SRT_URLOPEN_PREFER_STEAM=1
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
export STEAM_MULTIPLE_XWAYLANDS=1
export STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER=1
export STEAM_GAMESCOPE_NIS_SUPPORTED=1
export STEAM_ALLOW_DRIVE_UNMOUNT=1
export STEAM_DISABLE_MANGOAPP_ATOM_WORKAROUND=1
export STEAM_MANGOAPP_HORIZONTAL_SUPPORTED=1
export STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT=1
export STEAM_GAMESCOPE_COLOR_MANAGED=1
export STEAM_GAMESCOPE_VIRTUAL_WHITE=1
export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam

if [ -f "/usr/share/steamos/steamos.png" ] ; then
  export STEAM_UPDATEUI_PNG_BACKGROUND=/usr/share/steamos/steamos.png
fi

export CURSOR_FILE="${HOME}/.local/share/Steam/tenfoot/resource/images/cursors/arrow.png"
export CLIENTCMD="steam -gamepadui -steamos3 -steampal -steamdeck"
touch "${HOME}"/.steam/root/config/SteamAppData.vdf || true

if [[ -f "/etc/first-boot/bootstraplinux_ubuntu12_32.tar.xz" ]] && ! grep -q "set_bootstrap=1" "$STEAM_BOOTSTRAP_CONFIG"; then
    mkdir -p ~/.local/share/Steam
    tar xf /etc/first-boot/bootstraplinux_ubuntu12_32.tar.xz -C ~/.local/share/Steam
    echo "set_bootstrap=1" >> "$STEAM_BOOTSTRAP_CONFIG"
fi

# If we have steam_notif_daemon binary start it
if command -v steam_notif_daemon > /dev/null; then
    steam_notif_daemon &
fi
STEAM_SESSION_CONF
      sudo chmod 755 "$install_dir/sessions.d/steam"
      info "Installed sessions.d/steam config with MangoHud overlay fix"

      # Install Steam compatibility stubs
      for script_name in steamos-session-select steamos-update jupiter-biosupdate steamos-select-branch; do
        local src_file=""
        for candidate in "usr/bin/$script_name" "$script_name" "bin/$script_name"; do
          if [[ -f "$candidate" ]]; then
            src_file="$candidate"
            break
          fi
        done
        if [[ -n "$src_file" ]]; then
          sudo cp "$src_file" "/usr/bin/$script_name"
          sudo chmod 755 "/usr/bin/$script_name"
          info "Installed /usr/bin/$script_name"
        else
          info "Creating stub for $script_name..."
          case "$script_name" in
            steamos-session-select)
              sudo tee "/usr/bin/$script_name" > /dev/null << 'STUB_SELECT'
#!/bin/bash
# ChimeraOS compatibility stub for Steam (Fedora KDE)
case "$1" in
  desktop)
    exec /usr/lib/os-session-select
    ;;
  gamescope)
    echo "Already in gamescope session"
    ;;
  *)
    echo "Usage: $0 {desktop|gamescope}"
    ;;
esac
STUB_SELECT
              ;;
            steamos-update)
              sudo tee "/usr/bin/$script_name" > /dev/null << 'STUB_UPDATE'
#!/bin/bash
# ChimeraOS compatibility stub - no SteamOS updates on Fedora
echo "System updates are managed through Discover or dnf"
exit 0
STUB_UPDATE
              ;;
            jupiter-biosupdate)
              sudo tee "/usr/bin/$script_name" > /dev/null << 'STUB_BIOS'
#!/bin/bash
# ChimeraOS compatibility stub - not applicable on desktop
exit 0
STUB_BIOS
              ;;
            steamos-select-branch)
              sudo tee "/usr/bin/$script_name" > /dev/null << 'STUB_BRANCH'
#!/bin/bash
# ChimeraOS compatibility stub
echo "Branch selection not available on Fedora"
exit 0
STUB_BRANCH
              ;;
          esac
          sudo chmod 755 "/usr/bin/$script_name"
        fi
      done

      for f in gamescope-session-steam*.sh; do
        [[ -f "$f" ]] && sudo cp "$f" "$install_dir/" && sudo chmod 755 "$install_dir/$f"
      done

      popd >/dev/null || true
      info "gamescope-session-steam scripts installed"
    else
      err "Failed to clone gamescope-session-steam repository"
    fi
  fi

  rm -rf "$build_dir"
}

setup_requirements() {
  local -a required_packages=("steam" "libcap" "gamemode" "curl" "pciutils" "ntfs-3g")
  local -a packages_to_install=()
  for pkg in "${required_packages[@]}"; do
    check_package "$pkg" || packages_to_install+=("$pkg")
  done

  if ((${#packages_to_install[@]})); then
    info "The following packages are required: ${packages_to_install[*]}"
    read -p "Install missing packages? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      if ! sudo dnf install -y "${packages_to_install[@]}"; then
        warn "Initial install failed - attempting recovery..."
        if ! dnf_fix_and_retry "${packages_to_install[@]}"; then
          local -a still_needed=()
          for pkg in "${packages_to_install[@]}"; do
            check_package "$pkg" || still_needed+=("$pkg")
          done
          if ((${#still_needed[@]})); then
            err "Could not install: ${still_needed[*]}"
            read -p "Continue anyway? [y/N]: " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || die "Required packages missing - cannot continue"
          fi
        fi
      fi
    else
      die "Required packages missing - cannot continue"
    fi
  else
    info "All required packages present."
  fi

  setup_performance_permissions
  setup_shader_cache

  # Build/install gamescope from source
  install_gamescope_from_source

  # Install mangoapp (try repos first, fallback to source build)
  if ! command -v mangoapp >/dev/null 2>&1 && ! [[ -x /usr/local/bin/mangoapp ]]; then
    install_mangoapp
  fi

  # Install ChimeraOS session scripts from source
  install_chimera_session_scripts

  # Install Proton GE for better game compatibility
  install_proton_ge

  local gamescope_bin=""
  if command -v gamescope >/dev/null 2>&1; then
    gamescope_bin="$(command -v gamescope)"
  elif [[ -x /usr/local/bin/gamescope ]]; then
    gamescope_bin="/usr/local/bin/gamescope"
  fi

  if [[ "${PERFORMANCE_MODE,,}" == "enabled" ]] && [[ -n "$gamescope_bin" ]]; then
    if ! getcap "$gamescope_bin" 2>/dev/null | grep -q 'cap_sys_nice'; then
      echo ""
      echo "================================================================"
      echo "  GAMESCOPE CAPABILITY REQUEST"
      echo "================================================================"
      echo ""
      echo "  Performance mode requires granting cap_sys_nice to gamescope."
      echo ""
      read -p "Grant cap_sys_nice to gamescope? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sudo setcap 'cap_sys_nice=eip' "$gamescope_bin" || warn "Failed to set capability"
        info "Capability granted to gamescope"
      fi
    fi
  fi
}

# Detect the KDE Plasma session name from available .desktop files
detect_kde_session_name() {
  local session_name="plasma"
  # Check wayland sessions first (preferred)
  if [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
    session_name="plasma"
  elif [[ -f /usr/share/wayland-sessions/plasmawayland.desktop ]]; then
    session_name="plasmawayland"
  # Fallback to X11
  elif [[ -f /usr/share/xsessions/plasma.desktop ]]; then
    session_name="plasma"
  elif [[ -f /usr/share/xsessions/plasmax11.desktop ]]; then
    session_name="plasmax11"
  fi
  echo "$session_name"
}

setup_kde_shortcut() {
  local user_home="$1"
  local current_user="${SUDO_USER:-$USER}"

  info "Setting up KDE Plasma global shortcut for Gaming Mode..."

  # Create a .desktop file for the switch-to-gaming action
  local desktop_dir="/usr/share/applications"
  local desktop_file="$desktop_dir/switch-to-gaming.desktop"

  sudo tee "$desktop_file" > /dev/null << 'DESKTOP_ENTRY'
[Desktop Entry]
Type=Application
Name=Switch to Gaming Mode
Comment=Switch from KDE Plasma to Gaming Mode (Gamescope)
Exec=/usr/local/bin/switch-to-gaming
Icon=input-gaming
NoDisplay=true
Terminal=false
Categories=Game;
X-KDE-Shortcuts=Meta+Alt+G
DESKTOP_ENTRY

  sudo chmod 644 "$desktop_file"
  info "Created $desktop_file"

  # Update the desktop database so KDE discovers the new .desktop file
  if command -v update-desktop-database >/dev/null 2>&1; then
    sudo update-desktop-database "$desktop_dir" 2>/dev/null || true
  fi

  # Register the global shortcut in KDE's kglobalshortcutsrc
  # This matches the working CachyOS approach exactly:
  # 1. kwriteconfig to write the shortcut to the config file
  # 2. kbuildsycoca to discover the .desktop file
  # 3. Tell KWin to reconfigure (picks up the new shortcut)
  local kwriteconfig=""
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig="kwriteconfig6"
  elif command -v kwriteconfig5 >/dev/null 2>&1; then
    kwriteconfig="kwriteconfig5"
  fi

  if [[ -n "$kwriteconfig" ]]; then
    sudo -u "$current_user" "$kwriteconfig" --file kglobalshortcutsrc \
      --group "switch-to-gaming.desktop" \
      --key "_k_friendly_name" "Switch to Gaming Mode"
    sudo -u "$current_user" "$kwriteconfig" --file kglobalshortcutsrc \
      --group "switch-to-gaming.desktop" \
      --key "_launch" "Meta+Alt+G,none,Switch to Gaming Mode"
    info "Registered shortcut via $kwriteconfig"
  else
    # Fallback: manually append to kglobalshortcutsrc
    local shortcuts_file="${user_home}/.config/kglobalshortcutsrc"

    if [[ -f "$shortcuts_file" ]]; then
      if grep -q "\[switch-to-gaming.desktop\]" "$shortcuts_file" 2>/dev/null; then
        info "Gaming Mode shortcut already exists in kglobalshortcutsrc"
      fi
    fi

    # Ensure file ends with a newline before appending
    if [[ -f "$shortcuts_file" ]] && [[ -s "$shortcuts_file" ]]; then
      [[ "$(tail -c1 "$shortcuts_file")" != "" ]] && echo "" >> "$shortcuts_file"
    fi

    cat >> "$shortcuts_file" << 'KDE_SHORTCUT'

[switch-to-gaming.desktop]
_k_friendly_name=Switch to Gaming Mode
_launch=Meta+Alt+G,none,Switch to Gaming Mode
KDE_SHORTCUT

    info "Added Super+Alt+G shortcut to KDE global shortcuts (manual fallback)"
  fi

  # Rebuild KDE's sycoca cache so it picks up the new .desktop file and shortcut
  if command -v kbuildsycoca6 >/dev/null 2>&1; then
    sudo -u "$current_user" kbuildsycoca6 2>/dev/null || true
  elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    sudo -u "$current_user" kbuildsycoca5 2>/dev/null || true
  fi

  # Tell KWin to reconfigure so it picks up the new shortcut immediately
  # On Fedora Plasma 6, kglobalaccel is embedded in KWin, so we reconfigure KWin
  if command -v dbus-send >/dev/null 2>&1; then
    sudo -u "$current_user" dbus-send --session --type=method_call \
      --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
    info "Sent reconfigure signal to KWin"
  fi

  info "KDE shortcut configuration complete"
  echo "  NOTE: You MUST log out and back in for the shortcut to activate."
  echo "  You can also set it manually in System Settings > Shortcuts."
  NEEDS_RELOGIN=1
}

setup_session_switching() {
  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING SETUP (KDE Plasma <-> Gamescope)"
  echo "  Using ChimeraOS gamescope-session + plasmalogin"
  echo "================================================================"
  echo ""

  # Intel-only check
  if check_intel_only; then
    echo ""
    echo "  NO DICE - INTEL ONLY DETECTED"
    echo ""
    err "This setup does not support Intel GPUs (iGPU or Arc)."
    echo ""
    echo "  Gaming Mode requires AMD or NVIDIA graphics."
    echo ""
    exit 1
  fi

  echo "  This will:"
  echo "    - Configure session switching between KDE Plasma and Gaming Mode"
  echo "    - Configure Super+Alt+G to switch to Gaming Mode"
  echo "    - Configure Steam's 'Exit to Desktop' to return to KDE Plasma"
  echo ""
  read -p "Set up session switching? [Y/n]: " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipping session switching setup"
    return 0
  fi

  local current_user="${SUDO_USER:-$USER}"
  local user_home
  user_home=$(getent passwd "$current_user" | cut -d: -f6)
  [[ -d "$user_home" ]] || user_home="$HOME"

  local monitor_width=1920
  local monitor_height=1080
  local monitor_refresh=60
  local monitor_output=""

  local -a dgpu_monitors=()
  local dgpu_card=""
  local dgpu_type=""
  detect_dgpu_monitors dgpu_monitors dgpu_card dgpu_type

  if [[ -z "$dgpu_card" ]]; then
    if [[ "$dgpu_type" == "NVIDIA" ]]; then
      warn "NVIDIA GPU detected but no DRM card found!"
      echo ""
      echo "  This usually means nvidia-drm.modeset=1 is not set."
      echo "  Continuing setup with defaults (2560x1440@60 on NVIDIA)."
      echo "  A REBOOT will be required for full functionality."
      echo ""
      NEEDS_REBOOT=1
      # Use safe NVIDIA defaults so session switching config is still created
      dgpu_card="card0"
      monitor_width=2560
      monitor_height=1440
      monitor_refresh=60
    fi

    if [[ "$dgpu_type" != "NVIDIA" ]]; then
    # No dGPU and not NVIDIA - check for APU
    local apu_card=""
    local apu_monitors=()
    local card_name driver_link driver conn_dir conn_name status resolution mode_file

    for card_path in /sys/class/drm/card[0-9]*; do
      card_name=$(basename "$card_path")
      [[ "$card_name" == render* ]] && continue
      driver_link="$card_path/device/driver"
      [[ -L "$driver_link" ]] || continue
      driver=$(basename "$(readlink "$driver_link")")

      if [[ "$driver" == "amdgpu" ]] && is_amd_igpu_card "$card_path"; then
        apu_card="$card_name"
        for connector in "$card_path"/"$card_name"-*/status; do
          [[ -f "$connector" ]] || continue
          conn_dir=$(dirname "$connector")
          conn_name=$(basename "$conn_dir")
          conn_name=${conn_name#card*-}
          [[ "$conn_name" == Writeback* ]] && continue
          status=$(cat "$connector" 2>/dev/null)
          if [[ "$status" == "connected" ]]; then
            resolution=""
            mode_file="$conn_dir/modes"
            [[ -f "$mode_file" ]] && [[ -s "$mode_file" ]] && resolution=$(head -1 "$mode_file" 2>/dev/null)
            apu_monitors+=("$conn_name|$resolution")
          fi
        done
        break
      fi
    done

    if [[ -n "$apu_card" && ${#apu_monitors[@]} -gt 0 ]]; then
      echo ""
      info "No discrete GPU found, but detected AMD APU ($apu_card)"
      echo ""
      echo "  This system has an AMD APU which can run Gaming Mode."
      echo "  Detected monitors: ${#apu_monitors[@]}"
      echo ""
      read -p "  Set up Gaming Mode for APU? [Y/n]: " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        dgpu_card="$apu_card"
        dgpu_type="AMD APU"
        dgpu_monitors=("${apu_monitors[@]}")
        info "Configuring Gaming Mode for AMD APU"
      else
        info "Skipping APU Gaming Mode setup"
        return 0
      fi
    else
      err "No discrete GPU (dGPU) or AMD APU found!"
      echo "  Gaming mode requires a supported GPU with a connected display."
      return 1
    fi
    fi
  fi

  info "Found $dgpu_type on $dgpu_card"

  if [[ ${#dgpu_monitors[@]} -eq 0 ]]; then
    if [[ "$dgpu_type" == "NVIDIA" && "$NEEDS_REBOOT" -eq 1 ]]; then
      info "No monitors detected on NVIDIA (nvidia-drm.modeset=1 not yet active)"
      info "Using defaults: 2560x1440@60 — will auto-detect after reboot"
    else
      err "No monitors connected to dGPU!"
      echo ""
      echo "  Gaming mode requires a monitor connected to the discrete GPU."
      echo "  Please connect an external monitor to your dGPU port (HDMI/DP/USB-C)"
      echo "  and re-run this installer."
      echo ""
      return 1
    fi
  fi

  if [[ ${#dgpu_monitors[@]} -eq 1 ]]; then
    local entry="${dgpu_monitors[0]}"
    monitor_output="${entry%%|*}"
    local res="${entry##*|}"
    if [[ -n "$res" ]]; then
      monitor_width="${res%%x*}"
      monitor_height="${res##*x}"
      monitor_height="${monitor_height%%@*}"
      [[ "$res" == *@* ]] && monitor_refresh="${res##*@}" && monitor_refresh="${monitor_refresh%%.*}"
    fi
  else
    echo ""
    echo "  Multiple monitors connected to $dgpu_type:"
    local i=1
    for entry in "${dgpu_monitors[@]}"; do
      local name="${entry%%|*}"
      local res="${entry##*|}"
      echo "    $i) $name ${res:+($res)}"
      ((i++))
    done
    echo ""
    read -r -p "Select monitor for Gaming Mode [1-${#dgpu_monitors[@]}]: " selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#dgpu_monitors[@]})); then
      selection=1
    fi
    local entry="${dgpu_monitors[$((selection-1))]}"
    monitor_output="${entry%%|*}"
    local res="${entry##*|}"
    if [[ -n "$res" ]]; then
      monitor_width="${res%%x*}"
      monitor_height="${res##*x}"
      monitor_height="${monitor_height%%@*}"
      [[ "$res" == *@* ]] && monitor_refresh="${res##*@}" && monitor_refresh="${monitor_refresh%%.*}"
    fi
  fi

  info "Selected dGPU display: ${monitor_output} (${monitor_width}x${monitor_height}@${monitor_refresh}Hz)"

  info "Checking for old custom session files to clean up..."

  local -a old_files=(
    "/usr/bin/gamescope-session"
    "/usr/share/wayland-sessions/gamescope-session.desktop"
    "/usr/bin/jupiter-biosupdate"
    "/usr/bin/steamos-update"
    "/usr/bin/steamos-select-branch"
    "/usr/bin/steamos-session-select"
  )

  local cleaned=false
  for old_file in "${old_files[@]}"; do
    if [[ -f "$old_file" ]]; then
      info "Removing old file: $old_file"
      sudo rm -f "$old_file" && cleaned=true
    fi
  done

  if $cleaned; then
    info "Old custom session files removed"
  else
    info "No old files to clean up"
  fi

  # Re-install ChimeraOS session scripts (they were cleaned above)
  install_chimera_session_scripts

  # NetworkManager - ensure it's enabled (Fedora uses NM by default)
  info "Verifying NetworkManager is enabled..."
  if systemctl is-active --quiet NetworkManager.service; then
    info "NetworkManager is running"
  else
    warn "NetworkManager is not running - enabling..."
    sudo systemctl enable --now NetworkManager.service 2>/dev/null || warn "Failed to start NetworkManager"
  fi

  # NM start/stop scripts (Fedora: NM is always running)
  local nm_start_script="/usr/local/bin/gamescope-nm-start"
  sudo tee "$nm_start_script" > /dev/null << 'NM_START'
#!/bin/bash
# On Fedora, NetworkManager is always running.
LOG_TAG="gamescope-nm"
log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

if systemctl is-active --quiet NetworkManager.service; then
    log "NetworkManager is running"
else
    log "Starting NetworkManager service..."
    systemctl start NetworkManager.service
    if [ $? -eq 0 ]; then
        log "NetworkManager started successfully"
    else
        log "ERROR: Failed to start NetworkManager"
        exit 1
    fi
    for i in {1..20}; do
        if nmcli general status &>/dev/null; then
            log "NetworkManager ready after ${i} attempts"
            break
        fi
        sleep 0.5
    done
fi
nmcli general status 2>/dev/null || log "WARNING: nmcli status check failed"
NM_START
  sudo chmod +x "$nm_start_script"

  local nm_stop_script="/usr/local/bin/gamescope-nm-stop"
  sudo tee "$nm_stop_script" > /dev/null << 'NM_STOP'
#!/bin/bash
# On Fedora, we do NOT stop NetworkManager - it manages all networking.
LOG_TAG="gamescope-nm"
log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }
log "Gaming session ended - NetworkManager remains active (Fedora default)"
NM_STOP
  sudo chmod +x "$nm_stop_script"
  info "Created NetworkManager start/stop scripts"

  # Steam library mount script
  local steam_mount_script="/usr/local/bin/steam-library-mount"
  info "Creating Steam library drive mount script..."
  sudo tee "$steam_mount_script" > /dev/null << 'STEAM_MOUNT'
#!/bin/bash
LOG_TAG="steam-library-mount"
MOUNT_BASE="/run/media/$USER"

log() { logger -t "$LOG_TAG" "$*"; }

check_steam_library() {
    local mount_point="$1"
    if [[ -d "$mount_point/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary/steamapps" ]] || \
       [[ -d "$mount_point/SteamLibrary" ]] || \
       [[ -f "$mount_point/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/steamapps/libraryfolder.vdf" ]] || \
       [[ -f "$mount_point/SteamLibrary/libraryfolder.vdf" ]]; then
        return 0
    fi
    return 1
}

handle_device() {
    local device="$1"
    local part_name
    part_name=$(basename "$device")

    log "Checking device: $device"

    if findmnt -n "$device" &>/dev/null; then
        local existing_mount
        existing_mount=$(findmnt -n -o TARGET "$device" 2>/dev/null)
        if [[ -n "$existing_mount" ]] && check_steam_library "$existing_mount"; then
            log "Steam library already mounted at $existing_mount"
        else
            log "Device $device mounted at $existing_mount (no Steam library)"
        fi
        return
    fi

    [[ "$device" =~ [0-9]$ ]] || { log "Skipping whole disk: $device"; return; }

    local fstype
    fstype=$(lsblk -n -o FSTYPE --nodeps "$device" 2>/dev/null)
    case "$fstype" in
        ext4|ext3|ext2|btrfs|xfs|ntfs|vfat|exfat|f2fs) ;;
        crypto_LUKS) log "Skipping encrypted: $device"; return ;;
        swap) log "Skipping swap: $device"; return ;;
        "") log "Skipping $device - no filesystem"; return ;;
        *) log "Skipping $device - unsupported filesystem: $fstype"; return ;;
    esac

    if ! command -v udisksctl &>/dev/null; then
        log "udisksctl not found - cannot mount $device"
        return
    fi

    log "Attempting to mount $device..."
    local mount_output
    mount_output=$(udisksctl mount -b "$device" --no-user-interaction 2>&1)
    local mount_rc=$?

    if [[ $mount_rc -ne 0 ]]; then
        log "Could not mount $device: $mount_output"
        return
    fi

    local mount_point
    mount_point=$(findmnt -n -o TARGET "$device" 2>/dev/null)

    if [[ -z "$mount_point" ]]; then
        log "Could not determine mount point for $device"
        return
    fi

    if check_steam_library "$mount_point"; then
        log "Steam library found on $device at $mount_point - keeping mounted"
    else
        log "No Steam library on $device - unmounting"
        udisksctl unmount -b "$device" --no-user-interaction 2>/dev/null
    fi
}

log "Starting Steam library drive monitor..."

shopt -s nullglob
for dev in /dev/sd*[0-9]* /dev/nvme*p[0-9]*; do
    [[ -b "$dev" ]] && handle_device "$dev"
done
shopt -u nullglob

log "Initial device scan complete, watching for new devices..."

udevadm monitor --kernel --subsystem-match=block 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^KERNEL.*[[:space:]]add[[:space:]]+.*/([^/[:space:]]+)[[:space:]]+\(block\)$ ]]; then
        dev_name="${BASH_REMATCH[1]}"
        dev_path="/dev/$dev_name"
        if [[ "$dev_name" =~ [0-9]$ ]] && [[ -b "$dev_path" ]]; then
            sleep 1
            handle_device "$dev_path"
        fi
    fi
done
STEAM_MOUNT
  sudo chmod +x "$steam_mount_script"
  info "Created $steam_mount_script"

  # Polkit rules - use 'wheel' group for Fedora
  local polkit_rules="/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"

  if [[ -f "$polkit_rules" ]]; then
    info "Polkit rules already exist at $polkit_rules"
  else
    info "Creating Polkit rules for NetworkManager D-Bus access..."
    sudo mkdir -p /etc/polkit-1/rules.d

    if sudo tee "$polkit_rules" > /dev/null << 'POLKIT_RULES'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id == "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.own" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.hostname") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES
    then
      sudo chmod 644 "$polkit_rules"
      info "Polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create polkit rules file"
    fi
  fi

  local udisks_polkit="/etc/polkit-1/rules.d/50-udisks-gaming.rules"

  if [[ -f "$udisks_polkit" ]]; then
    info "Udisks2 polkit rules already exist at $udisks_polkit"
  else
    info "Creating Polkit rules for external drive auto-mount..."
    sudo mkdir -p /etc/polkit-1/rules.d
    local udisks_exit=0
    sudo tee "$udisks_polkit" > /dev/null << 'UDISKS_POLKIT' || udisks_exit=$?
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.power-off-drive") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
UDISKS_POLKIT

    if [[ $udisks_exit -eq 0 ]]; then
      sudo chmod 644 "$udisks_polkit"
      info "Udisks2 polkit rules created successfully"
      sudo systemctl restart polkit.service 2>/dev/null || true
    else
      err "Failed to create udisks2 polkit rules"
    fi
  fi

  info "Creating gamescope-session-plus configuration..."
  local env_dir="${user_home}/.config/environment.d"
  local gamescope_conf="${env_dir}/gamescope-session-plus.conf"

  sudo -u "$current_user" mkdir -p "$env_dir"

  local output_connector=""
  [[ -n "$monitor_output" ]] && output_connector="OUTPUT_CONNECTOR=$monitor_output"

  local is_nvidia=false
  local nvidia_device_id=""
  if [[ "$dgpu_type" == "NVIDIA" ]]; then
    is_nvidia=true
    nvidia_device_id=$(/usr/bin/lspci -nn | grep -i nvidia | grep -oP '\[10de:\K[0-9a-fA-F]+' | head -1)
    if [ "$monitor_width" -gt 2560 ]; then
      monitor_width=2560
    fi
    if [ "$monitor_height" -gt 1440 ]; then
      monitor_height=1440
    fi
  fi

  if $is_nvidia; then
    local vulkan_adapter=""
    [[ -n "$nvidia_device_id" ]] && vulkan_adapter="VULKAN_ADAPTER=10de:${nvidia_device_id}"
    cat > "$gamescope_conf" << GAMESCOPE_CONF
SCREEN_WIDTH=${monitor_width}
SCREEN_HEIGHT=${monitor_height}
CUSTOM_REFRESH_RATES=${monitor_refresh}
${output_connector}
${vulkan_adapter}
GBM_BACKEND=nvidia-drm
STEAM_ALLOW_DRIVE_UNMOUNT=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
  else
    cat > "$gamescope_conf" << GAMESCOPE_CONF
SCREEN_WIDTH=${monitor_width}
SCREEN_HEIGHT=${monitor_height}
CUSTOM_REFRESH_RATES=${monitor_refresh}
${output_connector}
ADAPTIVE_SYNC=1
ENABLE_GAMESCOPE_HDR=1
STEAM_ALLOW_DRIVE_UNMOUNT=1
FCITX_NO_WAYLAND_DIAGNOSE=1
SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
GAMESCOPE_CONF
  fi

  chown "$current_user":"$current_user" "$gamescope_conf" 2>/dev/null || true
  info "Created $gamescope_conf"

  info "Creating NVIDIA gamescope wrapper..."
  local nvidia_wrapper_dir="/usr/local/lib/gamescope-nvidia"
  local nvidia_wrapper="${nvidia_wrapper_dir}/gamescope"

  sudo mkdir -p "$nvidia_wrapper_dir"

  local gamescope_real="/usr/local/bin/gamescope"
  [[ -x "$gamescope_real" ]] || gamescope_real="/usr/bin/gamescope"

  sudo tee "$nvidia_wrapper" > /dev/null << NVIDIA_WRAPPER
#!/bin/bash
EXTRA_ARGS=""
if ${gamescope_real} --help 2>&1 | grep -q "force-composition"; then
    EXTRA_ARGS="--force-composition"
fi
exec ${gamescope_real} \$EXTRA_ARGS "\$@"
NVIDIA_WRAPPER

  sudo chmod +x "$nvidia_wrapper"
  info "Created $nvidia_wrapper"

  info "Creating NetworkManager session wrapper..."
  local nm_wrapper="/usr/local/bin/gamescope-session-nm-wrapper"

  sudo tee "$nm_wrapper" > /dev/null << 'NM_WRAPPER'
#!/bin/bash
log() { logger -t gamescope-wrapper "$*"; echo "$*"; }

# Save original values for restore on exit
ORIG_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "powersave")
ORIG_EPP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "balance_performance")
ORIG_SPLIT_LOCK=$(sysctl -n kernel.split_lock_mitigate 2>/dev/null || echo "")
ORIG_MAX_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo "1048576")

enable_performance_mode() {
    log "Enabling performance mode..."

    # Set CPU governor to performance
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null && log "CPU governor set to performance"
        break
    done
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null
    done

    # AMD pstate: set energy performance preference to performance
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        if [[ -w "$epp" ]]; then
            echo performance > "$epp" 2>/dev/null
        fi
    done
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
        log "AMD pstate EPP set to performance"
    fi

    # Kernel tuning: disable split lock mitigation (prevents stalls in some Proton games)
    [[ -n "$ORIG_SPLIT_LOCK" ]] && sudo -n /usr/bin/sysctl -w kernel.split_lock_mitigate=0 2>/dev/null && log "Split lock mitigation disabled"

    # Increase max memory map areas (prevents crashes in heavy Proton titles)
    sudo -n /usr/bin/sysctl -w vm.max_map_count=2147483642 2>/dev/null && log "vm.max_map_count increased"

    # Disable proactive memory compaction (reduces latency spikes)
    sudo -n /usr/bin/sysctl -w vm.compaction_proactiveness=0 2>/dev/null && log "Proactive compaction disabled"

    # Disable NMI watchdog (frees a hardware perf counter)
    sudo -n /usr/bin/sysctl -w kernel.nmi_watchdog=0 2>/dev/null && log "NMI watchdog disabled"

    # Set transparent hugepages to madvise (avoids background compaction stalls)
    echo madvise | sudo -n /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 && log "THP set to madvise"

    # NVIDIA dGPU performance mode
    if command -v nvidia-smi &>/dev/null; then
        sudo -n /usr/bin/nvidia-smi -pm 1 2>/dev/null && log "NVIDIA persistence mode enabled"

        local max_power
        max_power=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$max_power" && "$max_power" -gt 0 ]]; then
            sudo -n /usr/bin/nvidia-smi -pl "$max_power" 2>/dev/null && log "NVIDIA power limit set to ${max_power}W"
        fi

        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo on > "$nvidia_pci" 2>/dev/null && log "NVIDIA runtime suspend disabled"
                fi
            fi
        done
    fi

    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set performance 2>/dev/null && log "Power profile set to performance"
    fi
}

restore_balanced_mode() {
    log "Restoring balanced mode..."

    # Restore CPU governor to original
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "${ORIG_GOV:-powersave}" > "$gov" 2>/dev/null
    done

    # AMD pstate: restore energy performance preference
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        if [[ -w "$epp" ]]; then
            echo "${ORIG_EPP:-balance_performance}" > "$epp" 2>/dev/null
        fi
    done

    # Restore kernel tuning to original values
    [[ -n "${ORIG_SPLIT_LOCK:-}" ]] && sudo -n /usr/bin/sysctl -w kernel.split_lock_mitigate="${ORIG_SPLIT_LOCK}" 2>/dev/null
    sudo -n /usr/bin/sysctl -w vm.max_map_count="${ORIG_MAX_MAP:-1048576}" 2>/dev/null
    sudo -n /usr/bin/sysctl -w vm.compaction_proactiveness=20 2>/dev/null
    sudo -n /usr/bin/sysctl -w kernel.nmi_watchdog=1 2>/dev/null
    echo always | sudo -n /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1

    if command -v nvidia-smi &>/dev/null; then
        local default_power
        default_power=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d'.' -f1)
        if [[ -n "$default_power" && "$default_power" -gt 0 ]]; then
            sudo -n /usr/bin/nvidia-smi -pl "$default_power" 2>/dev/null
        fi

        for nvidia_pci in /sys/bus/pci/devices/*/power/control; do
            if [[ -f "${nvidia_pci%/power/control}/driver" ]]; then
                local drv=$(basename "$(readlink -f "${nvidia_pci%/power/control}/driver")" 2>/dev/null)
                if [[ "$drv" == "nvidia" ]]; then
                    echo auto > "$nvidia_pci" 2>/dev/null
                fi
            fi
        done

        sudo -n /usr/bin/nvidia-smi -pm 0 2>/dev/null
    fi

    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set balanced 2>/dev/null
    fi

    log "Balanced mode restored"
}

cleanup() {
    pkill -f steam-library-mount 2>/dev/null || true
    sudo -n /usr/local/bin/gamescope-nm-stop 2>/dev/null || true
    restore_balanced_mode
    # Unmask sleep targets that were masked during switch-to-gaming
    sudo -n /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
    # Re-enable Bluetooth
    sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
    sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true
    # Unmask drkonqi crash reporter
    systemctl --user unmask drkonqi-coredump-launcher@.service 2>/dev/null || true
    rm -f /tmp/.gaming-session-active
}
trap cleanup EXIT INT TERM

# Mask drkonqi crash reporter during gaming session
# Gaming processes crash harmlessly on shutdown — no need for crash dialogs
systemctl --user mask drkonqi-coredump-launcher@.service 2>/dev/null || true
log "Masked drkonqi crash reporter for gaming session"

enable_performance_mode

if /usr/bin/lspci 2>/dev/null | grep -qi nvidia; then
    export PATH="/usr/local/lib/gamescope-nvidia:$PATH"
    # Use the NVIDIA wrapper which adds --force-composition
    if [[ -x /usr/local/lib/gamescope-nvidia/gamescope ]]; then
        export GAMESCOPE_BIN="/usr/local/lib/gamescope-nvidia/gamescope"
        log "Using NVIDIA gamescope wrapper at $GAMESCOPE_BIN"
    elif [[ -x /usr/local/bin/gamescope ]]; then
        export GAMESCOPE_BIN="/usr/local/bin/gamescope"
        log "Warning: NVIDIA wrapper not found, using gamescope directly at $GAMESCOPE_BIN"
    fi
elif [[ -x /usr/local/bin/gamescope ]]; then
    export GAMESCOPE_BIN="/usr/local/bin/gamescope"
    log "Using gamescope at $GAMESCOPE_BIN"
fi

sudo -n /usr/local/bin/gamescope-nm-start 2>/dev/null || {
    log "Warning: Could not run NM start script"
}

if [[ -x /usr/local/bin/steam-library-mount ]]; then
    /usr/local/bin/steam-library-mount &
    log "Steam library drive monitor started"
else
    log "Warning: steam-library-mount not found"
fi

echo "gamescope" > /tmp/.gaming-session-active

export QT_IM_MODULE=steam
export GTK_IM_MODULE=Steam
export STEAM_DISABLE_AUDIO_DEVICE_SWITCHING=1
export STEAM_ENABLE_VOLUME_HANDLER=1

/usr/share/gamescope-session-plus/gamescope-session-plus steam
rc=$?

exit $rc
NM_WRAPPER

  sudo chmod +x "$nm_wrapper"
  info "Created $nm_wrapper"

  info "Creating wayland session entry..."
  local session_desktop="/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
  sudo mkdir -p /usr/share/wayland-sessions

  sudo tee "$session_desktop" > /dev/null << 'SESSION_DESKTOP'
[Desktop Entry]
Name=Gaming Mode (ChimeraOS)
Comment=Steam Big Picture with ChimeraOS gamescope-session
Exec=/usr/local/bin/gamescope-session-nm-wrapper
Type=Application
DesktopNames=gamescope
SESSION_DESKTOP

  info "Created $session_desktop"

  info "Creating session-select script..."
  local os_session_select="/usr/lib/os-session-select"

  sudo tee "$os_session_select" > /dev/null << 'OS_SESSION_SELECT'
#!/bin/bash
rm -f /tmp/.gaming-session-active
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || {
  echo "Warning: Failed to update session config"
}
timeout 5 steam -shutdown 2>/dev/null || true
sleep 1
nohup sudo -n /usr/bin/systemctl restart plasmalogin &>/dev/null &
disown
exit 0
OS_SESSION_SELECT

  sudo chmod +x "$os_session_select"
  info "Created $os_session_select"

  info "Creating switch-to-gaming script..."
  local switch_script="/usr/local/bin/switch-to-gaming"

  sudo tee "$switch_script" > /dev/null << 'SWITCH_SCRIPT'
#!/bin/bash
# Inhibit suspend FIRST
sudo -n /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch gaming 2>/dev/null || {
  notify-send -u critical -t 3000 "Gaming Mode" "Failed to update session config" 2>/dev/null || true
}
notify-send -u normal -t 2000 "Gaming Mode" "Switching to Gaming Mode..." 2>/dev/null || true
pkill -TERM gamescope 2>/dev/null || true
pkill -TERM -f gamescope-session 2>/dev/null || true
sleep 1
# Force kill if still running
pgrep -x gamescope >/dev/null 2>&1 && pkill -9 gamescope 2>/dev/null || true
pgrep -f gamescope-session >/dev/null 2>&1 && pkill -9 -f gamescope-session 2>/dev/null || true
sleep 0.5
# Wait for DRM master to be released (critical on NVIDIA)
for i in $(seq 1 20); do
  fuser /dev/dri/card* &>/dev/null || break
  sleep 0.5
done
sudo -n /usr/bin/chvt 2 2>/dev/null || true
sleep 0.3
sudo -n /usr/bin/systemctl restart plasmalogin
SWITCH_SCRIPT

  sudo chmod +x "$switch_script"
  info "Created $switch_script"

  info "Creating switch-to-desktop script..."
  local switch_desktop_script="/usr/local/bin/switch-to-desktop"

  sudo tee "$switch_desktop_script" > /dev/null << 'SWITCH_DESKTOP'
#!/bin/bash
if [[ ! -f /tmp/.gaming-session-active ]]; then
  exit 0
fi
rm -f /tmp/.gaming-session-active

sudo -n /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
sudo -n /usr/local/bin/gaming-session-switch desktop 2>/dev/null || true

# Re-enable Bluetooth
sudo -n /usr/bin/rfkill unblock bluetooth 2>/dev/null || true
sudo -n /usr/bin/systemctl start bluetooth.service 2>/dev/null || true

timeout 5 steam -shutdown 2>/dev/null || true
sleep 1

pkill -TERM gamescope 2>/dev/null || true
pkill -TERM -f gamescope-session 2>/dev/null || true

for _ in {1..6}; do
  pgrep -x gamescope >/dev/null 2>&1 || break
  sleep 0.5
done

if pgrep -x gamescope >/dev/null 2>&1; then
  pkill -9 gamescope 2>/dev/null || true
  pkill -9 -f gamescope-session 2>/dev/null || true
fi

sleep 2

# Wait for DRM master to be released (critical on NVIDIA)
for i in $(seq 1 20); do
  fuser /dev/dri/card* &>/dev/null || break
  sleep 0.5
done

sudo -n /usr/bin/chvt 2 2>/dev/null || true
sleep 0.5
sudo -n /usr/bin/systemctl stop plasmalogin 2>/dev/null || true
sleep 1
sudo -n /usr/bin/systemctl start plasmalogin &
disown
exit 0
SWITCH_DESKTOP

  sudo chmod +x "$switch_desktop_script"
  info "Created $switch_desktop_script"

  # Detect the correct KDE session name
  local kde_session_name
  kde_session_name=$(detect_kde_session_name)
  info "Detected KDE session: $kde_session_name"

  info "Creating plasmalogin session switching config..."
  local plasmalogin_conf="/etc/plasmalogin.conf"

  local autologin_user="$current_user"
  if [[ -f "$plasmalogin_conf" ]]; then
    local existing_user
    existing_user=$(sed -n 's/^User=//p' "$plasmalogin_conf" 2>/dev/null | head -1)
    [[ -n "$existing_user" ]] && autologin_user="$existing_user"
  fi

  # Backup existing plasmalogin.conf
  if [[ -f "$plasmalogin_conf" ]]; then
    sudo cp "$plasmalogin_conf" "${plasmalogin_conf}.bak.gaming-mode"
    info "Backed up $plasmalogin_conf to ${plasmalogin_conf}.bak.gaming-mode"
  fi

  # Update or create the [Autologin] section in plasmalogin.conf
  if [[ -f "$plasmalogin_conf" ]] && grep -q '^\[Autologin\]' "$plasmalogin_conf"; then
    sudo sed -i "s/^Session=.*/Session=${kde_session_name}/" "$plasmalogin_conf"
    if ! grep -q '^User=' "$plasmalogin_conf"; then
      sudo sed -i "/^\[Autologin\]/a User=${autologin_user}" "$plasmalogin_conf"
    fi
    if ! grep -q '^Relogin=' "$plasmalogin_conf"; then
      sudo sed -i "/^\[Autologin\]/a Relogin=true" "$plasmalogin_conf"
    fi
  else
    sudo tee "$plasmalogin_conf" > /dev/null << PLASMA_GAMING
[Autologin]
User=${autologin_user}
Session=${kde_session_name}
Relogin=true
PLASMA_GAMING
  fi

  info "Configured $plasmalogin_conf (default session: $kde_session_name)"

  # Ensure user is in the autologin group (required for passwordless login)
  if ! groups "$autologin_user" 2>/dev/null | grep -q '\bautologin\b'; then
    info "Adding $autologin_user to autologin group for passwordless session switching..."
    sudo groupadd -f autologin
    sudo usermod -aG autologin "$autologin_user"
    info "Added $autologin_user to autologin group"
  else
    info "User $autologin_user already in autologin group"
  fi

  info "Creating session switching helper script..."
  local session_helper="/usr/local/bin/gaming-session-switch"

  sudo tee "$session_helper" > /dev/null << SESSION_HELPER
#!/bin/bash
CONF="/etc/plasmalogin.conf"

if [[ ! -f "\$CONF" ]]; then
  echo "Error: Config file not found: \$CONF" >&2
  exit 1
fi

case "\$1" in
  gaming)
    sed -i 's/^Session=.*/Session=gamescope-session-steam-nm/' "\$CONF"
    echo "Session set to: gaming mode"
    ;;
  desktop)
    sed -i 's/^Session=.*/Session=${kde_session_name}/' "\$CONF"
    echo "Session set to: desktop mode (KDE Plasma)"
    ;;
  *)
    echo "Usage: \$0 {gaming|desktop}" >&2
    exit 1
    ;;
esac
SESSION_HELPER

  sudo chmod +x "$session_helper"
  info "Created $session_helper"

  local sudoers_session="/etc/sudoers.d/gaming-session-switch"

  if [[ -f "$sudoers_session" ]]; then
    info "Removing old sudoers rules to update..."
    sudo rm -f "$sudoers_session"
  fi

  info "Creating sudoers rules for session switching..."
  sudo mkdir -p /etc/sudoers.d

  if sudo tee "$sudoers_session" > /dev/null << 'SUDOERS_SWITCH'
%video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart plasmalogin
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop plasmalogin
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start plasmalogin
%video ALL=(ALL) NOPASSWD: /usr/bin/chvt
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl start NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop NetworkManager.service
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start bluetooth.service
%video ALL=(ALL) NOPASSWD: /usr/bin/rfkill unblock bluetooth
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-start
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-stop
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS_SWITCH
  then
    sudo chmod 0440 "$sudoers_session"
    if sudo visudo -c -f "$sudoers_session" >/dev/null 2>&1; then
      info "Sudoers rules created and validated successfully"
    else
      err "Sudoers syntax validation FAILED -- removing broken file"
      sudo rm -f "$sudoers_session"
    fi
  else
    err "Failed to create sudoers file"
  fi

  # SELinux: allow domain mmap for Steam's sandbox (pressure-vessel/bubblewrap)
  # Fedora uses SELinux instead of AppArmor.
  info "Configuring SELinux permissions for gaming session..."

  sudo setsebool -P domain_can_mmap_files 1 2>/dev/null || \
    warn "Could not set SELinux boolean domain_can_mmap_files"

  # Verify user namespaces are available (they should be on Fedora)
  local max_userns
  max_userns=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo "0")
  if [[ "$max_userns" -lt 1 ]]; then
    warn "Unprivileged user namespaces appear disabled - Steam's sandbox may not work"
    warn "Try: sudo sysctl -w user.max_user_namespaces=65536"
  else
    info "Unprivileged user namespaces enabled (max=$max_userns)"
  fi
  info "SELinux permissions configured for gaming session"

  # Suppress drkonqi crash dialogs during gaming session
  # Gamescope, bwrap, and wine crash on shutdown (SIGTERM/SIGKILL) which
  # triggers KDE's crash reporter with noisy but harmless dialogs.
  # We mask drkonqi in the gaming session wrapper and unmask on exit.
  info "drkonqi crash reporter will be masked during gaming sessions"

  # Set up KDE Plasma keybinding
  setup_kde_shortcut "$user_home"

  echo ""
  echo "================================================================"
  echo "  SESSION SWITCHING CONFIGURED (ChimeraOS on Fedora KDE)"
  echo "================================================================"
  echo ""
  echo "  Usage:"
  echo "    - Press Super+Alt+G in KDE Plasma to switch to Gaming Mode"
  echo "    - In Gaming Mode, use Steam > Power > Exit to Desktop to return to KDE Plasma"
  echo ""
  echo "  ChimeraOS scripts installed from source:"
  echo "    - gamescope-session-plus (base session framework)"
  echo "    - gamescope-session-steam scripts (Steam session)"
  echo ""
  echo "  Files created/modified:"
  echo "    - ~/.config/environment.d/gamescope-session-plus.conf"
  echo "    - /usr/local/bin/gamescope-session-nm-wrapper"
  echo "    - /usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"
  echo "    - /usr/lib/os-session-select"
  echo "    - /usr/local/bin/switch-to-gaming"
  echo "    - /usr/local/bin/switch-to-desktop"
  echo "    - /usr/share/applications/switch-to-gaming.desktop"
  echo "    - ~/.config/kglobalshortcutsrc (KDE shortcut added)"
  echo "    - /etc/plasmalogin.conf (session switching via [Autologin] section)"
  echo ""
  echo "  NetworkManager integration:"
  echo "    - /usr/local/bin/gamescope-nm-start"
  echo "    - /usr/local/bin/gamescope-nm-stop"
  echo "    - /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"
  echo "    - /etc/sudoers.d/gaming-session-switch"
  echo ""

  return 0
}

verify_installation() {
  echo ""
  echo "================================================================"
  echo "  GAMING MODE INSTALLATION VERIFICATION (Fedora KDE)"
  echo "================================================================"
  echo ""

  local all_ok=true
  local missing_files=()
  local permission_issues=()

  declare -A expected_files=(
    ["/usr/local/bin/gamescope-session-nm-wrapper"]="755:ChimeraOS session with NM wrapper"
    ["/usr/local/lib/gamescope-nvidia/gamescope"]="755:NVIDIA gamescope wrapper (--force-composition)"
    ["/usr/local/bin/gaming-session-switch"]="755:Session switching helper (gaming/desktop)"
    ["/usr/lib/os-session-select"]="755:Steam Exit to Desktop handler"
    ["/usr/local/bin/switch-to-gaming"]="755:KDE Plasma to Gaming Mode switcher"
    ["/usr/local/bin/switch-to-desktop"]="755:Gaming Mode to Desktop switcher"
    ["/usr/local/bin/gamescope-nm-start"]="755:NetworkManager start script"
    ["/usr/local/bin/gamescope-nm-stop"]="755:NetworkManager stop script"
    ["/usr/local/bin/steam-library-mount"]="755:Steam library drive auto-mount script"
    ["/usr/bin/steamos-session-select"]="755:Steam compatibility script"
    ["/usr/bin/steamos-update"]="755:Steam compatibility script"
    ["/usr/bin/jupiter-biosupdate"]="755:Steam compatibility script"
    ["/usr/bin/steamos-select-branch"]="755:Steam compatibility script"
    ["/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop"]="644:plasmalogin session entry"
    ["/usr/share/gamescope-session-plus/gamescope-session-plus"]="755:ChimeraOS session launcher"
    ["/usr/share/gamescope-session-plus/sessions.d/steam"]="755:Steam session config (CLIENTCMD + env vars)"
    ["/usr/share/applications/switch-to-gaming.desktop"]="644:KDE shortcut desktop entry"
    ["/etc/plasmalogin.conf"]="644:plasmalogin session switching config"
    ["/etc/polkit-1/rules.d/50-gamescope-networkmanager.rules"]="644:Polkit NM rules"
    ["/etc/polkit-1/rules.d/50-udisks-gaming.rules"]="644:Polkit udisks2 rules (external drive mount)"
    ["/etc/sudoers.d/gaming-session-switch"]="440:Sudoers rules"
    ["/etc/udev/rules.d/99-gaming-performance.rules"]="644:Udev performance rules"
    ["/etc/sudoers.d/gaming-mode-sysctl"]="440:Performance sudoers"
    ["/etc/security/limits.d/99-gaming-memlock.conf"]="644:Memlock limits"
    ["/etc/pipewire/pipewire.conf.d/10-gaming-latency.conf"]="644:PipeWire low-latency"
    ["/etc/environment.d/99-shader-cache.conf"]="644:Shader cache config"
  )
  echo "  FILE STATUS:"
  echo "  ------------"
  echo ""

  for file in "${!expected_files[@]}"; do
    local expected_perm="${expected_files[$file]%%:*}"
    local description="${expected_files[$file]#*:}"
    local is_optional=false

    [[ "$description" == *"(optional)"* ]] && is_optional=true

    if sudo test -f "$file" 2>/dev/null; then
      local actual_perm
      actual_perm=$(sudo stat -c "%a" "$file" 2>/dev/null)

      if [[ "$actual_perm" == "$expected_perm" ]]; then
        printf "  OK  %-55s [%s]\n" "$file" "$actual_perm"
      else
        printf "  !!  %-55s [%s] (expected %s)\n" "$file" "$actual_perm" "$expected_perm"
        permission_issues+=("$file: has $actual_perm, expected $expected_perm")
        all_ok=false
      fi
    else
      if $is_optional; then
        printf "  --  %-55s [SKIPPED] %s\n" "$file" "(optional)"
      else
        printf "  XX  %-55s [MISSING]\n" "$file"
        missing_files+=("$file: $description")
        all_ok=false
      fi
    fi
  done

  echo ""
  echo "  GAMESCOPE BINARY:"
  echo "  -----------------"
  if command -v gamescope >/dev/null 2>&1; then
    echo "  OK  gamescope found at $(command -v gamescope)"
  elif [[ -x /usr/local/bin/gamescope ]]; then
    echo "  OK  gamescope found at /usr/local/bin/gamescope"
  else
    echo "  XX  gamescope NOT found (needs to be built from source)"
    all_ok=false
  fi

  echo ""
  echo "  MANGOAPP (Performance Overlay):"
  echo "  --------------------------------"
  if command -v mangoapp >/dev/null 2>&1; then
    echo "  OK  mangoapp found at $(command -v mangoapp)"
  elif [[ -x /usr/local/bin/mangoapp ]]; then
    echo "  OK  mangoapp found at /usr/local/bin/mangoapp"
  else
    echo "  XX  mangoapp NOT found (Steam performance overlay will NOT work)"
    echo "      Fix: Re-run setup to install mangoapp"
    all_ok=false
  fi

  echo ""
  echo "  PROTON GE:"
  echo "  ----------"
  local verify_steam_root=""
  if [[ -d "$HOME/.local/share/Steam" ]]; then
    verify_steam_root="$HOME/.local/share/Steam"
  elif [[ -L "$HOME/.steam/root" ]]; then
    verify_steam_root="$(readlink -f "$HOME/.steam/root")"
  elif [[ -d "$HOME/.steam/debian-installation" ]]; then
    verify_steam_root="$HOME/.steam/debian-installation"
  elif [[ -d "$HOME/.steam/steam" ]]; then
    verify_steam_root="$HOME/.steam/steam"
  fi
  local compat_dir="${verify_steam_root:+$verify_steam_root/compatibilitytools.d}"
  local ge_versions=()
  if [[ -d "$compat_dir" ]]; then
    while IFS= read -r -d '' dir; do
      ge_versions+=("$(basename "$dir")")
    done < <(find "$compat_dir" -maxdepth 1 -type d -name "GE-Proton*" -print0 2>/dev/null | sort -zV)
  fi
  if ((${#ge_versions[@]})); then
    echo "  OK  Proton GE installed (${#ge_versions[@]} version(s)):"
    for gev in "${ge_versions[@]}"; do
      echo "      - $gev"
    done
  else
    echo "  XX  Proton GE NOT installed"
    echo "      Re-run setup or manually download from:"
    echo "      https://github.com/GloriousEggroll/proton-ge-custom/releases"
    all_ok=false
  fi

  echo ""
  echo "  KDE PLASMA SHORTCUT:"
  echo "  ---------------------"
  local kde_shortcuts="$HOME/.config/kglobalshortcutsrc"
  if [[ -f "$kde_shortcuts" ]]; then
    if grep -q "switch-to-gaming" "$kde_shortcuts" 2>/dev/null; then
      echo "  OK  Gaming Mode shortcut (Super+Alt+G) configured in kglobalshortcutsrc"
    else
      echo "  XX  Gaming Mode shortcut NOT found in kglobalshortcutsrc"
      echo "      You can add it manually: System Settings > Shortcuts > Custom Shortcuts"
      all_ok=false
    fi
  else
    echo "  !!  kglobalshortcutsrc not found - shortcut needs manual setup"
    echo "      Go to System Settings > Shortcuts to add Super+Alt+G"
  fi

  echo ""
  echo "  CHIMERAOS SCRIPTS:"
  echo "  -------------------"
  if [[ -x "/usr/share/gamescope-session-plus/gamescope-session-plus" ]]; then
    echo "  OK  gamescope-session-plus installed"
  else
    echo "  XX  gamescope-session-plus NOT installed"
    all_ok=false
  fi
  if [[ -x "/usr/bin/steamos-session-select" ]]; then
    echo "  OK  steamos-session-select installed"
  else
    echo "  XX  steamos-session-select NOT installed"
    all_ok=false
  fi

  echo ""
  echo "  STEAM LIBRARY DRIVE SUPPORT:"
  echo "  -----------------------------"
  if [[ -x "/usr/local/bin/steam-library-mount" ]]; then
    echo "  OK  steam-library-mount script installed"
  else
    echo "  XX  steam-library-mount NOT found - external Steam libraries will not auto-mount"
    all_ok=false
  fi
  if check_package "udisks2"; then
    echo "  OK  udisks2 installed (mount backend)"
  else
    echo "  XX  udisks2 NOT installed"
    all_ok=false
  fi
  if sudo test -f "/etc/polkit-1/rules.d/50-udisks-gaming.rules" 2>/dev/null; then
    echo "  OK  udisks2 polkit rules configured"
  else
    echo "  XX  udisks2 polkit rules NOT found"
    all_ok=false
  fi

  echo ""
  echo "  EXIT GAMING MODE:"
  echo "  ------------------"
  echo "  Use Steam > Power > Exit to Desktop to return to KDE Plasma"

  echo ""
  echo "  USER CONFIG:"
  echo "  ------------"
  local user_conf="$HOME/.config/environment.d/gamescope-session-plus.conf"
  if [[ -f "$user_conf" ]]; then
    echo "  OK  gamescope-session-plus.conf exists"
  else
    echo "  XX  gamescope-session-plus.conf NOT found"
    all_ok=false
  fi

  echo ""
  echo "  USER GROUPS:"
  echo "  ------------"
  local user_groups
  user_groups=$(groups 2>/dev/null)
  for grp in video input wheel; do
    if echo "$user_groups" | grep -qw "$grp"; then
      printf "  OK  User is in '%s' group\n" "$grp"
    else
      printf "  XX  User is NOT in '%s' group\n" "$grp"
      all_ok=false
    fi
  done

  echo ""
  echo "  SERVICE STATUS:"
  echo "  ---------------"
  echo "  NetworkManager:  $(systemctl is-active NetworkManager.service 2>/dev/null || echo 'inactive')"
  echo "  plasmalogin:     $(systemctl is-active plasmalogin.service 2>/dev/null || echo 'inactive')"
  echo "  polkit:          $(systemctl is-active polkit.service 2>/dev/null || echo 'inactive')"

  echo ""
  echo "  SUDO PERMISSIONS TEST:"
  echo "  ----------------------"
  if sudo -n true 2>/dev/null; then
    echo "  OK  sudo -n works (passwordless sudo available)"
    if sudo -n -l /usr/local/bin/gamescope-nm-start &>/dev/null; then
      echo "  OK  Can run gamescope-nm-start without password"
    else
      echo "  XX  Cannot run gamescope-nm-start without password"
      all_ok=false
    fi
  else
    echo "  ??  sudo -n test skipped (requires recent sudo auth)"
    echo "      Run: sudo -v && sudo -n -l /usr/local/bin/gamescope-nm-start"
  fi

  echo ""
  echo "================================================================"
  if $all_ok; then
    echo "  ALL CHECKS PASSED - Gaming Mode should work correctly"
  else
    echo "  SOME ISSUES DETECTED"
    echo ""
    if ((${#missing_files[@]})); then
      echo "  Missing files (${#missing_files[@]}):"
      for f in "${missing_files[@]}"; do
        echo "    - $f"
      done
    fi
    if ((${#permission_issues[@]})); then
      echo ""
      echo "  Permission issues (${#permission_issues[@]}):"
      for p in "${permission_issues[@]}"; do
        echo "    - $p"
      done
    fi
    echo ""
    echo "  Re-run the installer to fix these issues."
  fi
  echo "================================================================"
  echo ""

  $all_ok && return 0 || return 1
}

ensure_critical_permissions() {
  # This function guarantees sudoers and polkit files exist.

  if [[ ! -f /etc/sudoers.d/gaming-mode-sysctl ]]; then
    info "Creating performance sudoers (safety net)..."
    sudo tee /etc/sudoers.d/gaming-mode-sysctl > /dev/null << 'SUDOERS1'
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_autogroup_enabled=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_migration_cost_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_min_granularity_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.sched_latency_ns=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.swappiness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_background_ratio=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_writeback_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.dirty_expire_centisecs=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_watches=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.inotify.max_user_instances=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w fs.file-max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.rmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w net.core.wmem_max=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.split_lock_mitigate=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.max_map_count=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w vm.compaction_proactiveness=*
%video ALL=(ALL) NOPASSWD: /usr/bin/sysctl -w kernel.nmi_watchdog=*
%video ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/kernel/mm/transparent_hugepage/enabled
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS1
    sudo chmod 0440 /etc/sudoers.d/gaming-mode-sysctl
    if sudo visudo -c -f /etc/sudoers.d/gaming-mode-sysctl >/dev/null 2>&1; then
      info "Performance sudoers created and validated"
    else
      err "Performance sudoers validation failed — removing"
      sudo rm -f /etc/sudoers.d/gaming-mode-sysctl
    fi
  fi

  if [[ ! -f /etc/sudoers.d/gaming-session-switch ]]; then
    info "Creating session switch sudoers (safety net)..."
    sudo tee /etc/sudoers.d/gaming-session-switch > /dev/null << 'SUDOERS2'
%video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart plasmalogin
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop plasmalogin
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start plasmalogin
%video ALL=(ALL) NOPASSWD: /usr/bin/chvt
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl mask --runtime sleep.target suspend.target hibernate.target hybrid-sleep.target
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl start NetworkManager.service
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop NetworkManager.service
%video ALL=(ALL) NOPASSWD: /usr/bin/systemctl start bluetooth.service
%video ALL=(ALL) NOPASSWD: /usr/bin/rfkill unblock bluetooth
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-start
%wheel ALL=(ALL) NOPASSWD: /usr/local/bin/gamescope-nm-stop
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pm *
%video ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi -pl *
SUDOERS2
    sudo chmod 0440 /etc/sudoers.d/gaming-session-switch
    if sudo visudo -c -f /etc/sudoers.d/gaming-session-switch >/dev/null 2>&1; then
      info "Session switch sudoers created and validated"
    else
      err "Session switch sudoers validation failed — removing"
      sudo rm -f /etc/sudoers.d/gaming-session-switch
    fi
  fi

  if [[ ! -f /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules ]]; then
    info "Creating NetworkManager polkit rules (safety net)..."
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules > /dev/null << 'POLKIT1'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.enable-disable-network" ||
         action.id == "org.freedesktop.NetworkManager.enable-disable-wifi" ||
         action.id == "org.freedesktop.NetworkManager.network-control" ||
         action.id == "org.freedesktop.NetworkManager.wifi.scan" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.own" ||
         action.id == "org.freedesktop.NetworkManager.settings.modify.hostname") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT1
    sudo chmod 644 /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules
    info "NetworkManager polkit rules created"
  fi

  if [[ ! -f /etc/polkit-1/rules.d/50-udisks-gaming.rules ]]; then
    info "Creating udisks2 polkit rules (safety net)..."
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/50-udisks-gaming.rules > /dev/null << 'POLKIT2'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.udisks2.filesystem-mount" ||
         action.id == "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id == "org.freedesktop.udisks2.filesystem-unmount-others" ||
         action.id == "org.freedesktop.udisks2.encrypted-unlock" ||
         action.id == "org.freedesktop.udisks2.power-off-drive") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT2
    sudo chmod 644 /etc/polkit-1/rules.d/50-udisks-gaming.rules
    info "Udisks2 polkit rules created"
  fi

  # Restart polkit if any rules were just created
  if [[ -f /etc/polkit-1/rules.d/50-gamescope-networkmanager.rules ]] && \
     [[ -f /etc/polkit-1/rules.d/50-udisks-gaming.rules ]]; then
    sudo systemctl restart polkit.service 2>/dev/null || true
  fi
}

execute_setup() {
  sudo -k
  sudo -v || die "sudo authentication required"

  validate_environment

  echo ""
  echo "================================================================"
  echo "  SUPER SHIFT S GAMING MODE INSTALLER v${Super_Shift_S_VERSION}"
  echo "  Fedora / KDE Plasma / plasmalogin Edition (Nobara)"
  echo "  Dependencies & GPU Configuration"
  echo "================================================================"
  echo ""

  check_steam_dependencies
  check_nvidia_kernel_params
  install_nvidia_deckmode_env
  setup_requirements
  setup_session_switching

  # Safety net: ensure critical sudoers and polkit files always exist.
  sudo -v 2>/dev/null || {
    echo ""
    echo "  Sudo credentials expired. Please re-enter your password to complete setup."
    sudo -v || die "sudo authentication required for final setup"
  }
  ensure_critical_permissions

  if [ "$NEEDS_REBOOT" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: REBOOT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  Boot configuration has been updated (nvidia-drm.modeset=1)."
    echo "  You MUST reboot for the kernel parameter to take effect."
    echo ""
    if [ "$NEEDS_RELOGIN" -eq 1 ]; then
      echo "  Additionally, user groups were updated (video/input/wheel)."
    fi
    echo ""
    read -p "Reboot now? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      info "Rebooting..."
      sleep 2
      systemctl reboot
    else
      echo ""
      echo "  Remember to reboot before continuing!"
      echo ""
    fi
  elif [ "$NEEDS_RELOGIN" -eq 1 ]; then
    echo ""
    echo "================================================================"
    echo "  IMPORTANT: LOG OUT REQUIRED"
    echo "================================================================"
    echo ""
    echo "  User groups have been updated. You MUST log out and log back in"
    echo "  for the changes to take effect."
    echo ""
    read -r -p "Press Enter to exit (remember to log out)..."
  else
    echo ""
    echo "================================================================"
    echo "  SETUP COMPLETE"
    echo "================================================================"
    echo ""
    echo "  Dependencies, GPU configuration, and session switching are ready."
    echo ""
    echo "  To switch to Gaming Mode: Press Super+Alt+G"
    echo "  To return to Desktop:     Steam > Power > Exit to Desktop"
    echo ""
  fi

  echo ""
  read -p "Run installation verification? [Y/n]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    verify_installation
  fi
}

show_help() {
  echo "Super Shift S Gaming Mode Installer v${Super_Shift_S_VERSION}"
  echo "Fedora / KDE Plasma / plasmalogin Edition (Nobara)"
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --help, -h      Show this help message"
  echo "  --verify, -v    Run verification only (check all files and permissions)"
  echo "  --version       Show version number"
  echo ""
  echo "Without options, runs the full installation/setup process."
  echo ""
  echo "Adapted for Fedora/KDE Plasma/plasmalogin (Nobara)."
  echo "Gamescope is built from source (not available in Fedora repos)."
  echo "ChimeraOS session scripts are cloned from GitHub."
  echo ""
}

case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --verify|-v)
    echo "Running verification only..."
    verify_installation
    exit $?
    ;;
  --version)
    echo "Super Shift S Gaming Mode Installer v${Super_Shift_S_VERSION}"
    exit 0
    ;;
  "")
    # Run setup; if it fails partway through, the fallback below still creates critical files
    execute_setup || true
    # Always ensure critical permission files exist, even if setup failed/aborted
    sudo -v 2>/dev/null || sudo -v 2>/dev/null || true
    ensure_critical_permissions
    ;;
  *)
    echo "Unknown option: $1"
    echo "Use --help for usage information."
    exit 1
    ;;
esac
