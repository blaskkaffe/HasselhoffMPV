================================================================================
  MPV MEDIA PLAYER — SETUP GUIDE
================================================================================

What it is
----------
A kiosk-style player built on mpv. A silent background LOOP plays all the
time. Pressing a key (or a schedule entry) plays a MEDIA MODE on top of it,
optionally with an Intro/Outro cutscene, then returns to the loop. Everything
is controlled by how you name folders.

Files in this package (keep them together in ONE folder)
--------------------------------------------------------
  mediaplayer.lua   the script (settings are at the top, in SECTION 2)
  config.cfg        the same settings in a small plain-text file (optional)
  schedule.cfg      optional timed events (loop changes, timed media)
  launch.sh         starts mpv with the right options (macOS + Linux)
  content/          YOUR videos, in the folders described below (you create it)


1. INSTALL
----------
  macOS:    brew install mpv
  Debian/Ubuntu/Mint:   sudo apt install mpv
  Any other Linux:      install "mpv" with your package manager

For testing on a computer: put the four items above in one folder, e.g.
~/mediaplayer/.  Then:

  chmod +x launch.sh        (once)
  ./launch.sh --no-fs       (test in a window)
  ./launch.sh               (real use: fullscreen)

Quit with Ctrl+q.  (mpv's normal keys such as q and f are switched off on
purpose, because they would clash with your own M-folder keys.)


2. FOLDERS  (all directly inside content/ — no sub-folders)
-----------------------------------------------------------
  content/
    L0/                    default background loop            key: ESC
    L1 - Christmas/        loop 1                             key: F1
    L2 - New Year/         loop 2                             key: F2   ... up to L12 = F12
    M1/                    media mode 1                       key: 1
    M2 - Promos/           media mode 2                       key: 2
    Ma/                    media mode "a"                     key: a
    L1M1 - Xmas version/   OVERRIDE: plays instead of M1 while loop L1 is active
    Intro/                 cutscene before any media mode
    IntroM1/               cutscene before M1 only
    IntroL1M1/             cutscene before M1 while loop L1 is active
    Outro/  OutroM1/  OutroL1M1/       same idea, played after the media
    Transition/  TransitionL2/         played when the loop changes (TO that loop)
    M3 - Songs/            mp3 etc. inside = songs over the loop video (section 3)
    Overlay/ L1Overlay/ M1Overlay/ L1M1Overlay/   pictures + text on top of the video (section 4)

Naming rules
  * Text after " - " is just a label for you and is ignored:
      "L1 - Christmas", "L1" and "L1 - anything" are all loop 1.
  * Media folders are "M" + ONE character (digit or lowercase letter).
    That character IS the keyboard key.  M1 -> 1,  Ma -> a,  Mz -> z.
  * Loops are "L" + number.  L0 = ESC, L1..L12 = F1..F12.  L13 and above have
    no key but can still be used by the schedule.
  * Pressing a key that has no folder does nothing.
  * Inside a folder, "01 - clip.mp4" style names play in number order (when the
    order is sequential); other names are sorted A-Z.  Hidden files (.DS_Store,
    ._xxx) are ignored.  Video and audio files both work
    (mp4 mkv avi mov webm flv wmv m4v mp3 aac wav ogg flac m4a opus).

Overrides
  If loop L1 is active and you press 1, the player looks for a folder named
  L1M1.  If it exists it plays that, otherwise it plays the normal M1.  Keys
  never change — only what they play.

Cutscene fallback (most specific folder first; an EMPTY folder counts as missing)
  Intro:       IntroL1M1  ->  IntroM1  ->  Intro  ->  (nothing)
  Outro:       OutroL1M1  ->  OutroM1  ->  Outro  ->  (nothing)
  Transition:  TransitionL2 ->  Transition ->  (nothing)


