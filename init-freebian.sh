#!/bin/bash
# init-freebian.sh - generates the complete FreeBian live-build project tree.
# Idempotent: every file is rewritten on each run; directories are created with mkdir -p.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${FREEBIAN_PROJECT_DIR:-${SCRIPT_DIR}/freebian-build}"
COSMIC_REPO_URL="${FREEBIAN_COSMIC_REPO_URL:-https://rickysarraf.github.io/debian-cosmic/}"
COSMIC_KEY_URL="${FREEBIAN_KEY_URL:-https://rickysarraf.github.io/debian-cosmic/debian-cosmic.gpg}"
COSMIC_SUITE="${FREEBIAN_COSMIC_SUITE:-unstable}"

log() { printf '[init-freebian] %s\n' "$*"; }
die() { printf '[init-freebian] ERROR: %s\n' "$*" >&2; exit 1; }

for tool in curl gpg python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' is missing on the host (apt-get install curl gnupg python3)"
done

log "Creating project hierarchy in ${PROJECT_DIR}"
mkdir -p \
    "${PROJECT_DIR}/auto" \
    "${PROJECT_DIR}/config/package-lists" \
    "${PROJECT_DIR}/config/archives" \
    "${PROJECT_DIR}/config/hooks/live" \
    "${PROJECT_DIR}/config/includes.chroot/etc/default" \
    "${PROJECT_DIR}/config/includes.chroot/etc/sysctl.d" \
    "${PROJECT_DIR}/config/includes.chroot/etc/live/config.conf.d" \
    "${PROJECT_DIR}/config/includes.chroot/etc/calamares/modules" \
    "${PROJECT_DIR}/config/includes.chroot/usr/share/calamares/branding/freebian" \
    "${PROJECT_DIR}/config/includes.chroot/usr/share/applications" \
    "${PROJECT_DIR}/config/includes.chroot/usr/local/bin" \
    "${PROJECT_DIR}/config/includes.chroot_before_packages/etc/apt/apt.conf.d" \
    "${PROJECT_DIR}/config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d"

cd "${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# COSMIC repository signing key
# ---------------------------------------------------------------------------
log "Fetching COSMIC repository key from ${COSMIC_KEY_URL}"
KEY_TMP="$(mktemp)"
trap 'rm -f "${KEY_TMP}"' EXIT
curl -fsSL --retry 3 --retry-delay 2 "${COSMIC_KEY_URL}" -o "${KEY_TMP}" \
    || die "could not download the COSMIC repository key"
[ -s "${KEY_TMP}" ] || die "downloaded COSMIC key is empty"

if head -c 64 "${KEY_TMP}" | grep -q -- '-----BEGIN PGP'; then
    gpg --batch --yes --dearmor -o config/archives/cosmic.key.chroot "${KEY_TMP}"
else
    cp -f "${KEY_TMP}" config/archives/cosmic.key.chroot
fi
gpg --show-keys --with-colons config/archives/cosmic.key.chroot | grep -q '^pub' \
    || die "COSMIC key file does not contain a valid public key"
chmod 0644 config/archives/cosmic.key.chroot

cat > config/archives/cosmic.list.chroot <<EOF
deb ${COSMIC_REPO_URL} ${COSMIC_SUITE} main
EOF

# Keep the third-party repo from replacing Debian system libraries: only cosmic* packages are preferred.
# Display managers that would conflict with cosmic-greeter are blocked outright.
cat > config/archives/cosmic.pref.chroot <<'EOF'
Package: *
Pin: origin rickysarraf.github.io
Pin-Priority: 100

Package: cosmic* xdg-desktop-portal-cosmic pop-launcher
Pin: origin rickysarraf.github.io
Pin-Priority: 700

Package: gdm3 sddm lightdm
Pin: release *
Pin-Priority: -1
EOF

