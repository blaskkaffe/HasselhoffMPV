#!/usr/bin/env bash
# ==============================================================================
#  build-usb.sh  -  builds the media-player USB stick
#
#  Result: a stick with TWO partitions
#    1. MEDIAPLAYER  (FAT32, first)  your videos, mediaplayer.lua, config.cfg, schedule.cfg ...
#                                    -> everything you edit lives here; Windows,
#                                       macOS and Linux can all read/write it
#    2. system       (ext4, last 6 GB) a minimal Linux that boots straight into the
#                                    player. No login, no password, read-only
#                                    (changes live in RAM only, so pulling the
#                                    power can never damage it).
#  Boots on 64-bit PCs, both UEFI (Secure Boot OFF) and old BIOS/CSM.
#
#  Run this on a Linux computer (Ubuntu/Debian; a live USB or VM is fine), as root:
#
#     sudo ./build-usb.sh /dev/sdX                      write straight to the stick
#     sudo ./build-usb.sh --image stick.img --size 16G  make a disk image instead
#
#  Options:
#     --tz   Europe/Stockholm   time zone (used by the scheduler)       [UTC]
#     --kbd  se                 keyboard layout (us, se, de, fr, ...)   [us]
#     --root-gb 6               size of the system partition in GB      [6]
#     --content DIR             copy this folder into the stick's content/ folder
#     --mirror URL              Ubuntu mirror                           [archive.ubuntu.com]
#     --yes                     do not ask for confirmation
#     --allow-fixed-disk        allow a target that does not look like a USB stick
#
#  THIS ERASES THE TARGET DEVICE COMPLETELY.
# ==============================================================================
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITE="noble"                                  # Ubuntu 24.04 LTS (has mpv 0.37)
MIRROR="http://archive.ubuntu.com/ubuntu"
ROOT_GB=6
TZNAME="UTC"
KBD="us"
LABEL="MEDIAPLAYER"
DEV=""; IMAGE=""; SIZE=""; CONTENT=""; ASSUME_YES=0; ALLOW_FIXED=0

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,2\}//'; exit "${1:-0}"; }

# ----------------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --image)    IMAGE="$2"; shift 2 ;;
        --size)     SIZE="$2"; shift 2 ;;
        --tz)       TZNAME="$2"; shift 2 ;;
        --kbd)      KBD="$2"; shift 2 ;;
        --root-gb)  ROOT_GB="$2"; shift 2 ;;
        --content)  CONTENT="$2"; shift 2 ;;
        --mirror)   MIRROR="$2"; shift 2 ;;
        --yes)      ASSUME_YES=1; shift ;;
        --allow-fixed-disk) ALLOW_FIXED=1; shift ;;
        -h|--help)  usage 0 ;;
        -*)         die "unknown option $1 (see --help)" ;;
        *)          DEV="$1"; shift ;;
    esac
done

[ "$(id -u)" = 0 ] || die "run as root:  sudo $0 ..."
[ -n "$DEV" ] || [ -n "$IMAGE" ] || usage 1
[ -z "$DEV" ] || [ -z "$IMAGE" ] || die "give EITHER a device OR --image, not both"
[ -z "$IMAGE" ] || [ -n "$SIZE" ] || die "--image needs --size (for example --size 16G)"
for f in mediaplayer.lua config.cfg schedule.cfg README.txt; do
    [ -f "$HERE/$f" ] || die "$f must be in the same folder as this script ($HERE)"
done
[ -z "$CONTENT" ] || [ -d "$CONTENT" ] || die "--content: $CONTENT is not a folder"
[ -e "/usr/share/zoneinfo/$TZNAME" ] || die "unknown time zone '$TZNAME' (example: Europe/Stockholm)"

# ----------------------------------------------------------------------- host tools
NEED=""
for pair in debootstrap:debootstrap parted:parted mkfs.vfat:dosfstools mkfs.ext4:e2fsprogs \
            grub-install:grub2-common grub-mkstandalone:grub2-common blkid:util-linux mcopy:mtools; do
    command -v "${pair%%:*}" >/dev/null 2>&1 || NEED="$NEED ${pair##*:}"
