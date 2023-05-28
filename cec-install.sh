#!/bin/bash
#
# Systemd system extension for libcec on SteamOS
#
# h/t:
# https://blogs.igalia.com/berto/2022/09/13/adding-software-to-the-steam-deck-with-systemd-sysext/
# https://www.reddit.com/r/SteamDeck/comments/10nksyr/adding_hdmicec_to_a_dock_using_a_pulseeight_usb/j6a9k3z/?context=3
# https://wiki.archlinux.org/title/Power_management#Combined_suspend/resume_service_file
# https://github.com/Pulse-Eight/libcec/tree/master/systemd

set -eEuo pipefail

# are we building on SteamOS
if ! grep -q '^ID=steamos' /etc/os-release ; then
  echo "Build on a SteamOS system" >&2
  exit 1
fi

BASE_DIR="$HOME/Downloads"
EXT_DIR="$HOME/.extensions"
EXT_NAME="libcec"
OSD_NAME="Steam"
LOG_FILE="/tmp/${EXT_NAME}-ext.log"
declare -A PACKAGES=(
  [community/libcec]=6.0.2-3
  [community/p8-platform]=2.1.0.1-4
)
steamos_repo="https://steamdeck-packages.steamos.cloud/archlinux-mirror"

# return section and version for pkg
function pkg_details {
  local -r pkg="${1:?arg1 is pkg}"

  for section_pkg in "${!PACKAGES[@]}" ; do
    if [[ "${section_pkg#*/}" == "$pkg" ]] ; then
      version="${PACKAGES[$section_pkg]}"
      section="${section_pkg%/*}"
      echo "$section/$version"
      break
    fi
  done
}

function extract_package {
  local -r url="${1:?arg1 is url}"
  local -r pkg_file="${2:?arg2 is dest file}"
  local -r build_path="${3:?arg3 is build path}"

  curl -fsSL \
    --time-cond "$pkg_file" \
    --create-dirs --output "$pkg_file" \
    "$url" \
    >> "$LOG_FILE"
  # extract to build dir
  tar -C "$build_path" -xaf "$pkg_file" \
    >> "$LOG_FILE"
}

function generate_systemd_units {
  local -r build_path="${1:?arg1 is build path}"
  local -r osd_name="${2:-Steam}"
  local -r unit_path="$build_path/usr/lib/systemd/system"
  local -r bin_path="/usr/bin/cec-client"

  mkdir -p "$unit_path"

  cat <<EOF > "$unit_path/cec-active-source.service"
[Unit]
Description=Set this device to the CEC Active Source
[Service]
Type=oneshot
ExecStartPre=-/bin/sh -c 'echo "on 0" | $bin_path -t p -o $osd_name -s'
ExecStart=-/bin/sh -c 'echo "as" | $bin_path -t p -o $osd_name -s'
EOF

  cat <<EOF > "$unit_path/cec-active-source.timer"
[Unit]
Description=Trigger cec-active-source at boot
[Timer]
OnBootSec=1
OnStartupSec=1
[Install]
WantedBy=timers.target
EOF

  cat <<EOF > "$unit_path/cec-poweroff-tv.service"
[Unit]
Description=Use CEC to power off TV
[Service]
Type=oneshot
ExecStart=-/bin/sh -c 'echo "standby 0" | $bin_path -t p -o $osd_name -s'
ExecStop=-/bin/sh -c 'echo "standby 0" | $bin_path -t p -o $osd_name -s'
[Install]
WantedBy=poweroff.target
EOF

  cat <<EOF > "$unit_path/cec-sleep.service"
[Unit]
Description=Use CEC to power on/off TV on resume/sleep
Before=sleep.target
StopWhenUnneeded=yes
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/bin/sh -c 'echo "standby 0" | $bin_path -t p -o $osd_name -s'
ExecStop=-/bin/sh -c 'echo "on 0" | $bin_path -t p -o $osd_name -s'
ExecStop=-/bin/sh -c 'echo "as" | $bin_path -t p -o $osd_name -s'
[Install]
WantedBy=sleep.target
EOF

}