# ---------------------------------------------------------------------------
# Package list
# ---------------------------------------------------------------------------
log "Writing package list"
cat > config/package-lists/freebian.list.chroot <<'EOF'
# ---- Kernel, live system, boot ----
linux-image-amd64
live-boot
live-config
live-config-systemd
systemd-sysv
systemd-oomd
user-setup
sudo
initramfs-tools
firmware-linux-free
firmware-linux-nonfree
firmware-misc-nonfree
firmware-realtek
firmware-iwlwifi
firmware-atheros
firmware-amd-graphics
intel-microcode
amd64-microcode

# ---- COSMIC desktop (third-party Debian COSMIC repository) ----
cosmic-epoch-monorepo
cosmic-utils-monorepo

# ---- Wayland, graphics, audio ----
mesa-vulkan-drivers
mesa-utils
libvulkan1
wayland-protocols
xwayland
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
libspa-0.2-bluetooth
bluez
xdg-user-dirs
xdg-utils
fonts-noto-core
fonts-noto-color-emoji
fonts-inter

# ---- System services ----
network-manager
polkitd
pkexec
dbus-broker
dbus-user-session
irqbalance
thermald
zram-tools
power-profiles-daemon
udisks2
flatpak
ca-certificates
curl
wget
locales
tzdata
keyboard-configuration
console-setup
bash-completion
nano
less

# ---- Applications ----
firefox-esr

# ---- Installer (Calamares) and its disk tooling ----
calamares
calamares-settings-debian
squashfs-tools
rsync
parted
gdisk
dosfstools
mtools
e2fsprogs
btrfs-progs
xfsprogs
ntfs-3g
cryptsetup
lvm2
efibootmgr
os-prober
grub-common
grub-efi-amd64-bin
grub-pc-bin
EOF

# ---------------------------------------------------------------------------
# includes.chroot_before_packages: applied before any package is unpacked
# ---------------------------------------------------------------------------
log "Writing apt/dpkg slimming configuration"
cat > config/includes.chroot_before_packages/etc/apt/apt.conf.d/00freebian-slim <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
Acquire::Languages "none";
EOF

# Copyright files are kept on purpose: removing them would break license compliance for redistributed images.
cat > config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/01_nodoc <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
EOF

# ---------------------------------------------------------------------------
# includes.chroot: tuning, live-config, identity
# ---------------------------------------------------------------------------
log "Writing system tuning files"
cat > config/includes.chroot/etc/default/zramswap <<'EOF'
# FreeBian zram swap configuration (zram-tools)
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

cat > config/includes.chroot/etc/sysctl.d/99-freebian-perf.conf <<'EOF'
# FreeBian memory and I/O tuning, tuned for zram-backed swap
vm.swappiness=180
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.page-cluster=0
EOF

cat > config/includes.chroot/etc/hostname <<'EOF'
freebian
EOF

cat > config/includes.chroot/etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   freebian

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

cat > config/includes.chroot/etc/live/config.conf.d/freebian.conf <<'EOF'
LIVE_USERNAME="freebian"
LIVE_USER_FULLNAME="FreeBian Live User"
LIVE_HOSTNAME="freebian"
LIVE_USER_DEFAULT_GROUPS="audio cdrom dip floppy video plugdev netdev powerdev scanner bluetooth sudo"
LIVE_LOCALES="en_US.UTF-8"
LIVE_TIMEZONE="UTC"
EOF

cat > config/includes.chroot/usr/local/bin/freebian-installer <<'EOF'
#!/bin/bash
# Launches Calamares with root privileges against the current Wayland session.
set -eu
if [ "$(id -u)" -eq 0 ]; then
    exec calamares "$@"
fi
exec sudo -E env \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    QT_QPA_PLATFORM="wayland;xcb" \
    calamares "$@"
EOF
chmod +x config/includes.chroot/usr/local/bin/freebian-installer

cat > config/includes.chroot/usr/share/applications/freebian-installer.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Install FreeBian
GenericName=System Installer
Comment=Install FreeBian to your computer
Exec=/usr/local/bin/freebian-installer
Icon=system-software-install
Terminal=false
Categories=System;
Keywords=install;installer;calamares;
EOF