done
[ -d /usr/lib/grub/i386-pc ]       || NEED="$NEED grub-pc-bin"
[ -d /usr/lib/grub/x86_64-efi ]    || NEED="$NEED grub-efi-amd64-bin"
if [ ! -e /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then NEED="$NEED ubuntu-keyring"; fi
if [ -n "$NEED" ]; then
    command -v apt-get >/dev/null 2>&1 || die "please install these packages first:$NEED"
    say "Installing build tools:$NEED"
    DEBIAN_FRONTEND=noninteractive apt-get install -y $NEED
fi

# ----------------------------------------------------------------------- cleanup
MNT="/tmp/usbbuild.$$"; STAGE=""; LOOP_DISK=""
cleanup() {
    set +e
    for m in dev/pts dev proc sys run; do umount -l "$MNT/$m" 2>/dev/null; done
    umount "$MNT" 2>/dev/null
    [ -n "$LOOP_DISK" ] && losetup -d "$LOOP_DISK" 2>/dev/null
    rm -rf "$STAGE" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT
mkdir -p "$MNT"; STAGE="/tmp/usbstage.$$"; mkdir -p "$STAGE"   # files for the FAT32 partition are collected here

# ----------------------------------------------------------------------- target
if [ -n "$IMAGE" ]; then
    say "Creating image $IMAGE ($SIZE)"
    rm -f "$IMAGE"; truncate -s "$SIZE" "$IMAGE"
    LOOP_DISK="$(losetup -f --show -P "$IMAGE")"
    DISK="$LOOP_DISK"
else
    [ -b "$DEV" ] || die "$DEV is not a block device"
    DISK="$DEV"
    ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
    ROOT_PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 || true)"
    if [ -n "$ROOT_PK" ] && [ "/dev/$ROOT_PK" = "$DEV" ]; then die "$DEV is the disk this computer runs from!"; fi
    TRAN="$(lsblk -dno TRAN "$DEV" 2>/dev/null | head -n1 || true)"; RM="$(lsblk -dno RM "$DEV" 2>/dev/null | head -n1 || true)"
    if [ "$TRAN" != "usb" ] && [ "$RM" != "1" ] && [ "$ALLOW_FIXED" != 1 ]; then
        die "$DEV does not look like a USB stick (add --allow-fixed-disk if you are SURE)"
    fi
    echo; lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINT "$DEV"
    echo; echo "EVERYTHING on $DEV will be erased."
    if [ "$ASSUME_YES" != 1 ]; then
        read -r -p "Type the device name ($DEV) to continue: " ans
        [ "$ans" = "$DEV" ] || die "cancelled"
    fi
    for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do umount "$p" 2>/dev/null || true; done
    wipefs -a "$DEV" >/dev/null
fi

TOTAL_MIB=$(( $(blockdev --getsize64 "$DISK") / 1048576 ))
ROOT_MIB=$(( ROOT_GB * 1024 ))
DATA_END=$(( TOTAL_MIB - ROOT_MIB ))
[ "$DATA_END" -ge 1024 ] || die "the target is too small: ${TOTAL_MIB} MiB (need at least $(( ROOT_MIB + 1024 )) MiB)"

say "Partitioning (data FAT32 ${DATA_END} MiB + system ext4 ${ROOT_MIB} MiB)"
parted -s "$DISK" mklabel msdos
parted -s -a optimal "$DISK" mkpart primary fat32 1MiB "${DATA_END}MiB"
parted -s -a optimal "$DISK" mkpart primary ext4 "${DATA_END}MiB" 100%
parted -s "$DISK" set 1 boot on

# partition device nodes (some containers/VMs have no udev, so make sure they exist)
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true
base="$(basename "$DISK")"
case "$DISK" in *[0-9]) pfx="${DISK}p" ;; *) pfx="${DISK}" ;; esac
for n in 1 2; do
    node="${pfx}${n}"
    if [ ! -b "$node" ] && [ -r "/sys/block/$base/$(basename "$node")/dev" ]; then
        IFS=: read -r maj min < "/sys/block/$base/$(basename "$node")/dev"
        mknod "$node" b "$maj" "$min"
    fi
    for _ in 1 2 3 4 5; do [ -b "$node" ] && break; sleep 1; done
    [ -b "$node" ] || die "partition $node did not appear"