# returns extension image file name
# so trap all other output
function cmd_build_ext {
  local -r ext_name="${1:?arg1 is ext_name}"
  local -r osd_name="${2:-Steam}"

  build_path="$(mktemp -d)"  # TODO add trap for cleanup
  main_pkg_details="$(pkg_details "$ext_name")"
  ext_version="${main_pkg_details#*/}"
  ext_section="${main_pkg_details%/*}"

  section_ver="$(sed -En '/^\['"$ext_section"'(.*)\].*$/ s//\1/p' /etc/pacman.conf)"
  arch="$(uname -m)"
  steamos_version="$(sed -En '/^VERSION_ID="(.*)"/ s//\1/p' /etc/os-release)"

  # download and extract packages
  for section_pkg in "${!PACKAGES[@]}" ; do
    pkg_version="${PACKAGES[$section_pkg]}"
    pkg="${section_pkg#*/}"
    section="${section_pkg%/*}"

    # Source
    pkg_path="${section}${section_ver}/os/$arch"
    filename="${pkg}-${pkg_version}-${arch}.pkg.tar.zst"
    url="$steamos_repo/$pkg_path/$filename"

    # Destination
    pkg_file="$BASE_DIR/$pkg_path/$filename"

    extract_package "$url" "$pkg_file" "$build_path"
  done

  # add release file
  ext_path="$build_path/usr/lib/extension-release.d/"
  mkdir -p "$ext_path"
  cat <<EOF > "$ext_path/extension-release.$ext_name" 
ID=steamos 
VERSION_ID=$steamos_version
EOF

  generate_systemd_units "$build_path" "$osd_name" \
    >> "$LOG_FILE"

  # build extension image
  ext_file="$BASE_DIR/${ext_name}-${ext_version}_${section}${section_ver}_steamos-${steamos_version}.raw"

  mksquashfs "$build_path" "$ext_file" \
    -quiet \
    -noappend \
    -no-progress \
    -all-root \
    >> "$LOG_FILE"

  echo "$ext_file"
}

function cmd_setup {
  # setup extensions dir and symlink
  mkdir -p "$EXT_DIR"
  if [[ ! -L /var/lib/extensions ]] ; then
    sudo ln -svT "$EXT_DIR" /var/lib/extensions
  fi

  # enable and start the systemd extension unit
  if systemctl show systemd-sysext | grep -q '^UnitFileState=disabled' ; then
    sudo systemctl enable systemd-sysext
  fi
  if systemctl show systemd-sysext | grep -q '^ActiveState=inactive' ; then
    sudo systemctl start systemd-sysext
  fi
}

function control_systemd_units {
  local -r action="${1:?arg1 is systemctl action}"

  declare -a unit_files=(
    cec-active-source.timer
    cec-poweroff-tv.service
    cec-sleep.service
  )
  for unit in "${unit_files[@]}" ; do
    case "$action" in
      enable)  sudo systemctl enable "$unit";;
      disable) sudo systemctl disable "$unit" || true;;
    esac
  done
}

function installed_extensions {
  systemd-sysext list --json=short
}

function num_installed_extensions {
  installed_extensions \
    | jq -r '. | length'
}

function cmd_install_ext {
  local -r ext_file="${1:?arg1 is extension file}"
  local -r ext_name="${2:?arg2 is extension name}"

  cp "$ext_file" "$EXT_DIR/${ext_name}.raw"
  if [[ "$(num_installed_extensions)" -gt 0 ]] ; then
    sudo systemd-sysext refresh
  else
    sudo systemd-sysext merge
  fi
  sudo systemctl daemon-reload
  control_systemd_units "enable"
}

function cmd_uninstall_ext {
  local -r ext_name="${1:?arg1 is extension name}"

  control_systemd_units "disable"
  sudo systemctl daemon-reload
  rm "$EXT_DIR/${ext_name}.raw" || true
  sudo systemd-sysext refresh
}

function cmd_update_ext {
  local -r ext_file="${1:?arg1 is extension file}"
  local -r ext_name="${2:?arg2 is extension name}"

  cp "$ext_file" "$EXT_DIR/${ext_name}.raw"
  sudo systemd-sysext refresh
  sudo systemctl daemon-reload
}

function usage {
  cat <<EOF >&2
Usage: $(basename -- "$0") <install|update|uninstall>

install   install extension and activate
update    update extension and activate
uninstall deactive extension and remove
EOF

  exit 1
}

case "${1:-}" in
  install)
    cmd_setup
    ext_file="$(cmd_build_ext "$EXT_NAME" "$OSD_NAME")"
    cmd_install_ext "$ext_file" "$EXT_NAME"
    ;;
  update)
    ext_file="$(cmd_build_ext "$EXT_NAME" "$OSD_NAME")"
    cmd_update_ext "$ext_file" "$EXT_NAME"
    ;;
  uninstall)
    cmd_uninstall_ext "$EXT_NAME"
    ;;
  *)
    usage
    ;;
esac