# ---------------------------------------------------------------------------
# Calamares configuration
# ---------------------------------------------------------------------------
log "Writing Calamares configuration"
CAL="config/includes.chroot/etc/calamares"

cat > "${CAL}/settings.conf" <<'EOF'
---
modules-search: [ local ]

sequence:
  - show:
      - welcome
      - locale
      - keyboard
      - partition
      - users
      - summary
  - exec:
      - partition
      - mount
      - unpackfs
      - machineid
      - fstab
      - locale
      - keyboard
      - localecfg
      - users
      - networkcfg
      - hwclock
      - packages
      - shellprocess
      - initramfscfg
      - initramfs
      - grubcfg
      - bootloader
      - umount
  - show:
      - finished

branding: freebian
prompt-install: false
dont-chroot: false
oem-setup: false
disable-cancel: false
disable-cancel-during-exec: true
hide-back-and-next-during-exec: false
quit-at-end: false
EOF

cat > "${CAL}/modules/welcome.conf" <<'EOF'
---
showSupportUrl: true
showKnownIssuesUrl: false
showReleaseNotesUrl: false
requirements:
  requiredStorage: 12.0
  requiredRam: 2.0
  internetCheckUrl: https://deb.debian.org
  checkHasInternet: false
  check:
    - storage
    - ram
    - power
    - root
  required:
    - storage
    - ram
    - root
EOF

cat > "${CAL}/modules/locale.conf" <<'EOF'
---
region: "America"
zone: "New_York"
localeGenPath: /etc/locale.gen
geoip:
  style: none
EOF

cat > "${CAL}/modules/keyboard.conf" <<'EOF'
---
xOrgConfFileName: "/etc/X11/xorg.conf.d/00-keyboard.conf"
convertedKeymapPath: "/lib/kbd/keymaps/xkb"
writeEtcDefaultKeyboard: true
EOF

cat > "${CAL}/modules/partition.conf" <<'EOF'
---
efiSystemPartition: "/boot/efi"
efiSystemPartitionSize: 512M
userSwapChoices:
  - none
  - small
  - file
initialPartitioningChoice: erase
initialSwapChoice: small
defaultFileSystemType: "ext4"
availableFileSystemTypes: [ "ext4", "btrfs", "xfs" ]
drawNestedPartitions: false
alwaysShowPartitionLabels: true
allowManualPartitioning: true
EOF

cat > "${CAL}/modules/users.conf" <<'EOF'
---
defaultGroups:
  - users
  - sudo
  - audio
  - video
  - cdrom
  - plugdev
  - netdev
  - bluetooth
  - scanner
autologinGroup: autologin
doAutologin: false
sudoersGroup: sudo
setRootPassword: false
doReusePassword: true
passwordRequirements:
  minLength: 1
  maxLength: -1
allowWeakPasswords: true
allowWeakPasswordsDefault: true
user:
  shell: /bin/bash
  forbidden_names: [ root ]
hostname:
  location: EtcFile
  writeHostsFile: true
EOF

cat > "${CAL}/modules/mount.conf" <<'EOF'
---
extraMounts:
  - device: proc
    fs: proc
    mountPoint: /proc
  - device: sys
    fs: sysfs
    mountPoint: /sys
  - device: /dev
    mountPoint: /dev
    options: [ bind ]
  - device: tmpfs
    fs: tmpfs
    mountPoint: /run
  - device: /run/udev
    mountPoint: /run/udev
    options: [ bind ]
  - device: efivarfs
    fs: efivarfs
    mountPoint: /sys/firmware/efi/efivars
    efi: true
mountOptions:
  - filesystem: default
    options: [ defaults, noatime ]
  - filesystem: btrfs
    options: [ defaults, noatime, compress=zstd ]
ssdExtraMountOptions:
  ext4: [ discard ]
  btrfs: [ discard=async ]
EOF