done
P_DATA="${pfx}1"; P_ROOT="${pfx}2"

say "Creating file systems"
mkfs.vfat -F 32 -n "$LABEL" "$P_DATA" >/dev/null
mkfs.ext4 -q -F -L kioskroot "$P_ROOT"
ROOT_UUID="$(blkid -s UUID -o value "$P_ROOT")"
mount "$P_ROOT" "$MNT"

# ----------------------------------------------------------------------- base system
say "Installing the base system ($SUITE) - this downloads about 1 GB"
CACHE="/var/cache/usbbuild-debootstrap"; mkdir -p "$CACHE"
ok=0
for attempt in 1 2 3 4; do      # mirrors sometimes drop a download: just try again (files are cached)
    if debootstrap --variant=minbase --components=main,universe --arch=amd64 --cache-dir="$CACHE" \
                   --include=ca-certificates,gnupg "$SUITE" "$MNT" "$MIRROR"; then ok=1; break; fi
    echo "debootstrap failed (attempt $attempt) - retrying in 5 s"; sleep 5
done
[ "$ok" = 1 ] || die "debootstrap failed - check the internet connection or try --mirror"

cat > "$MNT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe
deb $MIRROR $SUITE-updates main universe
deb http://security.ubuntu.com/ubuntu $SUITE-security main universe
EOF
echo "mediaplayer" > "$MNT/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 mediaplayer\n' > "$MNT/etc/hosts"