3. MUSIC  (silent looping video + mp3 songs)
---------------------------------------------
Audio files (mp3, wav, flac, ogg, m4a, aac, opus) in a media folder are SONGS.
A folder can hold only songs, only videos, or BOTH mixed together - every item
is played its own way:

  * a song: the background loop video keeps playing, silently, without being
    interrupted (it acts as the "visualizer"), and the song is played on top of
    it by a second, hidden mpv process;
  * a video: plays like normal media, with its own sound.

Example: content/M3 - Songs/ with only mp3 files = songs over the loop video.
Example: content/M4 - Show/ with "01 intro.mp4", "02 song.mp3", "03 outro.mp4",
order = sequential: the video plays, then the song over the loop video, then the
second video, then back to the loop.

Everything else works exactly as with video media: Intro/Outro cutscenes,
overrides (L1M3), keys, lock_keys, key_cancel, the scheduler (media M3 12:00).

What the settings mean:
  clips_per_trigger = number of ITEMS (songs and videos) per key press
                      (1 = one item, 0 = keep going until another key / the
                      time limit)
  seconds_per_trigger = stop after N seconds (a running song is stopped)
  order             = item order (sequential / shuffle / random / ...)
  visual_loop       = "L5": show THAT loop's video while songs play (and go
                      back to the normal loop afterwards).  Use this to give a
                      music mode its own visualizer clips:
                        media_cfg = { M3 = { visual_loop = "L5", clips_per_trigger = 0 } },
                      (L5 is then a folder of visualizer videos; it is also a
                      normal loop you can switch to with F5.)
  music = false     play audio files of this mode like videos (black picture)
                    instead of as songs

Global settings (top of the script): MUSIC_VOLUME (0-100), MUSIC_FADE_IN
(seconds, off by default), MPV_BINARY ("mpv" - the program that plays the
songs; it must be findable on the PATH), MUSIC_EXTRA_ARGS (extra options for
the song player, e.g. {"--audio-device=alsa/hw:1"}).  The song player uses the
same audio device as the main player unless you set MUSIC_EXTRA_ARGS.

A different key or a loop key stops the music at once (hard stop).


4. OVERLAYS  (frames, logos, text)
----------------------------------
Folders in content/, all optional.  They STACK - everything that matches is
shown at the same time, in this order (later = on top):

    Overlay          shown always
    L1Overlay        shown while loop L1 is active   (also during media on L1)
    M1Overlay        shown while media mode M1 plays (on any loop)
    L1M1Overlay      shown while M1 plays on top of loop L1 only

(The name ends in "Overlay" so it sorts right next to L1, M1 and L1M1 in the
file list.  "L1Overlay - Christmas" style names work too: text after " - " is
ignored.)