cat > "${CAL}/modules/fstab.conf" <<'EOF'
---
mountOptions:
  default: defaults,noatime
  btrfs: defaults,noatime,compress=zstd
ssdExtraMountOptions:
  ext4: discard
  btrfs: discard=async
crypttabOptions: luks
EOF

cat > "${CAL}/modules/unpackfs.conf" <<'EOF'
---
unpack:
  - source: "/run/live/medium/live/filesystem.squashfs"
    sourcefs: "squashfs"
    destination: ""
EOF

cat > "${CAL}/modules/machineid.conf" <<'EOF'
---
systemd: true
dbus: true
symlink: true
EOF

cat > "${CAL}/modules/packages.conf" <<'EOF'
---
backend: apt
update_db: false
update_system: false
skip_if_no_internet: false
operations:
  - remove:
      - calamares
      - calamares-settings-debian
      - live-boot
      - live-boot-initramfs-tools
      - live-config
      - live-config-systemd
EOF

cat > "${CAL}/modules/shellprocess.conf" <<'EOF'
---
dontChroot: false
timeout: 120
script:
  - "rm -f /etc/sudoers.d/live"
  - "rm -f /etc/live/config.conf.d/freebian.conf"
  - "rm -f /usr/share/applications/freebian-installer.desktop"
  - "rm -f /usr/local/bin/freebian-installer"
  - "/usr/local/sbin/freebian-brand"
EOF

cat > "${CAL}/modules/initramfs.conf" <<'EOF'
---
kernel: all
EOF

cat > "${CAL}/modules/bootloader.conf" <<'EOF'
---
efiBootLoader: "grub"
kernel: "/vmlinuz"
img: "/initrd.img"
fallback: "/initrd.img"
timeout: 10
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "grub-probe"
efiBootMgr: "efibootmgr"
installEFIFallback: true
efiBootloaderId: "FreeBian"
bootloaderEntryName: "FreeBian"
EOF

cat > "${CAL}/modules/grubcfg.conf" <<'EOF'
---
overwrite: true
prefer_grub_d: false
always_use_defaults: false
kernel_params: [ "quiet", "splash" ]
defaults:
  GRUB_TIMEOUT: 5
  GRUB_DEFAULT: "0"
  GRUB_DISTRIBUTOR: "FreeBian"
  GRUB_DISABLE_OS_PROBER: "false"
EOF

cat > "${CAL}/modules/umount.conf" <<'EOF'
---
srcLog: "/root/.cache/calamares/session.log"
destLog: "/var/log/installation.log"
EOF

cat > "${CAL}/modules/finished.conf" <<'EOF'
---
restartNowEnabled: true
restartNowChecked: false
restartNowCommand: "systemctl -i reboot"
EOF

BR="config/includes.chroot/usr/share/calamares/branding/freebian"
cat > "${BR}/branding.desc" <<'EOF'
---
componentName: freebian

welcomeStyleCalamares: true
welcomeExpandingLogo: true
windowExpanding: normal
windowSize: 900px,560px
windowPlacement: center

strings:
  productName: FreeBian
  shortProductName: FreeBian
  version: "1.0"
  shortVersion: "1.0"
  versionedName: FreeBian 1.0
  shortVersionedName: FreeBian 1.0
  bootloaderEntryName: FreeBian
  productUrl: https://www.debian.org/
  supportUrl: https://www.debian.org/support
  knownIssuesUrl: https://www.debian.org/Bugs/
  releaseNotesUrl: https://www.debian.org/releases/

images:
  productLogo: "logo.png"
  productIcon: "icon.png"
  productWelcome: "welcome.png"

slideshow: "show.qml"
slideshowAPI: 2

style:
  sidebarBackground: "#0f1f4d"
  sidebarText: "#ffffff"
  sidebarTextSelect: "#3b82f6"
  sidebarTextHighlight: "#1d4ed8"
EOF