mount -t proc proc "$MNT/proc"; mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"; mount --bind /dev/pts "$MNT/dev/pts"
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"; chmod +x "$MNT/usr/sbin/policy-rc.d"
chr() { chroot "$MNT" env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"; }

# the kernel build scripts want to know the root device
cat > "$MNT/etc/fstab" <<EOF
# system (RAM overlay on top of it, see overlayroot) and the FAT32 data partition
UUID=$ROOT_UUID  /           ext4  defaults,noatime  0 1
LABEL=$LABEL     /mnt/player vfat  ro,nofail,noatime,utf8=1,uid=1000,gid=1000,umask=022,x-systemd.device-timeout=15s  0 0
EOF
mkdir -p "$MNT/mnt/player"

say "Installing the system packages (kernel, graphics, mpv, sound) - several minutes"
chr apt-get -o Acquire::Retries=5 update
chr apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
    linux-image-generic linux-firmware initramfs-tools overlayroot \
    systemd-sysv systemd-timesyncd systemd-resolved udev dbus dbus-user-session libpam-systemd \
    sudo kmod nano less iproute2 tzdata alsa-utils util-linux-extra \
    xserver-xorg-core xserver-xorg-input-libinput xinit x11-xkb-utils x11-xserver-utils \
    xserver-xorg-video-fbdev xserver-xorg-video-vesa \
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 mesa-va-drivers mesa-vdpau-drivers \
    mpv pipewire-audio

# ----------------------------------------------------------------------- user, login
say "Configuring the system"
chr useradd -m -s /bin/bash -G audio,video,render,input,plugdev kiosk 2>/dev/null \
  || chr useradd -m -s /bin/bash -G audio,video,render,input kiosk
chr passwd -d kiosk >/dev/null
chr passwd -l root  >/dev/null
echo 'kiosk ALL=(ALL) NOPASSWD:ALL' > "$MNT/etc/sudoers.d/kiosk"; chmod 440 "$MNT/etc/sudoers.d/kiosk"
touch "$MNT/home/kiosk/.hushlogin"; chr chown kiosk:kiosk /home/kiosk/.hushlogin

# automatic login on tty1
mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
cat > "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --noissue --skip-login --autologin kiosk %I $TERM
Type=idle
EOF
# no other virtual consoles, no Ctrl+Alt+Del, no SysRq: the keyboard only reaches the player
mkdir -p "$MNT/etc/systemd/logind.conf.d" "$MNT/etc/sysctl.d"
printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' > "$MNT/etc/systemd/logind.conf.d/kiosk.conf"
echo 'kernel.sysrq = 0' > "$MNT/etc/sysctl.d/90-kiosk.conf"
ln -sf /dev/null "$MNT/etc/systemd/system/ctrl-alt-del.target"
# journal in RAM only, quiet boot
mkdir -p "$MNT/etc/systemd/journald.conf.d"
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=20M\n' > "$MNT/etc/systemd/journald.conf.d/kiosk.conf"

# network (only used to keep the clock right) - never wait for it during boot
mkdir -p "$MNT/etc/systemd/network"
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n\n[DHCPv4]\nRouteMetric=100\n' > "$MNT/etc/systemd/network/20-wired.network"
chr systemctl enable systemd-networkd systemd-resolved systemd-timesyncd >/dev/null 2>&1 || true
chr systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
# sound server starts for the kiosk user
chr systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true

# clock: the PC's clock is expected to show LOCAL time (like Windows does)
printf '0.0 0 0.0\n0\nLOCAL\n' > "$MNT/etc/adjtime"
ln -sf "/usr/share/zoneinfo/$TZNAME" "$MNT/etc/localtime"; echo "$TZNAME" > "$MNT/etc/timezone"

# ----------------------------------------------------------------------- X server
mkdir -p "$MNT/etc/X11/xorg.conf.d"
cat > "$MNT/etc/X11/xorg.conf.d/10-kiosk.conf" <<'EOF'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
    Option "DontVTSwitch" "true"
    Option "DontZap"      "true"
EndSection
EOF

# ----------------------------------------------------------------------- kiosk scripts
mkdir -p "$MNT/opt/kiosk"
cat > "$MNT/opt/kiosk/session" <<'EOF'
#!/bin/sh
# Runs inside the X server. Starts the player and restarts it if it ever ends
# (Ctrl+q therefore RESTARTS the player). Everything it needs is on the FAT32
# partition, mounted read-only at /mnt/player.
DATA=/mnt/player
LOG=/tmp/kiosk-player.log      # (RAM only) what the player says; see USB-SETUP.txt

first_line() { [ -f "$1" ] && head -n 1 "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# wait for the data partition (up to 40 s)
i=0
while [ ! -f "$DATA/mediaplayer.lua" ] && [ "$i" -lt 40 ]; do
    mountpoint -q "$DATA" || sudo mount "$DATA" 2>/dev/null
    sleep 1; i=$((i + 1))
done

# time zone + clock (timezone.txt: first line = zone, optional line "rtc=utc")
TZN="$(first_line "$DATA/timezone.txt")"
RTC=local; grep -qi '^[[:space:]]*rtc[[:space:]]*=[[:space:]]*utc' "$DATA/timezone.txt" 2>/dev/null && RTC=utc
sudo /opt/kiosk/clock-setup "$TZN" "$RTC" >>"$LOG" 2>&1

# keyboard layout (keyboard.txt: us, se, de ...)
KBD="$(first_line "$DATA/keyboard.txt")"
setxkbmap "${KBD:-us}" >>"$LOG" 2>&1 || setxkbmap us

# sound: unmuted, full volume (best effort)
( for _ in 1 2 3 4 5 6 7 8 9 10; do
      wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null && wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 2>/dev/null && break
      sleep 1
  done ) &

while :; do
    if [ -f "$DATA/mediaplayer.lua" ]; then
        # extra mpv options, one per line, from mpv-options.txt
        set --
        if [ -f "$DATA/mpv-options.txt" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                case "$line" in ''|\#*) ;; *) set -- "$@" "$line" ;; esac
            done < "$DATA/mpv-options.txt"
        fi
        # (no window manager runs, so the window is sized to the whole screen by --geometry)
        mpv --no-config --no-terminal --log-file="$LOG" --msg-level=all=warn,mediaplayer=info \
            --script="$DATA/mediaplayer.lua" --script-opts=mediaplayer-root="$DATA" \
            --idle=yes --force-window=yes --keep-open=no \
            --fullscreen --geometry=100%x100%+0+0 --no-border \
            --no-input-default-bindings --no-osc --osd-level=0 --cursor-autohide=100 \
            --hwdec=auto-safe "$@" >/dev/null 2>&1
    else
        sleep 2
    fi
    [ -n "$KIOSK_ONCE" ] && break        # maintenance: run the player just once
    sleep 1
done
EOF
cat > "$MNT/opt/kiosk/clock-setup" <<'EOF'
#!/bin/sh
# root helper: apply the time zone and read the PC clock (local time or UTC)
tz="$1"; mode="$2"
if [ -n "$tz" ] && [ -e "/usr/share/zoneinfo/$tz" ]; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    echo "$tz" > /etc/timezone
fi
if [ "$mode" = utc ]; then hwclock --hctosys --utc 2>/dev/null; else hwclock --hctosys --localtime 2>/dev/null; fi
exit 0
EOF
chmod 755 "$MNT/opt/kiosk/session" "$MNT/opt/kiosk/clock-setup"

cat > "$MNT/etc/profile.d/kiosk.sh" <<'EOF'
# automatic start of the player on the first console (user "kiosk")
if [ "$(id -un)" = kiosk ] && [ -z "$DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then
    if grep -qw 'kiosk.maint=1' /proc/cmdline; then
        echo
        echo "  MAINTENANCE MODE - the player is not started."
        echo "  Changes made here are saved. Type 'sudo reboot' when you are done."
        echo "  To try the player once and read its log afterwards:"
        echo "      KIOSK_ONCE=1 startx /opt/kiosk/session -- vt1 -br -nolisten tcp ; less /tmp/kiosk-player.log"
        echo "  (Ctrl+q ends the player. The FAT32 partition is at /mnt/player.)"
        echo
    else
        startx /opt/kiosk/session -- vt1 -br -nocursor -nolisten tcp
        sleep 3
        exit 0
    fi
fi
EOF

# ----------------------------------------------------------------------- initramfs + boot loader
say "Building the boot files"
printf 'overlayroot="tmpfs:recurse=0"\n' > "$MNT/etc/overlayroot.conf"
chr update-initramfs -u -k all

KVER="$(ls "$MNT"/boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
[ -f "$MNT/boot/initrd.img-$KVER" ] || die "no initramfs was built for $KVER"

# boot loader: BIOS (MBR) and UEFI (\EFI\BOOT\BOOTX64.EFI on the FAT32 partition)
mkdir -p "$MNT/boot/grub"
grub-install --target=i386-pc --boot-directory="$MNT/boot" --modules="part_msdos ext2" --recheck "$DISK"
cp -r /usr/lib/grub/x86_64-efi "$MNT/boot/grub/"
rm -f "$MNT"/boot/grub/x86_64-efi/*.image "$MNT"/boot/grub/x86_64-efi/*.o 2>/dev/null || true
cat > "$STAGE/embedded.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $ROOT_UUID
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
EOF
mkdir -p "$STAGE/EFI/BOOT"
grub-mkstandalone -O x86_64-efi -o "$STAGE/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_msdos ext2 fat search search_fs_uuid configfile normal linux echo test all_video" \
    "boot/grub/grub.cfg=$STAGE/embedded.cfg"
rm -f "$STAGE/embedded.cfg"

CMD="root=UUID=$ROOT_UUID rootwait quiet loglevel=0 vt.global_cursor_default=0 consoleblank=0 usbcore.autosuspend=-1 net.ifnames=0"
cat > "$MNT/boot/grub/grub.cfg" <<EOF
# Hidden menu: boots the player after 1 second. Press ESC (or hold Shift) at power-on
# to get the menu with the maintenance entry.
set default=0
set timeout=1
set timeout_style=hidden
set gfxpayload=keep

menuentry "Media player" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux  /boot/vmlinuz-$KVER $CMD ro overlayroot=tmpfs:recurse=0
    initrd /boot/initrd.img-$KVER
}
menuentry "Maintenance (no player, changes are saved)" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux  /boot/vmlinuz-$KVER $CMD rw overlayroot=disabled kiosk.maint=1
    initrd /boot/initrd.img-$KVER
}
EOF

# ----------------------------------------------------------------------- data partition
say "Filling the FAT32 partition"
cp "$HERE/mediaplayer.lua" "$HERE/config.cfg" "$HERE/schedule.cfg" "$STAGE/"
[ -f "$HERE/USB-SETUP.txt" ] && cp "$HERE/USB-SETUP.txt" "$STAGE/USB-SETUP.txt"
cp "$HERE/README.txt" "$STAGE/README.txt"
printf '%s\r\n' "$TZNAME" > "$STAGE/timezone.txt"
printf 'The first line is the time zone (example: Europe/Stockholm).\r\nOptional line:  rtc=utc   if the PC clock shows UTC instead of local time.\r\n' >> "$STAGE/timezone.txt"
printf '%s\r\n' "$KBD" > "$STAGE/keyboard.txt"
cat > "$STAGE/mpv-options.txt" <<'EOF'
# Extra options for mpv, ONE per line. Lines starting with # are ignored.
# The player restarts (Ctrl+q) to pick up changes - or just reboot.
#
# Examples (remove the # to use):
#--screen=1                        use the second monitor
#--video-rotate=90                 rotate the picture
#--hwdec=no                        turn hardware decoding off if the picture is garbled
#--vo=x11                          fallback video output (fades will not work with it)
#--audio-device=pipewire/alsa_output.pci-0000_00_1f.3.hdmi-stereo
EOF
mkdir -p "$STAGE/content"
cat > "$STAGE/content/_PUT_YOUR_FOLDERS_HERE.txt" <<'EOF'
Create your folders in here, for example:

   L0/            the default background loop (videos)
   L1 - Xmas/     another loop (key F1)
   M1/            media mode 1 (key 1)
   M2 - Songs/    media mode 2 with mp3 files (key 2)
   Intro/  Outro/  Transition/   optional cutscenes
   Overlay/       optional frames, logos and text on top of the picture

See README.txt (one folder up) for everything else.
With no L0 folder (or an empty one) the screen simply stays black.
Delete this file whenever you like.
EOF
if [ -n "$CONTENT" ]; then
    say "Copying $CONTENT into content/"
    cp -r "$CONTENT"/. "$STAGE/content/"
fi

# copy everything onto the FAT32 partition (no mounting needed)
MTOOLS_SKIP_CHECK=1 mcopy -i "$P_DATA" -s -m -Q "$STAGE"/* ::/ || die "copying to the FAT32 partition failed"
rm -rf "$STAGE"

# ----------------------------------------------------------------------- finish
say "Cleaning up"
rm -f "$MNT/usr/sbin/policy-rc.d"
chr apt-get clean
rm -rf "$MNT/var/lib/apt/lists/"* "$MNT/tmp/"* "$MNT/var/cache/apt/"*
: > "$MNT/etc/machine-id"
sync
cleanup; trap - EXIT
sync
say "DONE. The stick is ready."
if [ -n "$IMAGE" ]; then
    echo "Image: $IMAGE   (write it to a stick of at least $SIZE, for example with balenaEtcher)"
else
    echo "Remove the stick safely, put it in the player PC and boot from USB."
fi
echo "Put your videos into the FAT32 partition ($LABEL) in the 'content' folder."
