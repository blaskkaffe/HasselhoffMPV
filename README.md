# Wind-Up Fairway

A minigolf game for the Sega Dreamcast, built on [KallistiOS](https://github.com/KallistiOS/KallistiOS)
(KOS) and [GLdc](https://gitlab.com/simulant/GLdc). Instead of a ball and clubs,
you're putting **pull-back toy cars** around each hole. Every car has its own
**strength** (launch power), **speed** (how far it coasts before friction wins),
and **turning** (how sharply it curves) — pick the right car for the shot.

This is a first playable slice: one hole, three cars, full pull-back-and-release
physics with wall bouncing and curve, a chase camera, and a minimal on-screen
HUD (stroke count, par, charge meter). It's built to be extended — see
**Roadmap** at the bottom.

## Controls

| Input                     | Action                                              |
|---------------------------|------------------------------------------------------|
| Left stick / D-pad L-R    | Aim direction                                        |
| L / R triggers            | Set curve bias (locked in when you start charging)  |
| A (hold, then release)    | Pull back (hold to charge power, release to shoot)  |
| X (before your first shot)| Cycle car                                            |
| Start                     | Restart the hole once the car is sunk               |
| A+B+X+Y+Start             | Reset to BIOS (KOS's default handler)               |

## Project layout

```
Makefile          Top-level KOS build (kos-cc, links -lGL -lGLU)
src/
  main.c          Entry point / frame loop
  input.{h,c}     Maple controller -> input_state_t
  car.{h,c}       Car stat presets (strength/speed/turning)
  course.{h,c}    Hole 1: walls, hole position, par
  physics.{h,c}   Pure-C car physics: launch, friction, curve, wall bounce, sink
  hud.{h,c}       2D overlay: charge bar + LED-style digit renderer (no fonts)
  render.{h,c}    GLdc 3D scene: ground, walls, hole/flag, car model, camera
  game.{h,c}      State machine tying input -> physics -> HUD together
```

`physics.c`, `car.c`, `course.c`, and `game.c` have no KOS/GL dependency at
all — they're plain, portable C, which makes the actual game design (the
part you asked about: car stats and how they play) easy to read and tune
independently of the Dreamcast-specific rendering/input code.

## Toolchain setup

You need the `sh-elf` cross-compiler, KallistiOS itself, and the GLdc port
(`libGL`/`libGLU`). This is the standard KOS setup, not anything specific to
this project — if you've already got a working KOS environment, skip to
**Building the game**.

```sh
# 1. Dependencies (Debian/Ubuntu; see utils/kos-chain/doc/ for other OSes)
sudo apt-get install build-essential texinfo libjpeg-dev libpng-dev \
                      libelf-dev git subversion python3 cmake

# 2. Get KallistiOS + kos-ports
sudo mkdir -p /opt/toolchains/dc
cd /opt/toolchains/dc
git clone https://github.com/KallistiOS/KallistiOS.git kos
git clone https://github.com/KallistiOS/kos-ports.git

# 3. Build the sh-elf/arm-eabi cross-compiler toolchain (this takes a while)
cd kos/utils/kos-chain
cp Makefile.dreamcast.cfg Makefile.cfg
make

# 4. Set up and source your environment
cd /opt/toolchains/dc/kos
cp doc/environ.sh.sample environ.sh
# edit environ.sh if you installed anywhere other than /opt/toolchains/dc
source environ.sh

# 5. Build KallistiOS itself
make

# 6. Build the GLdc port (provides libGL.a / libGLU.a used by this game)
cd /opt/toolchains/dc/kos-ports/libGL
make install clean
```

Re-run `source /opt/toolchains/dc/kos/environ.sh` in every new shell before
building (or add it to your `.bashrc`).

> I set this exact pipeline up while scaffolding this project, to check the
> API calls in `src/` against the real KOS/GLdc headers - but this sandbox's
> network policy blocks the GNU mirrors (gcc/binutils/newlib sources) and
> Docker Hub's blob storage, so I couldn't finish compiling the cross-compiler
> here. It should build cleanly on a normal dev machine following the steps
> above; the source in this repo was written against, and cross-checked line
> by line against, the actual KallistiOS/GLdc headers and examples (matrix
> API, `cont_state_t` fields, GLdc's `gl.h`/`glu.h` usage), not from memory
> alone.

## Building the game

```sh
source /opt/toolchains/dc/kos/environ.sh   # if not already sourced
cd /path/to/HasselhoffMPV
make
```

This produces `windup-fairway.elf`.

## Running it

**Flycast (recommended for iteration):** load `windup-fairway.elf` directly
- most Flycast builds have a "Load ELF/BIN" option, or drop it in as a
selected file when launching. No disc image needed.

**Real hardware via GDEMU / burned disc:** you need a bootable disc image.
KOS itself only ships the low-level pieces (`utils/scramble`, `utils/makeip`)
used internally by its build system; for a one-step `.elf -> .cdi` tool, the
common choice in the current homebrew scene is
[**mkdcdisc**](https://github.com/8bitgeek/mkdcdisc) (or an equivalent
GDI/CDI builder) - install it, put it on your `PATH`, then:

```sh
make cdi   # runs: mkdcdisc -e windup-fairway.elf -o windup-fairway.cdi -n "WINDUP FAIRWAY"
```

Copy the resulting `.cdi` to your GDEMU SD card the same way you would for
any other homebrew title.

## How the car physics work (`src/physics.c`)

- **Launch:** speed = `BASE_LAUNCH_SPEED * (0.6 + 0.8*strength) * charge01`,
  fired along the locked-in aim angle.
- **Curve:** the velocity vector is rotated every tick by the car's `spin`
  (derived from `turning` and the curve bias you set with the triggers),
  scaled by `current_speed / launch_speed` - so the curve is strongest right
  after release and relaxes as the car slows, like a wound-up toy losing
  momentum in its front wheels.
- **Friction:** `speed` stat lowers rolling friction, so higher-`speed` cars
  coast farther at a given `strength`.
- **Walls:** the car is treated as a circle; hitting a wall segment reflects
  its velocity about the wall normal with a fixed restitution (0.55).
- **Sinking:** the car sinks if it's within the hole's radius *and* under
  `CAPTURE_MAX_SPEED` - blowing through the hole too fast just rolls past it.

## Roadmap / good next steps

- Pre-shot car-select screen (currently: press X before your first shot)
- More holes/courses, and a course-select menu
- Textured ground/car (currently flat-shaded colored polygons - no romdisk,
  no texture loading, on purpose, to keep this slice dependency-free)
- Slopes/ramps (current course is a flat plane)
- Sound effects (launch, bounce, sink) via KOS's sound driver
- A proper "ball in hole" text banner instead of the green flash circle
- Multiplayer (take turns; `game_t` is already structured to be duplicated
  per player)