cat > "${BR}/show.qml" <<'EOF'
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0f1f4d"
        }
        Text {
            anchors.centerIn: parent
            text: "Installing FreeBian"
            color: "#ffffff"
            font.pixelSize: 32
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0f1f4d"
        }
        Text {
            anchors.centerIn: parent
            text: "Debian base. COSMIC desktop."
            color: "#ffffff"
            font.pixelSize: 28
        }
    }
}
EOF

log "Generating FreeBian logo images"
python3 - "${BR}" <<'PYEOF'
import struct
import sys
import zlib

out = sys.argv[1]


def write_png(path, w, h, pixel):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel(x, y, w, h))

    def chunk(tag, data):
        body = struct.pack(">I", len(data)) + tag + data
        return body + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(blob)


def pixel(x, y, w, h):
    s = min(w, h)
    ox = (w - s) / 2.0
    oy = (h - s) / 2.0
    u = (x - ox) / s
    v = (y - oy) / s
    t = y / float(h)
    r = int(0x1B + (0x3B - 0x1B) * t)
    g = int(0x3A + (0x82 - 0x3A) * t)
    b = int(0x8A + (0xF6 - 0x8A) * t)
    if 0.0 <= u <= 1.0 and 0.0 <= v <= 1.0:
        stem = 0.30 <= u <= 0.42 and 0.20 <= v <= 0.80
        top = 0.30 <= u <= 0.72 and 0.20 <= v <= 0.32
        mid = 0.30 <= u <= 0.62 and 0.46 <= v <= 0.57
        if stem or top or mid:
            return (255, 255, 255, 255)
    return (r, g, b, 255)


write_png(out + "/logo.png", 256, 256, pixel)
write_png(out + "/icon.png", 64, 64, pixel)
write_png(out + "/welcome.png", 640, 360, pixel)
PYEOF

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
log "Writing chroot hooks"

cat > config/hooks/live/0100-cosmic-repo.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Persist the COSMIC repository in the installed system with a deb822 source and a keyring in /etc/apt/keyrings.
set -e

install -d -m 0755 /etc/apt/keyrings