PICTURES:  .png / .webp with transparency.
  * With no tags in the file name the picture is stretched over the whole
    video, i.e. a FRAME:             frame.png
  * Tags in the file name place and size a LOGO (any order, any case):
      position:  top-left top-center top-right middle-left center
                 middle-right bottom-left bottom-center bottom-right
      size:      12%   = width as a percentage of the video width
      opacity:   opacity50 = half transparent
    Examples:    logo bottom-right 12%.png
                 watermark top-left 8% opacity40.png
    A picture with a position but no % keeps its own pixel size.
  * Several pictures in one folder are drawn in file-name order.
  * Avoid apostrophes (') in overlay file names - such files are skipped.

TEXT:  .txt files.  Simplest: the file contains just the text.
  With settings (everything after "text:" is the text, several lines ok):

      position: top-center        (same nine names as above, default bottom-center)
      size: 48                    (default 48; measured on a 1080-pixel-high screen)
      color: FFD700               (RRGGBB, default FFFFFF)
      outline: 3                  (default 3)
      text: Merry Christmas
      and a second line

Pictures and text fade together with the video.  Overlays are NOT shown
during Intro/Outro/Transition cutscenes (set OVERLAYS_ON_CUTSCENES = true to
show them there too).  Hide overlays in one mode with  overlays = false  in
media_cfg / loop_cfg, or everywhere with  OVERLAYS = false.
Example - a Christmas frame only on loop L1, a logo only while M2 plays:
    content/L1Overlay/frame.png          content/M2Overlay/logo top-right 10%.png


5. HOW IT BEHAVES
-----------------
  * Loops play silently and forever, one clip after another.
  * A media key plays Intro (if any) -> the media -> Outro (if any) -> loop.
  * Pressing ANOTHER media key while media plays interrupts it (default).
  * Pressing the SAME key again is ignored (default).
  * Keys are ignored while a cutscene plays.
  * Loop keys (ESC, F1..F12) switch loop immediately; pressing the key of the
    loop you are already on does nothing.
  * Scheduler changes (loop switch, timed media) wait until the current media
    has finished.  After media ends, the player returns to whichever loop is
    current at that moment.
  * If the schedule wants a loop and you press another loop key by hand, your
    choice stays until the schedule next changes its mind.


6. SETTINGS  (top of mediaplayer.lua, SECTION 2 — open it in any text editor)
-----------------------------------------------------------------------------
  DEFAULT_LOOP          "L0"      loop used when the schedule has no opinion
  DEFAULT_ORDER         "random"  sequential | reverse | pingpong | shuffle | random
                                  (shuffle = no repeats until everything has played;
                                   pingpong = forward, then backward, then forward...)
  CUTSCENE_ORDER        "random"  sequential | shuffle | random
  CLIPS_PER_TRIGGER     1         clips per key press; 0 = until interrupted/timer
  SECONDS_PER_TRIGGER   0         end the media after N seconds (0 = off)
  LOOP_MUTED            true
  LOCK_KEYS             false     true = ignore all keys while media plays
  KEY_CANCEL            false     true = pressing the same key again stops the media
  QUIT_KEY              "Ctrl+q"  "" = no quit key

  CUTSCENE_ON_TRIGGER   true      play Intro before media
  CUTSCENE_ON_RETURN    false     play Outro after media     <- set true to use Outro folders
  CUTSCENE_ON_SWITCH    false     play Transition on loop change <- true to use them
  (A cutscene only plays when its folder exists and contains files.)

  FADE_ENABLED          true
  FADE_OUT_DURATION     0.4       seconds to fade to black
  FADE_BLACK_HOLD       0.1       seconds of black between clips (0 = none)
  FADE_IN_DURATION      0.4       seconds to fade in
  FADE_BEFORE_END       true      also fade out shortly before a clip ends on its own

  MPV_BINARY            "mpv"     program that plays the songs (music modes)
  MUSIC_VOLUME          100       0-100
  MUSIC_FADE_IN         0         seconds of fade-in per song (0 = off, songs start normally)
  MUSIC_EXTRA_ARGS      {}        extra mpv options for the song player
  OVERLAYS              true      false = all overlays off
  OVERLAYS_ON_CUTSCENES false     true = overlays during cutscenes too

Per-mode settings (same file, a few lines further down: media_cfg / loop_cfg)
  Any setting above (lower-case) can be overridden for one mode.  Example:

    media_cfg = {
        M1 = { order = "shuffle", clips_per_trigger = 2, cutscene_on_return = true },
        M3 = { order = "pingpong", seconds_per_trigger = 30, key_cancel = true },
        M2 = { lock_keys = true, cutscene_on_trigger = false },
    },
    loop_cfg = {
        L1 = { order = "pingpong", cutscene_on_switch = true },
    },

  So "intro only", "outro only", "both" or "neither" is chosen per mode with
  cutscene_on_trigger (Intro) and cutscene_on_return (Outro).
  Extra per-mode settings: overlays (false = hide overlays),
  visual_loop ("L5"), music (false = audio files play like videos).

  config.cfg  (optional, next to mediaplayer.lua)
  Every setting above, and the per-mode ones, can also be written in
  config.cfg instead of editing the script:
        default_order = shuffle        a global setting (any upper/lower case)
        [M1]                           settings for media mode M1
        clips_per_trigger = 2
        [L1]                           settings for loop L1
        order = pingpong
  config.cfg wins over mediaplayer.lua; what it leaves out keeps the script's
  value.  Unknown names are logged and skipped.  List settings
  (MUSIC_EXTRA_ARGS) stay in mediaplayer.lua.  The shipped config.cfg has
  every line commented out with examples.


7. SCHEDULE  (schedule.cfg)
---------------------------
  loop   L1  START  END  [FROM-DATE  TO-DATE]
  media  M2  TIME        [FROM-DATE  TO-DATE]

  loop   L1  00:00  23:59  12-01  01-06      Christmas loop, Dec 1 - Jan 6
  loop   L0  09:00  17:00                    every day 09:00-17:00
  media  M2  12:00                           every day at noon

  Times are 24h HH:MM.  Dates are MM-DD and repeat every year (a range may wrap
  New Year).  Lines LOWER in the file beat lines above them.  The file is read
  once at start-up: restart the player after editing it.  The schedule uses the
  computer's clock — on a live USB make sure the time zone and clock are right.


8. LIVE USB / AUTOSTART
-----------------------
The complete stick (boots by itself into this player, no password, keyboard
only, read-only system) is built with  build-usb.sh  - see USB-SETUP.txt.
On such a stick this README, mediaplayer.lua, schedule.cfg and the content/
folder are on the FAT32 partition called MEDIAPLAYER, and you edit them from
your normal computer.  Ctrl+q restarts the player there.


9. TROUBLESHOOTING
------------------
Run ./launch.sh --no-fs from a Terminal; every decision is printed with the
prefix [mediaplayer] [SM].  For more detail set DEBUG = true in the script.

  "Default loop folder 'L0' not found"
        -> create content/L0 and put at least one video in it.
  Nothing plays / "No folder" warnings
        -> the folder must be named exactly L0, M1 ... (capital L/M), directly
           inside content/.
  A key does nothing
        -> there is no matching M folder, a cutscene is playing, or LOCK_KEYS
           is on.
  Intro/Outro/Transition never plays
        -> check the folder name (Intro, IntroM1, IntroL1M1 ...), that it has
           video files, and the CUTSCENE_ON_* switch in the settings.
  Fades do not show
        -> fades use mpv's "brightness" setting.  If your video output ignores
           it, try adding   --vo=gpu   to the mpv line in launch.sh.
  Songs do not play ("Could not play song ..." in the log)
        -> the song player is a second mpv: it must be installed and found as
           "mpv" (see MPV_BINARY).  On a live USB, check the audio device.
  A picture overlay does not show / video turns black with an overlay
        -> the PNG may be damaged or the name contains an apostrophe.  Remove
           the overlay folder to confirm.  Text overlays need no extra files.
  Overlay is the wrong size
        -> sizes follow the video: % is of the video width.  Mixed video sizes
           are handled (the overlay is rebuilt when the size changes).
  Base folder shows "." in the log
        -> start the player with launch.sh (it passes the folder to the script).


10. WHAT HAS BEEN TESTED
------------------------
  * A simulated mpv (virtual clock and folders, mpv's real end-file behaviour):
    ~150 scripted checks (keys, overrides, cutscene fallbacks, clip counts,
    timers, scheduler incl. dates, fades, bad files, music modes, overlays)
    plus thousands of randomised key / schedule / settings runs.
  * A real mpv 0.37 on Linux: the player started, looped, ran music and mixed
    video/song folders (hidden second mpv playing the mp3, no leftover processes after quit,
    stopped by keys), applied overlays - checked on the rendered pictures
    (red frame, logo bottom-right at the right size, text at the top, all on
    top of the running video).
  * NOT tested: macOS, other mpv/ffmpeg versions, real audio hardware, real
    fullscreen displays.  Run ./launch.sh --no-fs once on your machine with
    your own files before relying on it.
================================================================================
