# HasselhoffMPV — mpv kiosk player on a USB stick

A folder-driven media player for [mpv](https://mpv.io) plus a builder for a bootable
USB stick that runs it as a kiosk:

- **Continuous silent loops** (`L0`, `L1` …) and **keyboard-triggered media** (`M1`, `M2` …),
  per-loop overrides (`L1M1`), Intro/Outro/Transition cutscenes, fades, a scheduler,
  mp3 music over a looping video, and PNG/text overlays — all driven by **folder names**.
- **The stick** has two partitions: a FAT32 one for your videos and all settings
  (readable on Windows/macOS/Linux) and a small read-only Ubuntu 24.04 that boots
  straight into the player: no login, black screen when idle, the keyboard is the only control.

## Get a ready-made stick image (no Linux needed)

1. Open the **Actions** tab → **Build USB image** → **Run workflow**; set time zone,
   keyboard layout and size (a little below your stick's capacity; 14G for a 16 GB stick).
2. After ~25 minutes the image appears under **Releases** (in parts of < 2 GB).
   Join the parts, then flash with [balenaEtcher](https://etcher.balena.io). The release
   notes show the exact commands.
3. Put your videos into the `content/` folder of the MEDIAPLAYER partition.

## Build it yourself

```
sudo bash build-usb.sh /dev/sdX --tz Europe/Stockholm --kbd se        # straight onto a stick
sudo bash build-usb.sh --image stick.img --size 14G --tz Europe/Stockholm --kbd se
```

Needs a Linux machine with internet (Ubuntu/Debian, a live USB or VM works). The full
guide — first start, maintenance mode, troubleshooting — is in [`USB-SETUP.txt`](USB-SETUP.txt).

## Files

| File | What |
|---|---|
| `mediaplayer.lua` | the player (mpv script) |
| `config.cfg` | optional plain-text settings, overrides the defaults in the script |
| `schedule.cfg` | optional timed events |
| `README.txt` | how folders, keys, music, overlays and settings work |
| `USB-SETUP.txt` | stick build / setup / troubleshooting guide |
| `build-usb.sh` | builds the stick (or an image of it) |
| `launch.sh` | runs the player on a normal computer for testing |
| `tests/` | mock-mpv test suite (`cd tests && lua5.3 tests.lua ../mediaplayer.lua`) |

## Status

Tested in a PC emulator (UEFI boot, key presses, loops, media, hidden second mpv for songs,
overlays, fades, read-only system) and with the mock-mpv tests. Not yet tested on real
hardware, real audio output, or with Windows/macOS reading the stick — try it on your
player PC before relying on it. Secure Boot must be off.