KEY_SRC=""
for candidate in /etc/apt/trusted.gpg.d/*cosmic*; do
    if [ -s "$candidate" ]; then
        KEY_SRC="$candidate"
        break
    fi
done

if [ -n "$KEY_SRC" ]; then
    install -m 0644 "$KEY_SRC" /etc/apt/keyrings/debian-cosmic.gpg
elif [ -s /etc/apt/keyrings/debian-cosmic.gpg ]; then
    :
else
    echo "FreeBian: COSMIC repository key was not installed by live-build" >&2
    ls -la /etc/apt/trusted.gpg.d/ >&2 || true
    exit 1
fi

# Remove the build-time list so the source is not configured twice.
rm -f /etc/apt/sources.list.d/cosmic.list

cat > /etc/apt/sources.list.d/debian-cosmic.sources <<'EOF'
Types: deb
URIs: https://rickysarraf.github.io/debian-cosmic/
Suites: unstable
Components: main
Signed-By: /etc/apt/keyrings/debian-cosmic.gpg
EOF

install -d -m 0755 /etc/apt/preferences.d
cat > /etc/apt/preferences.d/freebian-cosmic <<'EOF'
Package: *
Pin: origin rickysarraf.github.io
Pin-Priority: 100

Package: cosmic* xdg-desktop-portal-cosmic pop-launcher
Pin: origin rickysarraf.github.io
Pin-Priority: 700

Package: gdm3 sddm lightdm
Pin: release *
Pin-Priority: -1
EOF
rm -f /etc/apt/preferences.d/cosmic.pref

export DEBIAN_FRONTEND=noninteractive
apt-get update
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0200-cosmic-extras.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Install individual COSMIC components and Qt Wayland support when the repository ships them as separate packages.
# Missing optional packages are reported, not fatal; the hard requirements are verified in 0390.
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update

OPTIONAL_PACKAGES="
cosmic-session
cosmic-comp
cosmic-panel
cosmic-launcher
cosmic-applets
cosmic-settings
cosmic-settings-daemon
cosmic-greeter
cosmic-files
cosmic-term
cosmic-edit
cosmic-store
cosmic-osd
cosmic-bg
cosmic-workspaces
xdg-desktop-portal-cosmic
qt6-wayland
qtwayland5
"

for pkg in $OPTIONAL_PACKAGES; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "FreeBian: $pkg already installed"
        continue
    fi
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "FreeBian: installing $pkg"
        apt-get install -y --no-install-recommends "$pkg" || echo "FreeBian: WARNING could not install $pkg"
    else
        echo "FreeBian: $pkg is not provided by any configured repository, skipping"
    fi
done
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0150-cosmic-diagnostics.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Prints what the COSMIC packages actually installed. Informational only; never fails the build.
set -e

echo "=== FreeBian diagnostics: COSMIC-related packages available in apt ==="
apt-cache search cosmic 2>/dev/null | sort | head -100 || true

echo "=== FreeBian diagnostics: installed COSMIC packages ==="
dpkg -l 2>/dev/null | grep -i -E 'cosmic|greetd|pop-launcher' || true

echo "=== FreeBian diagnostics: dependencies of cosmic-epoch-monorepo ==="
apt-cache depends cosmic-epoch-monorepo 2>/dev/null | head -60 || true

echo "=== FreeBian diagnostics: key files from cosmic-epoch-monorepo ==="
dpkg -L cosmic-epoch-monorepo 2>/dev/null \
    | grep -i -E 'systemd|wayland-sessions|xsessions|/bin/|libexec|greet|\.desktop$' | head -150 || true

echo "=== FreeBian diagnostics: sessions and greeter files on disk ==="
ls -la /usr/share/wayland-sessions /usr/share/xsessions 2>/dev/null || true
find /usr/lib/systemd /lib/systemd /etc/systemd /usr/bin /usr/libexec \
    -iname '*cosmic*' -o -iname '*greet*' 2>/dev/null | sort | head -100 || true
echo "=== FreeBian diagnostics end ==="
exit 0
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0250-locale.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
set -e

if [ -f /etc/locale.gen ]; then
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
else
    echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
fi
locale-gen
update-locale LANG=en_US.UTF-8
echo 'freebian' > /etc/hostname
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0300-services.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Display manager selection, fast-boot masks, and service enablement.
set -e
export DEBIAN_FRONTEND=noninteractive

unit_exists() {
    [ -e "/usr/lib/systemd/system/$1" ] || [ -e "/lib/systemd/system/$1" ] || [ -e "/etc/systemd/system/$1" ]
}

enable_optional() {
    if unit_exists "$1"; then
        systemctl enable "$1"
    else
        echo "FreeBian: unit $1 not present, skipping enable"
    fi
}

# --- Remove conflicting display managers if anything pulled them in ---
for dm in gdm3 sddm lightdm; do
    if dpkg -s "$dm" >/dev/null 2>&1; then
        apt-get purge -y "$dm"
    fi
done

# --- COSMIC greeter is the display manager ---
if unit_exists cosmic-greeter.service; then
    systemctl enable cosmic-greeter
    if [ ! -L /etc/systemd/system/display-manager.service ]; then
        for base in /usr/lib/systemd/system /lib/systemd/system; do
            if [ -e "$base/cosmic-greeter.service" ]; then
                ln -sf "$base/cosmic-greeter.service" /etc/systemd/system/display-manager.service
                break
            fi
        done
    fi
else
    echo "FreeBian: WARNING cosmic-greeter.service was not provided by the COSMIC packages." >&2
    echo "FreeBian: greeter-related files that do exist in the image:" >&2
    find /usr/lib/systemd /lib/systemd /etc/systemd /usr/bin /usr/libexec /usr/lib /usr/share/wayland-sessions \
        -iname '*greet*' 2>/dev/null >&2 || true
    echo "FreeBian: see the 0150 diagnostics above for the full COSMIC file list" >&2
fi
systemctl set-default graphical.target

# --- D-Bus broker ---
if unit_exists dbus-broker.service; then
    systemctl enable --force dbus-broker.service
    systemctl --global enable --force dbus-broker.service || true
else
    echo "FreeBian: dbus-broker.service is missing" >&2
    exit 1
fi

# --- Performance services ---
enable_optional systemd-oomd.service
enable_optional irqbalance.service
enable_optional thermald.service
enable_optional zramswap.service
enable_optional NetworkManager.service
enable_optional bluetooth.service
enable_optional power-profiles-daemon.service

# --- Fast boot: no network wait, no background apt jobs ---
systemctl mask NetworkManager-wait-online.service
systemctl mask systemd-networkd-wait-online.service
systemctl mask apt-daily.timer
systemctl mask apt-daily.service
systemctl mask apt-daily-upgrade.timer
systemctl mask apt-daily-upgrade.service
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0390-verify-cosmic.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Fail the build early if the COSMIC session is not actually present in the image.
set -e

missing=0

if ! ls /usr/share/wayland-sessions/cosmic*.desktop >/dev/null 2>&1; then
    echo "FreeBian: no COSMIC Wayland session file found in /usr/share/wayland-sessions" >&2
    missing=1
fi

for bin in cosmic-comp cosmic-session cosmic-panel; do
    if ! command -v "$bin" >/dev/null 2>&1 && [ ! -x "/usr/libexec/$bin" ] && [ ! -x "/usr/lib/$bin" ]; then
        echo "FreeBian: expected COSMIC binary '$bin' not found" >&2
        missing=1
    fi
done

if ! command -v calamares >/dev/null 2>&1; then
    echo "FreeBian: calamares binary not found" >&2
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    echo "FreeBian: COSMIC verification failed. Check build.log for the COSMIC repository package names." >&2
    exit 1
fi

echo "FreeBian: COSMIC verification passed"
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0400-branding.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# FreeBian identity. A dpkg diversion plus an APT post-invoke hook keep branding after package updates.
set -e

install -d -m 0755 /usr/local/sbin

cat > /usr/local/sbin/freebian-brand <<'EOF'
#!/bin/bash
# Idempotent: re-asserts FreeBian identity files. Safe to run at any time.
set -e

cat > /usr/lib/os-release <<'OSR'
PRETTY_NAME="FreeBian 1.0 (COSMIC)"
NAME="FreeBian"
VERSION_ID="1.0"
VERSION="1.0 (forky)"
VERSION_CODENAME=forky
ID=freebian
ID_LIKE=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://www.debian.org/Bugs/"
OSR

ln -sf ../usr/lib/os-release /etc/os-release

cat > /etc/lsb-release <<'LSB'
DISTRIB_ID=FreeBian
DISTRIB_RELEASE=1.0
DISTRIB_CODENAME=forky
DISTRIB_DESCRIPTION="FreeBian 1.0 (COSMIC)"
LSB

cat > /etc/issue <<'ISS'
FreeBian 1.0 (COSMIC) \n \l

ISS

cat > /etc/issue.net <<'ISN'
FreeBian 1.0 (COSMIC)
ISN

if [ -f /etc/default/grub ]; then
    if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
        sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="FreeBian"/' /etc/default/grub
    else
        echo 'GRUB_DISTRIBUTOR="FreeBian"' >> /etc/default/grub
    fi
fi
EOF
chmod 0755 /usr/local/sbin/freebian-brand

# Divert the files owned by base-files so package upgrades write to .distrib copies instead.
for f in /usr/lib/os-release /etc/issue /etc/issue.net; do
    if ! dpkg-divert --list "$f" | grep -q "$f"; then
        dpkg-divert --quiet --local --rename --add "$f"
    fi
done

cat > /etc/apt/apt.conf.d/99freebian-branding <<'EOF'
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/freebian-brand ]; then /usr/local/sbin/freebian-brand || true; fi"; };
EOF

/usr/local/sbin/freebian-brand

# Installed-system GRUB defaults
install -d -m 0755 /etc/default
if [ ! -f /etc/default/grub ]; then
    cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="FreeBian"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
EOF
fi
/usr/local/sbin/freebian-brand
FREEBIAN_HOOK_EOF

cat > config/hooks/live/0900-sysctl-check.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Confirm that the tuning files shipped by includes.chroot are in place.
set -e

for f in /etc/default/zramswap /etc/sysctl.d/99-freebian-perf.conf /etc/dpkg/dpkg.cfg.d/01_nodoc /etc/apt/apt.conf.d/00freebian-slim; do
    if [ ! -s "$f" ]; then
        echo "FreeBian: expected file $f is missing or empty" >&2
        exit 1
    fi
done
grep -q '^ALGO=zstd' /etc/default/zramswap
grep -q '^PERCENT=50' /etc/default/zramswap
grep -q 'vm.swappiness=180' /etc/sysctl.d/99-freebian-perf.conf
FREEBIAN_HOOK_EOF

cat > config/hooks/live/9999-cleanup.hook.chroot <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Final size reduction. Must remain the last chroot hook.
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get autoremove -y --purge || true
apt-get clean

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*
rm -rf /var/cache/debconf/*-old
rm -f /var/lib/dpkg/*-old
rm -f /var/cache/ldconfig/aux-cache

# Documentation already on disk (dpkg 01_nodoc only affects future unpacks). Copyright files are kept.
find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null || true
find /usr/share/doc -type l -delete 2>/dev/null || true
find /usr/share/doc -mindepth 1 -type d -empty -delete 2>/dev/null || true
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/groff/* /usr/share/lintian/* /usr/share/linda/*

# Logs and temporary data
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf /tmp/* /var/tmp/*
rm -f /root/.bash_history
FREEBIAN_HOOK_EOF

log "Writing binary hook for ISO boot menu branding"
cat > config/hooks/live/0500-bootmenu-branding.hook.binary <<'FREEBIAN_HOOK_EOF'
#!/bin/bash
# Runs on the host inside the live-build directory after the bootloaders are generated.
# Rewrites the ISO's syslinux and GRUB menu titles.
set -e

patch_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -i \
        -e 's/Debian GNU\/Linux/FreeBian/g' \
        -e 's/Debian Live/FreeBian Live/g' \
        -e 's/Live system (amd64)/FreeBian Live (amd64)/g' \
        -e 's/^\( *menu title \).*/\1FreeBian/' \
        -e 's/^\( *MENU TITLE \).*/\1FreeBian/' \
        "$f"
}

for d in binary/isolinux binary/syslinux; do
    if [ -d "$d" ]; then
        for f in "$d"/*.cfg; do
            patch_file "$f"
        done
    fi
done

for f in binary/boot/grub/grub.cfg binary/boot/grub/live.cfg binary/boot/grub/theme.cfg; do
    patch_file "$f"
done

if [ -f binary/boot/grub/grub.cfg ] && ! grep -q 'FreeBian' binary/boot/grub/grub.cfg; then
    if ! grep -q '^set menu_title' binary/boot/grub/grub.cfg; then
        sed -i '1i set menu_title="FreeBian"' binary/boot/grub/grub.cfg
    fi
fi
FREEBIAN_HOOK_EOF

# ---------------------------------------------------------------------------
# Permissions and summary
# ---------------------------------------------------------------------------
log "Setting hook permissions"
chmod +x config/hooks/live/*.hook.chroot config/hooks/live/*.hook.binary

log "Project tree:"
if command -v tree >/dev/null 2>&1; then
    tree -a --noreport "${PROJECT_DIR}"
else
    (cd "${PROJECT_DIR}" && find . -mindepth 1 | LC_ALL=C sort | sed 's|[^/]*/|  |g')
fi

log "Done. Next: run ./build-freebian.sh"
