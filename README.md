# steamos-libcec-extension

Add HDMI CEC support to SteamOS, requires [supported
hardware](https://github.com/Pulse-Eight/libcec#supported-hardware).

[install.sh](https://github.com/deekue/steamos-libcec-extension/raw/main/install.sh) sets up [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html) then builds and installs an extension that includes [libcec](https://github.com/Pulse-Eight/libcec) and systemd unit files.

The included systemd unit files will:
- power on, resume: power on the TV and set SteamDeck as active source 
- power off, sleep: set the TV to standby
- TODO: dock,undock

## Installation

1. Install supported hardware (tested with [PulseEight USB-CEC Adapter](https://www.pulse-eight.com/p/104/usb-hdmi-cec-adapter) )
1. Switch to Desktop Mode
1. open a terminal (Ctrl+Alt+t)
1. `curl -fsSLO https://github.com/deekue/steamos-libcec-extension/raw/main/cec-install.sh`
1. `chmod +x cec-install.sh`
1. `./cec-install.sh install`

## Usage

```
Usage: cec-install.sh <install|update|uninstall>

install   install extension and activate
update    update extension and activate
uninstall deactive extension and remove
```

