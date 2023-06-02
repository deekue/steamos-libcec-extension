#!/bin/bash
#
# Systemd system extension for libcec on SteamOS
#
# h/t:
# https://blogs.igalia.com/berto/2022/09/13/adding-software-to-the-steam-deck-with-systemd-sysext/
# https://www.reddit.com/r/SteamDeck/comments/10nksyr/adding_hdmicec_to_a_dock_using_a_pulseeight_usb/j6a9k3z/?context=3
# https://wiki.archlinux.org/title/Power_management#Combined_suspend/resume_service_file
# https://github.com/Pulse-Eight/libcec/tree/master/systemd
# https://www.psdn.io/posts/systemd-shutdown-unit/
# https://github.com/flatcar/sysext-bakery

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
ensure_sysext_unit_file="/etc/systemd/system/ensure-sysext.service"

# https://github.com/Pulse-Eight/libcec/blob/master/include/cectypes.h#L829
declare -A CEC_LOG_LEVELS=(
  [ERROR]=1
  [WARNING]=2
  [NOTICE]=4
  [TRAFFIC]=8
  [DEBUG]=16
  [ALL]=31
)
CEC_LOG_LEVEL="NOTICE"

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
  local -r log_level="${CEC_LOG_LEVELS[$CEC_LOG_LEVEL]}"
  local -r cmd="$bin_path -t p -o $osd_name -s -d $log_level"

  mkdir -p "$unit_path"

  cat <<EOF > "$unit_path/cec-active-source.service"
[Unit]
Description=Set this device to the CEC Active Source
Requires=systemd-sysext.service
[Service]
Type=oneshot
ExecStartPre=-/bin/sh -c 'echo "on 0" | $cmd'
ExecStart=-/bin/sh -c 'echo "as" | $cmd'
EOF

  cat <<EOF > "$unit_path/cec-power-tv.service"
[Unit]
Description=Use CEC to power on/off TV at boot/shutdown
After=systemd-sysext.service
Requires=systemd-sysext.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/bin/sh -c 'echo "on 0" | $cmd ; sleep 1'
ExecStart=-/bin/sh -c 'echo "as" | $cmd'
ExecStop=-/bin/sh -c 'echo "standby 0" | $cmd'
[Install]
WantedBy=multi-user.target
EOF

  power_dropin="$unit_path/multi-user.target.d/10-cec-power-tv.conf"  
  mkdir -p "$(dirname -- "$power_dropin")"
  cat <<EOF > "$power_dropin"
[Unit]
Upholds=cec-power-tv.service
EOF
  
  # TODO detect if device is active source and only then put screen on standby
  cat <<EOF > "$unit_path/cec-sleep.service"
[Unit]
Description=Use CEC to power on/off TV on resume/sleep
Before=sleep.target
Requires=systemd-sysext.service
StopWhenUnneeded=yes
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/bin/sh -c 'echo "standby 0" | $cmd'
ExecStop=-/bin/sh -c 'echo "on 0" | $cmd'
ExecStop=-/bin/sh -c 'echo "as" | $cmd'
[Install]
WantedBy=sleep.target
EOF

  sleep_dropin="$unit_path/sleep.target.d/10-cec-sleep.conf"  
  mkdir -p "$(dirname -- "$sleep_dropin")"
  cat <<EOF > "$sleep_dropin"
[Unit]
Upholds=cec-sleep.service
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

function generate_ensure_sysext {
  local -r unit_file="${1:?arg1 is unit file}"

  # https://github.com/flatcar/init/raw/flatcar-master/systemd/system/ensure-sysext.service
  cat <<EOF | sudo tee "$unit_file" > /dev/null
[Unit]
BindsTo=systemd-sysext.service
After=systemd-sysext.service
DefaultDependencies=no
# Keep in sync with systemd-sysext.service
ConditionDirectoryNotEmpty=|/etc/extensions
ConditionDirectoryNotEmpty=|/run/extensions
ConditionDirectoryNotEmpty=|/var/lib/extensions
ConditionDirectoryNotEmpty=|/usr/local/lib/extensions
ConditionDirectoryNotEmpty=|/usr/lib/extensions
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/systemctl daemon-reload
ExecStart=/usr/bin/systemctl restart --no-block sockets.target timers.target multi-user.target
[Install]
WantedBy=sysinit.target
EOF

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

  generate_ensure_sysext "$ensure_sysext_unit_file"
  sudo systemctl enable --now ensure-sysext.service 
}

function cmd_install_ext {
  local -r ext_file="${1:?arg1 is extension file}"
  local -r ext_name="${2:?arg2 is extension name}"

  cp "$ext_file" "$EXT_DIR/${ext_name}.raw"
  sudo systemctl restart systemd-sysext ensure-sysext
}

function cmd_uninstall_ext {
  local -r ext_name="${1:?arg1 is extension name}"

  rm "$EXT_DIR/${ext_name}.raw" || true
  sudo systemctl restart systemd-sysext ensure-sysext
}

function cmd_update_ext {
  local -r ext_file="${1:?arg1 is extension file}"
  local -r ext_name="${2:?arg2 is extension name}"

  cp "$ext_file" "$EXT_DIR/${ext_name}.raw"
  sudo systemctl restart systemd-sysext ensure-sysext
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

