# 240-MP Architecture

240-MP is a retro VCR-style media app built with **C++ Qt6 + QML**, targeting **Raspberry Pi 4** and **macOS**. and this is the reference for working on 240-MP's code (whether you're adding a new module or changing an existing one). 

If you just want to install or build the app, see [INSTALL.md](INSTALL.md) and [BUILDING.md](BUILDING.md). 

If you want to contribute, please start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Philosophy

Think of 240-MP as a **browsing shell** that hands off to **purpose-built tools**.

- The app shell handles browsing, auth, and settings
- **Modules** are self-contained media integrations (Local Files, Plex, Ambient Mode, etc...) that the shell discovers and loads at startup.
- When a user picks something to play, the shell hands off to a dedicated fullscreen tool and resumes when that tool exits. For video, that tool is **mpv**, launched as a subprocess by `MpvController`. mpv is installed separately (`apt install mpv` / `brew install mpv`).  240-MP does not link against libmpv.

The guiding idea: **browse structured content, then hand off to the right tool for the job** rather than bundling everything into one binary.

## Project Structure

```
240-mp/
  src/                              # C++ source
    main.cpp                        # app entry point — engine setup, context properties, registerModule calls
    AppCore.h / AppCore.cpp         # app shell: module registry, config r/w, settings routing
    modules/                        # per-module C++ backends
      local_files/
        LocalFilesBackend.h/.cpp
      plex/
        PlexBackend.h/.cpp          # good reference backend implementation
      ...
    player/
      MpvController.h/.cpp          # mpv subprocess controller: QProcess launch + IPC socket
  modules/                          # QML + assets per module (discovered at startup)
    plex/
      manifest.json                 # module identity and settings shape
      assets/images/logo.svg
      views/
        Root.qml                    # module router (required)
        ...
    local_files/
    ...
  views/                            # app-level QML
    ModuleList.qml
    Settings.qml
    ...
    Components/                     # shared QML components (AppBar, qmldir)
  Main.qml                          # app root
  CMakeLists.txt
```

There are three modules today: `local_files`, `plex`, and `ambient_mode`. `plex` is a helpful reference when building something new as it covers a more complex use case (connecting to a 3rd party API with auth)

## Anatomy of a Module

A module has up to three parts:

| Part | Location | Required? |
|---|---|---|
| `manifest.json` | `modules/<name>/manifest.json` | **Yes** — read by `AppCore` at startup |
| QML views | `modules/<name>/views/` (entry point `Root.qml`) | **Yes** |
| C++ backend | `src/modules/<name>/<Name>Backend.h/.cpp` | Optional |

`AppCore` scans `modules/*/manifest.json` at startup. A module that needs **no backend** (pure QML) requires **no C++ changes at all** — drop in the folder and it's discovered. A module that needs a backend adds one `registerModule(...)` call in `main.cpp` (see [AppCore](#appcore--the-app-shell)).

```
modules/<name>/
  manifest.json             # identity + settings
  assets/images/logo.svg    # logo for the module / single color `#ffffff` to enable color schemes to re-color
  views/
    Root.qml                # module router (entry point)
    Items.qml               # list view
    Detail.qml              # detail/leaf view
```

## manifest.json Reference

Loaded at startup by `AppCore` — the single source of truth for a module's identity and settings. No C++ changes are needed to add or modify settings.

```json
{
  "id": "com.240mp.<name>",
  "name": "<DISPLAY NAME>",
  "icon": "assets/images/logo.svg",
  "entry_point_qml": "views/Root.qml",
  "settings": [ ... ]
}
```

### Setting types

| `type` | Description | Extra fields |
|---|---|---|
| `toggle` | ON/OFF toggle | `default: "ON"` or `"OFF"` |
| `list_single` | Single-select list | `options_source`, `options_slot`, `apply_slot` |
| `multiselect_submenu` | Multi-select list via submenu | `options_source`, `options_slot` |
| `directory_browser` | Keyboard-navigable directory picker | `default` (path string, may be empty) |
| `action` | Button that calls a backend slot | `action_slot` |

Additional fields any setting may carry:

- `key` — the config key written under `modules.<id>.<key>` in `config.json`. Supports dot-notation.
- `label` — display text in Settings.
- `requires_auth` — if `true`, the setting is only shown when the module reports an authenticated state via `get_module_auth_state(moduleId)`. Used by Plex to hide server/user/library settings until sign-in.

### Dynamic options and apply slots

- For `list_single` / `multiselect_submenu` with `"options_source": "dynamic"`, the backend slot named by `options_slot` must emit `dynamicOptionsReady(key, [{id, label}])`. `AppCore` re-emits it to QML with the module ID prepended.
- For `list_single` with `apply_slot`, that slot is called automatically (routed through `invoke_module_action`) when the user changes the value.

A real example (Plex) — note `requires_auth`, dynamic options, and apply slots:

```json
{
  "key": "server_machine_id",
  "label": "Server",
  "type": "list_single",
  "options_source": "dynamic",
  "options_slot": "getServers",
  "apply_slot": "applyCurrentServerSetting",
  "requires_auth": true
}
```

## AppCore — the App Shell

`AppCore` (`src/AppCore.h/.cpp`) is the shell. It's exposed to all QML as the context property **`appCore`**.

**Global context properties** (available in all QML): `appCore`, `mpvController`, plus one per module backend (`localFilesBackend`, `plexBackend`, `ambientModeBackend`, …). Backend names are assigned by the `registerModule` call in `main.cpp`.

### Q_INVOKABLE slots used by QML

| Slot | Purpose |
|---|---|
| `scan_for_modules()` | Emits `modulesLoaded` with enabled modules |
| `get_settings()` | Returns entire `config.json` as a map |
| `get_setting(moduleId, key)` | Returns a single setting value |
| `save_setting(moduleId, key, value)` | Writes to `config.json`; supports dot-notation keys |
| `get_module_info(moduleId)` | Returns `{name, icon}` for a module |
| `get_module_settings_schema(moduleId)` | Returns the module's settings array |
| `invoke_module_action(moduleId, slotName)` | Routes to the registered backend via `QMetaObject::invokeMethod` |
| `get_module_auth_state(moduleId)` | Returns the module's auth state (for `requires_auth` settings) |
| `twelve_hour_clock()` | Whether every clock in the app reads 12-hour (see below) |
| `getCustomColorScheme()` | Returns the user's custom color scheme |
| `listDirectories(path)` / `parentDirectory(path)` / `homePath()` | Helpers for `directory_browser` |

**The clock format is resolved in one place.** The app has no 12/24-hour setting of its own — the weather module owns the only `hours_format` there is — so `twelve_hour_clock()` answers for the whole app: an *enabled* module offering that setting speaks for it, 24-hour when none does. It finds that module by the setting key rather than by module id, so the id stays stated once (in `main.cpp`). `Main.qml` mirrors it as `root.twelveHour`, re-asking on any `moduleSettingChanged` for `hours_format` or `enabled`; `MpvController` asks it directly to tell the OSC script how to print a time.

### Signals

`modulesLoaded`, `appSettingChanged`, `moduleSettingChanged(moduleId, key, value)`, `dynamicOptionsReady(moduleId, key, options)`, `moduleAuthStateChanged(moduleId)`.

### registerModule — wiring a backend in

Backends are wired in from `main.cpp` with a single call:

```cpp
YourBackend yourBackend(appRoot, dataRoot);   // construct with whatever args the ctor needs

appCore.registerModule("com.240mp.<name>", "yourBackend", &yourBackend, ctx);
```

`registerModule(moduleId, contextProperty, backend, ctx)` does everything: it stores the backend for `invoke_module_action` routing, exposes it to QML under `contextProperty`, and connects the backend's optional signals/slots **by introspection** — each is wired only if the backend actually declares it, so there are no per-capability lambdas:

| Backend member (if declared) | Auto-connected to |
|---|---|
| signal `dynamicOptionsReady(QString, QVariant)` | re-emitted as `appCore.dynamicOptionsReady(moduleId, key, options)` |
| signal `authStateChanged()` | re-emitted as `appCore.moduleAuthStateChanged(moduleId)` |
| slot `onSettingChanged(QString, QString, QVariant)` | `appCore.moduleSettingChanged(moduleId, key, value)` |

The module ID lives in exactly one place per module — this call. Declare these members with the exact signatures above and `registerModule` wires them with no other changes to `main.cpp`.

#### Probed, not connected

Two further capabilities are **probed on demand** rather than connected at registration — `AppCore` checks `metaObject()->indexOfMethod(...)` and calls the method with `QMetaObject::invokeMethod` only if the backend declares it. Same idea, but they return a value, so there's nothing to connect:

| Backend member (if declared) | Used by |
|---|---|
| `Q_INVOKABLE QString get_auth_state()` | `appCore.get_module_auth_state(moduleId)` — drives the `requires_auth` setting gate |
| `Q_INVOKABLE QVariantList get_menu_entries()` | `scan_for_modules()` — lets a backend add its own rows to the **main menu** |

`get_menu_entries()` returns a list of `{name, params}`. `AppCore` fills in `entry_point` from the module's manifest and appends the rows to the `modulesLoaded` payload, so `views/ModuleList.qml` renders them like any other row and forwards `params` as `navParams` then the module's `Root.qml` router interprets them.

Rows are appended **after** all module rows on purpose: module row indices then stay stable, so a saved menu position still restores onto the same row when a contributed row appears or disappears. The scripts module uses this to list `favorite = yes` scripts after native 240-MP modules.

## Playback Hand-off (MpvController)

The current MPV implementation is a good reference implementation of the "browse & hand-off" philosophy. When a module decides to play a video, it hands off to **mpv** rather than rendering video itself. All of that lives in `MpvController` (`src/player/MpvController.h/.cpp`), exposed to QML as the context property **`mpvController`**.

### How the hand-off works

1. **Launch** — `loadAndPlay(url, startSeconds, audioTrack, subTrack, ...)` starts mpv as a `QProcess`. Playback parameters are passed as mpv command-line flags: `--start=<sec>` (resume offset), `--playlist-start=<n>`, `--loop-playlist=inf`, and so on. mpv is found on `PATH` — the app never links libmpv.
2. **Control channel** — mpv is started with `--input-ipc-server=<socket>` (a Unix domain socket at `/tmp/240mp-mpv.sock`). `MpvController` connects to it with a `QLocalSocket` and sends JSON commands via `sendCommand(QJsonArray)`. `seekTo()` and `sendKey()` (which sends mpv a `keypress` command) go over this channel — that's how the USB remote / keyboard drives mpv's OSC while it's fullscreen.
3. **State back to QML** — `MpvController` issues `observe_property` for `time-pos`, `duration`, and `playlist-pos`, and re-publishes them as `Q_PROPERTY`s + the `positionChanged` / `durationChanged` / `playlistPosChanged` signals. A watchdog timer logs a warning if no `time-pos` event arrives for ~10 s (freeze detection).
4. **Exit** — when mpv quits, `MpvController` emits a single signal, **`playbackEnded(finalPos, finalDur, reason)`**, where `reason` is one of:
    - `"eof"` — the file played to its natural end. What happens next is the module's call: most just return to the menu.  For example: Plex may autoplay the next episode (based on the user's autoplay setting, and fall back to a normal return when there is no next episode, e.g. a movie or the last episode of a season).
    - `"stopped"` — the user quit/stopped before the end (also the safe default for a crash/kill with no end-file event). Record the resume position and return.
    - `"failed"` — mpv exited with code 2 (file couldn't be played). A module may attempt recovery first.  For example: Plex retries with transcoding — otherwise it just returns.

    **The baseline for every module to keep in mind:** by the time `playbackEnded` fires, mpv has already exited, so a handler that returns without either calling `goBack()` or starting fresh playback (`loadAndPlay`, e.g. in an autoplay/retry scenario) will leave the now-defunct Player view focused over a dead subprocess which will cause the app to freeze. So please handle the one signal, then branch on `reason` only where you have special behavior, and make sure no branch falls through.

### Per-device video decode profiles

The `--vo`/`--hwdec` flags mpv launches with are auto-selected per device to try to target hardware-decodes efficiently per device without the need for user setup. `MpvController::detectVideoProfile()` reads `/proc/device-tree/model` once at startup; `appendVideoArgs()` then picks the flag set:

| Target | Boot driver | Video flags |
|---|---|---|
| Pi 4B | Fake KMS (`vc4-fkms-v3d`) | `--vo=drm --hwdec=v4l2m2m-copy` |
| Pi 3B / 3B+ | Fake KMS (`vc4-fkms-v3d`) | `--vo=gpu --gpu-context=drm --hwdec=v4l2m2m` |
| Pi 5 | Full KMS (`vc4-kms-v3d`) | `--vo=drm --hwdec=auto-safe` |
| Unknown headless Linux | — | `--vo=drm --hwdec=auto-safe` (a safe fallback for now - will research this more later) |
| macOS (Apple Silicon) | — | `--hwdec=videotoolbox` |

The key levers are which decoder and which DRM plane the frames land on:

- **Pi 4** 
    - H264 - in my testing I found that the Pi4 has the CPU headroom to implement `-copy` + software-downscale cost (~50–70% across four cores) in exchange for the primary-plane path with working crop (`--panscan`), so it uses native `--vo=drm` + hardware decode.
    - HEVC — `v4l2m2m-copy` doesn't look like it can reach the Pi4's HEVC decoder from my testing (rpivid is a stateless V4L2-request device, not the stateful `hevc_v4l2m2m` wrapper that mpv tries), so it falls back cleanly. It's seems to work fine for 1080p (~50% CPU) but 4K HEVC does not look feasbile with my current set up so I am accepting that as a limitation for now considering my primary target is a CRT TV. 
    - I tried a bunch of other paths just to be safe... `auto`/`auto-copy` excludes `v4l2m2m` entirely (so they'd drop H.264 to software too), the Pi5's Vulkan path is unavailable here (the Pi4's V3D 4.2 GPU looks ot lack `VK_KHR_video_decode_queue`), and the only door to rpivid (`--hwdec=drm`) is non-copy → overlay plane which causes judder and it wouldn't help H.264. So that's why I settled on `v4l2m2m-copy` as the current compromise.
- **Pi 3**
    - H264 - the copy path I am using on the pi4 sadly pegs all four cores and goes choppy on the pi3. So I chose to take lowest-CPU path with zero-copy (e.g. `v4l2m2m` straight to the overlay plane).  
    - That gives around ~15% CPU, smooth playback, with the single trade-off that crop (`--panscan`) is unavailable with this set up.  I figured that was an acceptable tradeoff for supporting 1080p video but if you want to retain the ability to crop on a pi3 then you can use the override args to set v4l2m2m-copy which will allow crop to work but limit performance to 720p content instead.
- **Pi 5** 
    - boots Full KMS, so plain `--vo=drm` direct-renders. when testing `auto-safe` I found no working VA-API/V4L2 path (the V3D VA-API driver fails to open) and it selects FFmpeg's Vulkan video decoder (`vulkan-copy`) on the V3D GPU for both H264 and HEVC. HEVC reaches the Pi5's hardware HEVC block this way — ~15% for 1080p, ~45% for 4K; H.264 goes through the same Vulkan path and stays light (~20–27% for 1080p). Because it's a `-copy` decoder the frames land on the primary draw plane, so I found this path is smooth and supports crop.

Advanced users can override the auto-detected flags with the app-level `mpv_video_args` setting in `config.json` (a space-separated flag string under `"app"`); it is read at each launch, so changes apply on the next playback without a rebuild — useful for on-hardware tuning.

### How mpv flags are layered (the precedence cascade)

Every flag mpv receives belongs to one of a few layers, and the model that keeps them straight is a single precedence cascade where each layer can only override what the layers above it didn't nail down:

I think of it like this:
```
app constants → 
  app per-playback → 
    app presentation (user-set in Settings) → 
      device decode (user-overridable in config) → 
        ~/.config/mpv/mpv.conf
```

| Layer | Examples | Owner | Where |
|---|---|---|---|
| **App constants** | `--input-ipc-server`, `--input-conf`, `--osc`, `--script`, `--log-file`, `--no-input-terminal` | App only | command-line |
| **App per-playback** | `--start`, `--aid`, `--sub-file`, `--http-header-fields` (stream URL, tokens) | App only | command-line |
| **App presentation** | `--panscan` (Auto Crop), `--video-output-levels` (Video Levels) | User, via a Settings row | command-line |
| **Device decode** | `--vo` / `--gpu-context` / `--hwdec` | App auto-detects; user may override via `mpv_video_args` | command-line |
| **User prefs** | `deinterlace`, `cache`, `sub-scale`, `audio-device`, profiles | User | `mpv.conf` |

- The first four layers are app-owned and the first two are load-bearing because they wire the IPC control channel, the input/OSC bridge, and (headless) the DRM/VT hand-off. Changing them would break functionality in the app, not just playback, so they are never user-overridable. The last two app layers are the ones the user can steer: *app presentation* through a Settings row (Auto Crop, Video Levels) for the knobs worth reaching without a keyboard, and *device decode* through the `mpv_video_args` override if per device tweaks are needed.
- A presentation setting left at its default emits **no flag at all** (Video Levels on `Auto`, Auto Crop `Off`), so a `video-output-levels=` line in someone's `mpv.conf` still applies; picking Limited/Full puts it on the command line, where it wins.
- And all app layers are command-line, so they all win over `mpv.conf`. I do pass no `--no-config`, so mpv will look to read `~/.config/mpv/mpv.conf` on launch, which means users can add anything the app doesn't set explicitly direclty in their MPV config.

### Custom OSC (Lua)

The on-screen controls mpv shows during playback are custom Lua scripts in `scripts/` (`mpv-osc.lua` for normal playback, `mpv-osc-ambient.lua` for Ambient Mode), loaded via mpv's `--script=` flag. Options are passed in with `--script-opts=` (e.g. `transcode-offset=<sec>`). The remote's key events reach these scripts through the `keypress` IPC bridge described above.

#### What the OSC shows, and where the app tells it

While the menu is up the script lays a **~30% black scrim** over the whole frame, so white controls are not read against a white shot. It is drawn first, and cut away over the poster: mpv draws `overlay-add` art *under* a script's ASS, so without that hole the art would be dimmed twice. `assdraw`'s `rect_cw` plus `rect_ccw` makes the hole in one path, with a 1px `C_WHITE` hairline round the art afterwards so a poster with dark edges does not bleed into the dimmed frame.

The **top-left title block** answers what the seek bar never can: the bar says how far in you are, not what you are in. It is art beside two lines — the top one **what is playing** (the film, the episode as `S01E01: Magic Xylophone`, the video), the one under it **what that belongs to** (the show, the channel; nothing for a film, which names itself). Both lines are measured against the art beside them rather than against the font, so the block reads as one object.

**`MpvController::setNowPlaying(title, showTitle, posterUrl, contentRating, label, posterAspect, fitPoster, airingBeginsAt, airingEndsAt)`** feeds that block. A module calls it immediately before `loadAndPlay()`, which consumes and clears it, so a caller that sets nothing falls back to mpv's own `media-title` — right for a local file, useless for a streamed one (Plex hands out `/library/parts/…`, Jellyfin `master.m3u8`). Not for playlists: the `--force-media-title` it also sets would pin one name over every entry, which is why Local Files and Ambient Mode set nothing. Plex, Jellyfin and Emby set it again when autoplay swaps the episode under the player. **`setNowPlayingSource(server, profile)`** is the session half of it — the same `SERVER | PROFILE` strip the app keeps in its own corner, drawn beside the OSC's clock.

**`updateNowPlaying(title, showTitle, contentRating, airingBeginsAt, airingEndsAt)`** is for the one case a launch-time block cannot cover: text that changes while the *same* stream keeps playing. A Plex live channel rolls from one programme to the next without mpv ever loading a file, so the JSON the script read at startup goes stale where a new file would have replaced it. It pushes those fields over IPC as `script-message 240mp-nowplaying`, and the script redraws if the menu is up (a script-message carries only strings, so the numbers go through `tonumber` on the way back). The art is not among them: what it shows (the channel) has not changed, and re-sending it would mean another round trip for the same bitmap.

The title and show reach the script as a **JSON file** (`nowplaying-file=<path>` in script-opts) for the same reason the subtitle names do: script-opts is one comma-separated list, and a title is exactly the kind of string that has a comma in it. A path is not.

The **poster takes a round trip**, because `overlay-add` cannot scale — it draws raw premultiplied BGRA at exactly the size given, and only the script knows the window's OSD resolution:

1. The script sends `script-message 240mp-poster-request <w> <h>` the first time it draws the menu (and only if the JSON said a poster exists).
2. `MpvController` sees it as a `client-message` on the IPC socket, fetches the art through an `AppNamFactory` manager (so it is usually a cache hit on art the browse screen already pulled, and gets the `*.plex.direct` leniency), cover-crops it, fades it to 45% — premultiplied alpha means scaling all four channels is a uniform fade, and mpv's overlay has no opacity of its own — and writes it raw to a temp file.
3. It answers `script-message 240mp-poster-ready <file> <w> <h> <stride>`; the menu redraws twice a second, so the art appears a moment later.

Since art of the wrong size can only sit small or spill out, the script **checks the answer against what it currently wants** and, on a mismatch, drops it and asks again. That covers a window resized after the first request and a reply meant for the previous file arriving late; both numbers are logged (`poster request WxH`, `poster ready WxH`). `MpvController` drops a fetch that finishes after the next launch for the same reason, so autoplay cannot leave the previous episode's art on screen. The overlay draws over the video whether or not the menu is up, so it is removed on **both** teardown paths — the keypress that closes the menu and the auto-hide timer.

`posterAspect` is the shape the art is drawn in, width over height: `0` keeps the 2:3 of cover art, and a module handing over something else says so (`1` for a channel avatar, `16/9` for a video thumbnail). `fitPoster` says the art is shown **whole inside** that box rather than cover-cropped to fill it — cover art of any shape can lose its edges, but cropping a wide station logo to a square cuts the name out of it, the same distinction `PosterCell.logoArt` draws on the browse screen. A fitted poster is backed a shade off black instead of being left transparent: the script cuts its scrim away over the art, so undimmed frame would otherwise come through around a logo's transparent margins.

**The transport measures a programme when there is no file to measure.** `airingBeginsAt` / `airingEndsAt` are the guide's window as epoch seconds; both `0` (the default, and the only right answer for a file) leaves the OSC reading mpv's `duration` and `time-pos`. Live TV needs it because a live stream has no length at all — the bar would sit at nothing and both times would read `0:00`.

Only the **length** comes from the clock, though. The **motion** along it stays mpv's `time-pos`, and that distinction is the whole design: pausing a live stream does not pause the broadcast, but it does stop the viewer moving through the programme, and after a five-minute pause they are five minutes further *behind* the broadcast rather than five minutes further *through* it. A script reading `os.time()` would get that backwards, so it does not.

Position is therefore `time-pos + transcode_offset` — the same arithmetic that already places a Plex transcode resumed part-way through a file, which is the identical problem (the stream starts some way into the thing being measured). `MpvController::updateNowPlaying` recomputes that offset as `(now − airingBeginsAt) − time-pos` and pushes it with each new programme, because only the app has both halves. It is **re-anchored, never accumulated**: mpv's clock runs straight through a programme change, so the offset that placed the stream inside the old programme would place it an hour into the new one.

The right-hand time becomes a **countdown** (`-12:57`) rather than a length: what a file has left to run is a fact about the file, what a programme has left is a fact about the clock, and the sign tells them apart at a glance.

**`ENDS 21:45`** sits left of STOP: when what you are watching finishes, as a wall-clock time. "45 minutes left" is a number you have to do arithmetic on; the time itself is the answer. It is always **now plus what is left to run**, which is the one form that survives a pause — a film held for ten minutes finishes ten minutes later, and so does a live programme, because pausing puts the viewer that far behind the broadcast and they reach its end that much after it airs. Drawing the guide's `airingEndsAt` directly would be right only until the first pause. A live channel reaches this line at all because `total` is the programme's length by then, so the same expression serves both and there is no live branch here.

**Track info** (`AUDIO:` / `SUBTITLE:`) sits at the **foot of the controls**, under the button row, at three-quarters the OSC's font size: a footnote to the bar, not a heading over the picture, and the corner it used to occupy is the title block's now.

The **current time** sits top right, where the app's own corner clock is, so bringing the OSD up does not lose it. Right-aligned on the block's second line, under it, is one of two things and never both: the **content rating**, boxed the way a certificate card is (text in a border — those marks are trademarks, and ASS draws vectors and text, not bitmaps), or a **plain label** for a module with no certificate, which is where YouTube names the playlist a video is playing out of. All three video-server backends carry `contentRating` (Plex's `contentRating`, Jellyfin's and Emby's `OfficialRating`); `MpvController` strips the region Plex sometimes prefixes (`de/16` → `16`).

### Raspberry Pi headless hand-off (EGLFS)

On RPi Lite there is no display server; Qt draws via EGLFS straight to the KMS/DRM framebuffer, so the app and a fullscreen child can't both own the screen at once. **`DisplayHandoff`** (`src/util/DisplayHandoff.h/.cpp`) owns this hand-off for the whole app. `MpvController` delegates to it and does not implement any of the ioctls itself.

The order is load-bearing and was established against real Pi hardware — read the header comment before touching it:

- **`acquire(owner)`**: VT switch → `drmDropMaster` → save CRTC state. The VT switch goes *first* because it suspends Qt's render thread via the kernel's VT-switch signal before master is dropped; on kernels 5.8+ `drmSetMaster()` returns `EACCES` for non-root while another process holds master, and Qt EGLFS runs `VT_AUTO` and never drops master itself.
- **`releaseDeferred(owner, cb)`**: after 200 ms (>3 VSync at 60 Hz, so the child's last pending KMS commit can clear), `drmSetMaster` → restore CRTC → switch back, then run `cb`. The restore uses **legacy** `drmModeSetCrtc`, not an atomic commit: the child's atomic cleanup leaves `CRTC_ACTIVE=0` and EGLFS would get `EINVAL` on its first page flip.
- **`releaseNow(owner)`**: synchronous, for shutdown; `MpvController`'s destructor calls it so quitting mid-playback no longer leaves the Pi on a blank VT.

The `owner` token means two subsystems can never both believe they hold the screen — `acquire()` refuses if someone else holds it, and `isHeldBy()` is the re-entrancy guard for relaunching a child without releasing first. All of it is Linux-only in effect (`isHeadless()` is false on macOS and whenever a compositor is present), where the hand-off is just a fullscreen window swap.

Two consequences that are easy to get wrong, both of them Pi-only and both invisible on any other target:

- **Whatever Qt last put on the glass stays there for the whole hand-off.** The VT switch suspends Qt's renderer, but nothing clears the framebuffer, and we no longer hold DRM master so we cannot. A child that draws immediately (mpv) hides this completely; a child that draws late or never leaves the previous frame frozen on screen, which reads as a hang rather than a hand-off. So **paint the screen you want frozen, wait for it to be presented, and only then call `acquire()`**. As an example `modules/scripts/views/Takeover.qml` does this with a short timer, deliberately not `Qt.callLater`, because what matters is a frame actually presented instead of the scene graph being updated.
- **The VT we switch to must not be the one we are on.** `findFreeVt()` starts from `VT_OPENQRY`, which reports the lowest VT the kernel considers unused. Activating the VT we are already on would be a silent no-op so Qt never suspends, and master is then dropped out from under a still-drawing Qt, with nothing logged because the ioctl succeeds. `findFreeVt()` takes the active VT and steps past it so that cannot happen.

  In practice `VT_OPENQRY` does not return Qt's own VT, because Qt EGLFS opens `/dev/tty0` for its `KD_GRAPHICS`/`VT_AUTO` handling and `/dev/tty0` *is* the foreground console, which pins that VT's tty count. Measured on an installed card: idle `tty1`, during playback `tty2`, back to `tty1` on exit.

  Note that `VT_OPENQRY`'s notion of "in use" is the *virtual console's* tty count, not "some process has `/dev/ttyN` open". `fuser -v /dev/tty1` comes back empty under the service and yet VT 1 is in use, because the process pinning it opened `/dev/tty0`. `fuser` on the numbered node is the wrong instrument here; read `/sys/class/tty/tty0/active` instead.

On a dev box neither of these bites the same way, because `autovt@` is unmasked there: a getty spawns on the VT we switch to, repaints the console for us, and holds that VT open so `VT_OPENQRY` keeps moving up. The login prompt you see mid-hand-off on a dev Pi is that getty, not anything 240-MP drew.

### Adding a different hand-off target

The longer-term vision is to hand off to *other* purpose-built tools (e.g. RetroArch), not just mpv. `MpvController` is the template: launch the external tool as a `QProcess`, drive it over whatever control channel it offers, and surface progress/exit back to QML via signals. **Use `DisplayHandoff` for the screen — do not re-implement the VT/DRM ioctls in a new caller.**

The **scripts module** (`modules/scripts/`, `src/modules/scripts/`) is the second worked example, and generalises the idea to arbitrary user programs. Its `ScriptLauncher` has things that `MpvController` doesn't need:

- **Two run modes per target.** `console` keeps 240-MP on screen and streams the child's merged output into a QML view; `takeover` gives the child the display. The split is per-target. On macOS / desktop Linux / SteamOS a takeover needs nothing at all (the child's window covers ours), and only headless Linux needs the `DisplayHandoff` bracket.
- **Nothing is handed over before a spawn that might still be refused.** All validation happens first, `QProcess::errorOccurred(FailedToStart)` is handled explicitly (`finished` is *never* emitted in that case), and a started-watchdog covers "started but silent". 
- **`setsid()` in a child-process modifier**, so the child leads its own process group: `killpg` reaches everything it spawned, and an empty group is how you know the screen is free again. A launcher script that backgrounds its real work and exits immediately would otherwise have the display taken back out from under its children.
- **Report only after the display is restored.** The caller pops its view on the "finished" signal; doing that while the framebuffer still belongs to the child draws into memory you don't own.
- **No stop key during a takeover.** A takeover child should own input for it's whole run, and on EGLFS every keystroke is double-delivered (Qt's libinput and the child both read the same evdev devices) so any tap-to-stop key would also fire inside inside a launched takeover application (For example ESC/Back is used by RetroArch's to navigate its menus just like its used inside 240-MP so pressing that key while RA is open would SIGTERM the session mid-run). With this in mind, the runner view is set up to swallow Back events while a takeover is busy and offers no direct stop key. What covers failures instead: the started-watchdog and `FailedToStart` handling, the downgrade-to-console refusal when display state can't be saved, and `~ScriptLauncher`'s SIGTERM → SIGKILL + `releaseNow()` at app quit. Console mode and downgraded runs (where 240-MP kept the screen) still have the Back-to-stop key with `requestStop()`'s SIGTERM → SIGKILL escalation.

## Card Hand-off (NFC → a module)

An NFC card's tag file can point at content another module owns, rather than at a file this module can play itself. The NFC module resolves *which* module, and that module resolves *what to play* — auth, lookup and playback stay where they already live.

**The tag file.** Line 1 is the card UID, line 2 the ref, and an optional line 3 a bare mode token (`shuffle`). Line 3 is deliberately generic rather than Plex-specific so `.m3u` and YouTube-playlist cards can use the same slot later. `parseTagFile` stopped at two lines before, so a third line is backwards-compatible meaning existing cards are unaffected.

**Routing.** `handoffModuleForRef()` in `NfcReaderBackend.cpp` maps a ref's URI scheme to a module id via `kHandoffModules`. `http`/`https` are deliberately absent as those are stream URLs this module hands straight to mpv. A recognised scheme emits `cardHandoffRequested(moduleId, ref, mode)` instead of `playbackRequested(videoPath)`; the file/stream path is untouched. If the target module is disabled the card is refused (`AppCore::is_module_enabled`).

**Navigation.** `Items.qml` resolves the target's entry point with `AppCore::module_entry_point(moduleId)` and emits the **shell-level** `navigateTo` (not the router's internal one). That is why `nfc_reader/views/Root.qml` declares `signal navigateTo(...)` and calls its own router function `navigateToView()`: `Main.qml` only listens for a signal named exactly `navigateTo` on the loaded module, so the name has to be free.

**The receiving module carries a `CardPlay.qml`.** `modules/plex/views/CardPlay.qml` is the reference. It is a thin resolver, not a view the user navigates to:

- `Root.qml` routes to it on `navParams.cardRef`, **ahead of and exclusive of the auth/user gate**. For Plex, falling through that would land a card tap on `UserSelect.qml` whenever `auto_sign_in` is off, and switching profiles from a card would sidestep the profile PIN. A missing sign-in or a pending PIN is surfaced as an error, never a prompt.
- So it resolves the ref, builds the stream, then **`replaceWith("Player.qml", …)`** — `replaceWith` doesn't push to the nav stack, so the stack stays `[NFC Root] → [Player]` and backing out of playback returns straight to the NFC tap screen instead of stranding the user inside a module so they can tap another card easily after playback stops.
- It doesn't write player state back to the service (Plex's `set_audio_stream` / `set_subtitle_stream`) — a card tap must not mutate stored per-item preferences. Whatever the server already prefers is what plays.
- Errors render in the NFC module's visual language, so a card tap looks the same whichever module ends up serving it.

**Adding another module** (e.g. Jellyfin, Emby, …) means: a row in `kHandoffModules`, a `CardPlay.qml`, and a `cardRef` branch in that module's `Root.qml`. Nothing in the NFC module is service-specific.

### Plex specifics

- Cards store a Plex **guid** (`plex://movie/…`), never a ratingKey because guids survive library re-scans and moves between servers, which a physical card on a shelf will benefit from. Resolution is `/library/all?guid=` unscoped: it searches every section, so the card says *what* to play and the app decides *where* it lives. That query omits `Media`/`Part` unless given a `type=` filter so the chosen item is always re-fetched by ratingKey. External ids (`imdb://`, `tmdb://`) are **not** resolvable through this filter.
- Libraries on a legacy metadata agent report `com.plexapp.agents.*://…` guids. They resolve fine and are routed to Plex by prefix, but they're agent-scoped: re-agenting such a library breaks cards written against it.
- **Cards never switch server or user.** `select_server` persists config (see the settings-write rule), and auto-switching a Plex Home profile would be a PIN bypass in physical form. Wrong server / no permission / signed out are all errors.
- A **shuffle** card sets `trackProgress: false` on the Player, suppressing both `update_timeline` calls. Progress reporting is entirely client-side, so that is sufficient to leave watched state, Continue Watching and on-deck untouched.
- Shuffle keeps rolling via a **shuffle bag** in `PlexBackend` (`m_shuffleBag`): a shuffled permutation played to exhaustion then reshuffled, rather than independent random draws, which clump badly over the hours a jukebox card runs. `resolve_card` reports the show/season as `cardScope`; the Player's EOF branch calls `load_random_episode(scope)` instead of `load_next_episode(ratingKey)`. Both emit `nextEpisodeReady`, so the advance itself is shared. Continuation respects the module's `autoplay_next_episode` setting.

## Input (InputManager)

All input arrives in QML as **ordinary key events** — views bind `Keys.onPressed` / `Keys.onUpPressed` / etc. and never know which physical device produced the event. Keyboards and keyboard-emulating USB remotes deliver real key events natively; **USB game controllers** are translated by `InputManager` (`src/input/InputManager.h/.cpp`, exposed to QML as the context property **`inputManager`**).

**Please don't add gamepad-specific handling to a view** — if a view handles the right keyboard keys then with this setup it will also handle gamepads.

### How it works

1. **SDL2 GameController** — `SDL_Init(SDL_INIT_GAMECONTROLLER)` only (no video subsystem, so it works headless under EGLFS). A 16 ms `QTimer` on the main thread polls SDL events: hotplug (`CONTROLLERDEVICEADDED/REMOVED`), buttons, and axes. SDL's built-in controller database normalizes most pads to a standard layout, so defaults "should" work out of the box. The `SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS` hint keeps controller input flowing while mpv's window holds OS focus during playback.
2. **Buttons → actions → key events** — each SDL input maps to one of seven named actions below, and each action synthesizes one Qt key. Button identities are **positional** (using an Xbox reference layout — `SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS` is forced off so Nintendo-type pads behave the same): `a` is always the south face button and input.cfg accepts `south`/`east`/`west`/`north` aliases to try to make it easier to wrap my head around =)

   | Action | Qt key | Default binding |
   |---|---|---|
   | `up` / `down` / `left` / `right` | arrows | D-pad, left stick, LB/RB (left/right) |
   | `select` | Return | A |
   | `back` | Escape/Backspace | B, Select |
   | `play_pause` | Space | Start |

3. **Delivery** — while the Qt window is **active**, synthesized `QKeyEvent`s are posted to the root QQuickWindow and reach the QML `activeFocusItem` like real key presses; on RPi/EGLFS the window is always active, so during playback they flow through the Player views' existing key forwarding (`mpvController.sendKey(...)`). When the window is **inactive** (like on MacOS where fullscreen mpv holds OS focus) and QQuickWindow has no `activeFocusItem`; `InputManager` instead emits `mpvKeyRequested(key)`, which `main.cpp` connects to `MpvController::sendKey`.  That will drive mpv directly over IPC with the same key names. The net result is that gamepads drive mpv identically to the keyboard on both platforms. Held directions auto-repeat (400 ms delay, 100 ms interval) so lists and ff/rw feel like keyboard repeat.
4. **User overrides** — `$DATA_ROOT/input.cfg` (`<input> <action>` per line, `#` comments, merged over defaults, live-reloaded via `QFileSystemWatcher`). An optional `$DATA_ROOT/gamecontrollerdb.txt` can add SDL mappings for exotic pads. Check out grammar and examples in [BUILDING.md → Gamepad input](BUILDING.md#gamepad-input-inputcfg).
5. **Adaptive footers** — `inputManager` exposes `lastInputDevice` (`"keyboard"` | `"gamepad"`, tracked via an app-wide event filter that ignores the synthesized events by their magic `nativeScanCode`) and a `hints` map (`back`, `select`, `navigate`, `change`, `browse`, `play_pause`). Main.qml mirrors it as **`root.hints`**, and footer hint labels bind to that — e.g. `root.hints.back + ":BACK"` renders `[ESC]:BACK` while the keyboard is active and `[B]:BACK` after a controller press, reflecting the live mapping. Views should bind to `root.hints.*` (similar to how we handle `root.sh`), **not** `inputManager.hints.*` because id-resolved `root.*` will stay valid when swappig views.  If you don't when the module Loader swaps views, the dying view's context properties will resolve to null and bindings on them will throw TypeErrors during teardown. Face-button labels are translated to what's printed on the **last-touched** controller via `SDL_GameControllerGetType` (Nintendo swaps A/B & X/Y; PlayStation shows X/O/SQ/TR), and `label <button> <text>` lines in input.cfg override them for pads that misreport their type. New views with footers should now use `root.hints.*`, and not hardcoded `[ESC]`/`[ENTER]` strings like I had in my previous implementation.

### Input survives a display hand-off

On RPi/EGLFS, input keeps flowing while Qt is VT-switched away: Qt's libinput/evdev handlers and SDL both read `/dev/input/event*` directly, with no VT gating. **Only rendering is suspended.** That's why a Player view can forward keys to fullscreen mpv over IPC on the Pi.

## C++ Backend Patterns

Backends are `QObject` subclasses registered via `registerModule(...)` before the engine loads.
Please review `PlexBackend` as a reference implementation.

- All HTTP via `QNetworkAccessManager` — async, on the main thread, no worker threads needed.
- Results returned to QML via signals.
- Auth/state persisted to JSON files in the data dir.
- `Q_INVOKABLE` for slots called from QML; `signals:` for callbacks to QML.
- For dynamic settings dropdowns, emit `dynamicOptionsReady(key, [{id, label}])` — auto-connected; `AppCore` re-emits with the module ID prepended.
- For auth-gated modules, emit `authStateChanged()` on sign-in/out — auto-connected and re-emitted as `moduleAuthStateChanged(moduleId)`.
- To react to your own settings changing, add a slot `onSettingChanged(moduleId, key, value)` — auto-connected to `moduleSettingChanged`.
- A backend resolves its own configured paths in its constructor — e.g. `LocalFilesBackend` / `AmbientModeBackend` read `media_directory` from `config.json` (defaulting to `dataRoot/media` / `dataRoot/ambient`). `main.cpp` does not touch module paths.

## QML View Patterns

### Root.qml — module router

Every module requires `Root.qml` as its entry point. It owns the internal nav stack and handles exiting back to the module list.

```qml
import QtQuick

FocusScope {
    id: moduleRoot

    signal goBack()

    property var navParams: ({})

    // must match your manifest id
    property var _moduleInfo: appCore ? appCore.get_module_info("com.240mp.<name>") : ({})
    property string moduleName: _moduleInfo.name || ""
    property string moduleIcon: _moduleInfo.icon || ""

    property var navStack: []
    property var currentParams: ({})

    function navigateTo(viewPath, params, fromState) {
        var resolved = Qt.resolvedUrl(viewPath)
        navStack.push({ source: internalLoader.source, params: currentParams, listState: fromState || {} })
        currentParams = params || {}
        internalLoader.setSource(resolved, { "navParams": params || {} })
    }

    function navigateBack() {
        if (navStack.length === 0) {
            moduleRoot.goBack()
            return
        }
        var prev = navStack.pop()
        if (!prev.source || prev.source.toString() === "") {
            moduleRoot.goBack()
            return
        }
        var restored = Object.assign({}, prev.params)
        restored.navListState = prev.listState || {}
        currentParams = restored
        internalLoader.setSource(prev.source, { "navParams": restored })
    }

    Loader {
        id: internalLoader
        anchors.fill: parent
        focus: true
        onLoaded: { if (item) item.forceActiveFocus() }

        Connections {
            target: internalLoader.item
            ignoreUnknownSignals: true
            function onNavigateTo(path, params, listState) { moduleRoot.navigateTo(path, params, listState) }
            function onGoBack() { moduleRoot.navigateBack() }
        }
    }

    Component.onCompleted: navigateTo("Items.qml", {})
}
```

**Rules:**
- `id` is always `moduleRoot`.
- `moduleName` / `moduleIcon` always come from `appCore.get_module_info(...)` — never hardcoded.
- `goBack()` is the only signal that leaves the module — child views never emit it directly.
- `navigateBack` merges `navListState` back into params on pop so list views can restore position.
- For auth flows that need `replaceWith` (navigate without pushing to the stack), please see the Plex module as a reference.

### Items.qml — list view

```qml
import QtQuick
import Components

FocusScope {
    id: itemsRoot

    property var navParams: ({})
    property var navListState: navParams.navListState || ({})

    signal navigateTo(string path, var params, var listState)
    signal goBack()

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
            goBack()
            event.accepted = true
        }
    }

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
    }

    ListView {
        id: itemList
        anchors.topMargin: root.sh * 0.25
        anchors.leftMargin: root.sw * 0.115625

        // restore list position on back-navigate
        Component.onCompleted: {
            var restore = navListState.currentIndex !== undefined ? navListState.currentIndex : 0
            currentIndex = Math.min(restore, Math.max(0, count - 1))
            positionViewAtIndex(currentIndex, ListView.Contain)
        }

        // Up/Down with wraparound. The positionViewAtIndex call is required:
        // changing currentIndex alone does not scroll a clipped ListView, so
        // without it a wrap moves the selection off-screen.
        Keys.onUpPressed: {
            if (count === 0) return
            if (currentIndex > 0) currentIndex--
            else currentIndex = count - 1
            itemList.positionViewAtIndex(itemList.currentIndex, ListView.Contain)
        }
        Keys.onDownPressed: {
            if (count === 0) return
            if (currentIndex < count - 1) currentIndex++
            else currentIndex = 0
            itemList.positionViewAtIndex(itemList.currentIndex, ListView.Contain)
        }

        Keys.onReturnPressed: {
            navigateTo("Detail.qml", { item: model[currentIndex] }, { currentIndex: currentIndex })
        }
    }
}
```

### Detail.qml — leaf view

```qml
import QtQuick
import Components

FocusScope {
    id: detailRoot

    property var navParams: ({})

    signal goBack()

    focus: true
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
            goBack()
            event.accepted = true
        }
    }

    AppBar {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.topMargin: root.sh * 0.125
        anchors.leftMargin: root.sw * 0.125
        iconSource: moduleRoot.moduleIcon
        title: moduleRoot.moduleName
        subtitle: navParams.item || ""
    }
}
```

**View rules:**
- Always declare `property var navParams: ({})` — the router passes params via `Loader.setSource`.
- List views also declare `property var navListState: navParams.navListState || ({})` and restore position in `Component.onCompleted`.
- `navigateTo` always takes 3 args: `(path, params, listState)` — pass `{ currentIndex: listView.currentIndex }` as listState when pushing to a detail view. Detail views with multiple focus rows (play button / list) also pass `focusRow` in listState and restore it in their data-loaded handler, so backing in lands on the row the user left.
- Up/Down navigation wraps: past the last item returns to the first and vice versa, always followed by `positionViewAtIndex(..., ListView.Contain)` (see the handlers in Items.qml above). Views with an A–Z letter panel additionally keep `letterList.currentIndex` in sync on every move and wrap the panel itself — `modules/jellyfin/views/Items.qml` is the reference.
- Leaf views only need `signal goBack()` — no `navigateTo`.
- Use `root.sh` / `root.sw` for all margins and sizes — never hardcoded pixels. This keeps layouts responsive across CRT (240p/480i, watch overscan) and HDMI/LCD.
- Access shared state via `moduleRoot.moduleName`, `moduleRoot.moduleIcon`.
- Navigate via signals — never call router functions directly.
- `navParams.fromAppStartup` is `true` only when the app booted straight into this module because it's the configured **Start On Module** — never when the user navigated in from the main menu. `Main.qml` sets it on the startup-module `setSource`; a module's `Root.qml` forwards it by passing `navParams` into its first `navigateTo`. Use it to gate boot-only behaviour such as Ambient Mode's Auto-Launch Playback, so the module's normal screens stay reachable from the menu.
- A view that emits `navigateTo` from its own `Component.onCompleted` must defer it with `Qt.callLater` — the router's `Connections { target: internalLoader.item }` only rebinds after `setSource()` returns, so a synchronous emit goes out before anything is listening.

## Poster Art

Off by default. The global `poster_grid` app setting (Settings → APPLICATION) switches the media modules between text rows and cover art. `Main.qml` mirrors it as `root.posterGrid`, which views bind the same teardown-safe way they bind `root.hints`.

The building blocks are shared and backend-agnostic: a host passes resolver functions (`posterSource`, `titleText`, …) and the component never learns which backend the items came from. [PosterGrid](#postergrid-viewscomponentspostergridqml) is the tiled browser, [PosterShelf](#postershelf-viewscomponentspostershelfqml) one horizontal row under a heading, [ShelfList](#shelflist-viewscomponentsshelflistqml) a stack of those, and [PosterCell](#postercell-viewscomponentspostercellqml) the single cell all of them draw.

### Plex

`Items.qml` swaps its `ListView` for a [PosterGrid](#postergrid-viewscomponentspostergridqml) on media lists only — directory rows (hubs, collections, playlists, categories) have no artwork and stay as text — and the movie / episode / show / season detail views show the poster above their action buttons, moving their list section alongside it rather than below. The show and season views also draw each sub-list row's own art left of its title, in a slot reserved for every row so titles stay aligned.

The home screen (`Libraries.qml`) becomes a shelf per library, each holding **that library's whole menu as tiles** followed by whatever it has in progress. A tile only appears when the library actually has that thing, which costs `check_section_capabilities` per library plus one Continue Watching fetch covering all of them; `capabilitiesLoaded` now carries the `sectionId` it answered for, without which several libraries cannot be probed at once (`Library.qml` guards on it too). The menu is one `ListView` of mixed entries — `{kind: "row"}` and `{kind: "shelf"}` behind a `Loader` delegate — with focus never leaving it: Up/Down step entries whatever their kind, Left/Right are forwarded to the selected shelf through `PosterShelf`'s `moveLeft()`/`moveRight()`, which is what `highlighted` exists for.

**LIVE TV** is a shelf too, on a server whose DVR has a lineup: the same spine card leading the row (it opens `LiveChannels.qml`, the full list the row used to be) followed by one **square** cell per channel, carrying the station logo the EPG supplies — `PlexBackend::live_channel_logo_url(channel)`, which passes an already-absolute provider URL straight through and hangs a token on a server-relative one, fetching it raw rather than through `/photo/:/transcode` so the logo's transparency survives into the light themes. Those cells are `logoArt`: a station's mark is not cover art, so it is fitted whole inside the square and held an eighth of the cell off its edges — cropped to fill, a row of them reads as one continuous band and a wide mark loses its ends. The channel number rides the foot of the cell (`cornerTagSource`), in the margin the mark gives up, and a station the guide has no logo for falls back to `PosterCell`'s titled card carrying number and name, which is why a lineup with no artwork at all still reads.

That row runs at `shelfPosterH * 2/3` — one cover's *width*, and square, so it measures the same step as every other row on the screen instead of running wider than the posters above and below it. A mark stays recognisable that small, the way a YouTube channel's avatar does, and the height the shorter row gives back buys more of the menu. Its spine measures against that shorter height so both shelves' spines come out one width. The lineup joins the capability probes in the gate `resolveMenu()` holds the menu on, and an empty one leaves LIVE TV the nav row it has always been.

Watching one, the OSD names the **programme**, not just the channel: `tune_channel` gets the airing's *name* for free from the DVR's grab metadata, and `load_live_programme(channel)` asks the guide for the rest — the provider proxy's `grid` route, narrowed server-side to `beginsAt<=now` and `endsAt>=now`, so every airing that comes back is on air and only the channel has to be matched. Which of the channel's names the guide files an airing under varies by EPG provider, so `airingIsOnChannel` tries the id, the number and the call sign against every `channel*` field on the airing's `Media` entries. `LivePlayer.qml` checks once a minute against the airing's own `endsAt` rather than scheduling a timer to it — live sport runs over — and pushes each change through `MpvController::updateNowPlaying`, since the stream never restarts. That window does triple duty: it schedules the next look, it is what the OSD's seek bar and times measure, and it is the `ENDS 21:45` line — so it is taken **only** from the guide. The window on the grab's own `Media` entry looks like the same thing and is not: it describes the block the tuner is grabbing, and a programme listed 21:30–22:30 came back from it ending at 22:00, which is exactly what the OSD then showed. `tune_channel` therefore emits the name and blanks the window, and the guide is asked as soon as the stream is handed to mpv rather than on the refresh Timer's first tick, so the bar is there when the OSD is. Its answer usually beats mpv's first frame, when the launch file is already written and no IPC socket exists yet to push it down, so `onPositionChanged` pushes the block once when playback actually starts. A guide that answers nothing costs the OSD a programme name and that line, and nothing else: the top line falls back to the channel, and the station logo beside it is the same `live_channel_logo_url` art the shelf uses, square and fitted whole. The channel list can read that same guide for the whole lineup before anything is tuned — see [TV Guide](#tv-guide).

The module's **Libraries** setting (a `multiselect_submenu`, keyed `<machineId>_<sectionKey>` so the same section number on two servers is two choices) hides a library everywhere, not only from the library list. `/hubs/continueWatching` answers for the whole server, so `load_continue_watching` runs its items through `enabledLibraryItems` *before* flattening seasons — a season in a switched-off library would otherwise cost a request to expand items nobody will see.

`PlexBackend::poster_url(item, w, h, context)` builds the URL. It takes the whole item map so the "which artwork for this type" rule lives in one place, and `context` picks two independent things — *which* artwork, and whether it is cropped to fill a fixed-shape cell or fitted whole:

| `context` | Artwork for an episode | Fit |
|---|---|---|
| `"grid"` (default) | the show's poster | cropped to the cell |
| `"shelf"` | own still → season → show | cropped (the cell is cut to the art's own shape, so nothing is lost) |
| `"detail"` | own still → season → show | fitted whole |
| `"badge"` | the season's poster → the show's, **never** its own still | cropped to the cell |

A grid gives an episode its show's poster so a whole library tiles as one shelf; a shelf is a handful of items, where the episode's own still identifies it better. `"badge"` is the corner overlay that puts back what a still gives up. `poster_aspect(item, context)` returns the shape the art `poster_url` *would* return — `16/9` for an episode's own still, `2/3` for cover art — so shelves can cut each cell to its own width; that is why the rule lives beside the fallback chain instead of being guessed in QML. Resizing is server-side (`/photo/:/transcode`), with the token as a query param because a QML `Image` cannot set the `X-Plex-Token` header.

#### SERVER | PROFILE status line

`modules/plex/views/StatusLine.qml`, instantiated once by the module's `Root.qml` so it outlives a view swap. Which server you are browsing and who you are browsing it as change what every list contains, and nothing else says them once you are past the main menu.

Only the main menu makes it a nav target (`Root.statusNavigable`): deeper in, switching would throw away the path that got you there, so the switch lives one BACK away. A view hands focus up to it by calling `moduleRoot.focusStatus()` when a step upward runs off the top of its own content — the call returns whether the corner took it, so the view falls back to its usual wrap when there is nothing up there. `Root.qml` dims the loader while the corner has focus, since every view here draws its selection from a `currentIndex` rather than from focus.

The line claims its width from the shell through `root.statusReserve` (a `Binding`, so the claim is released when the module unloads) and anchors at `root.statusMargin` on `root.cornerCenterY`. `root.cornerReserve` is what anything at the right end of the top row subtracts from its own width — `AppBar`'s, and the IP address in `views/Settings.qml`.

`AppBar` also gained `subtitleElide`: a name reads from the left so its tail goes, but a **breadcrumb**'s tail says where you actually are, so `Items.qml` sets `Text.ElideLeft`. It builds that breadcrumb from a `crumbs` array carried in `navParams`, each hop appending the title of the row it opened, so a category chain reads `MOVIES > CATEGORIES > DIRECTOR > STEVEN SPIELBERG` rather than four screens that all say `MOVIES`.

### YouTube

With the setting on, `Channels.qml` draws its channel list as a grid of profile pictures — square, not 2:3, because an avatar is — keeping the A–Z panel and its Right-to-browse hand-off. A channel's RSS feed carries no artwork, so `YouTubeBackend::channel_art_url(channelId, size)` answers from a cache the module scrapes in the background; `channelArtLoaded` announces each one, and the view bumps an `artRev` counter that its `posterFor()` reads, so cells re-resolve in place rather than the model being reassigned (which would reset the grid under the selection). `channel_art_for(id, name, size)` is the same lookup by *name*, for Watch Later, History and playlist entries, which carry no channel ID.

`Subscriptions.qml` — the module's one video list, serving the feed, a channel, a playlist, Watch Later and History — draws each row's own thumbnail from `video_thumb_url(videoId)`, which needs no cache and no signal: the URL follows from the ID, and `mqdefault` is the only stock size that is 16:9 without letterbox bars. In **channel** and **playlist** modes that view also takes the shape of a Plex season — the artwork heads the left column with its name and video count beside it, and the list moves right of it, `sectionX`/`sectionW` exactly as `ItemSeason.qml` computes them. A channel is headed by its avatar and drops the per-row channel name (the header says it); a playlist is headed by its own cover, `playlist_thumb_url(playlistId)`, and keeps it, because a playlist mixes channels.

The module's own menu (`Items.qml`) becomes a mixed list of nav rows and shelves behind one `Loader` delegate, focus never leaving the `ListView`, Left/Right forwarded to whichever shelf holds the selection. Each shelf leads with a **card** — a `PosterCell` with no art, whose title is read up it as a spine — that opens the full list the shelf replaced. The menu holds at `LOADING` until `channelsLoaded` arrives (or a 5s timer gives up) rather than drawing a text row that becomes a shelf a second later; a list that never comes back leaves `CHANNELS` as the nav row it has always been.

`Playlists.qml` goes the same way one level in: each playlist is drawn as a `ShelfList` shelf of its own videos. It costs no extra network — `load_playlists()` already fetches every playlist's contents to count them.

`Video.qml` is the screen a video gets before it plays — description, counts, actions — the step a Plex episode takes through `Item.qml`, and laid out the same way. Every list in the module now lands there rather than in the Player. `video_detail()` serves whatever is held (a channel feed carries the description in full, so a video reached from Subscriptions has its text before the screen paints) and `load_video_detail()` fetches the rest, announcing it with `videoDetailLoaded`.

Both YouTube views reach `youtubeBackend` from inside bindings, which is the one place that needs the null guard `root.hints` exists for: a context property reads back null while a view's `Loader` tears down and every binding runs one last time.

Everything the module fetches goes to **one host**, which answers an address asking for too much by refusing all of it — every feed comes back `404`, YouTube's own channel included. Feeds are cached to disk (`youtube_feed_cache.json`), sent a few at a time, and a pass that mostly fails pauses the module for `kThrottlePauseMs`, remembered across restarts. **Playlists are cached harder** (`youtube_playlist_cache.json`, `kPlaylistCacheTtlMs`), because they cost the most: a `yt-dlp` subprocess over as many as 500 entries. The longer window is affordable because the refresh is invisible — `ensurePlaylistsFresh()` hands the waiting view whatever is held before it queues anything, including a caller arriving while a refresh is already in flight.

QML fetches those images through the QML engine's own `QNetworkAccessManager`, which is separate from the one each backend owns. `AppNamFactory` (`src/net/`, installed in `main.cpp` before `engine.load`) gives that manager a 64 MB `QNetworkDiskCache` under `<dataRoot>/cache/images` and the same narrow `*.plex.direct` certificate leniency as `PlexBackend::ignoreSslErrors` — without which posters silently fail on a system with an incomplete CA bundle.

## TV Guide

Off by default, and independent of the artwork above it. The global `live_epg` app setting (Settings → APPLICATION, **TV Guide**) puts what is on each live channel beside the channel, read from the DVR's own EPG. `Main.qml` mirrors it as `root.liveEpg` the way it mirrors `root.posterGrid`, and `LiveChannels.qml` binds it through `root` for the same teardown reason.

The two switches give the live lineup four layouts, all of them the same `ListView` with the same keys and the same selection:

| `live_epg` | `poster_grid` | `LiveChannels.qml` draws |
|---|---|---|
| Off | Off | the list of channel names, its highlight hugging the line rather than banding the row |
| Off | On | the **channel page** — a row per channel: the station's mark, then its number over its name, which has the whole row to run in |
| On | Off | each name with the time what is on it started, a rule under that time measuring how much of it has gone, and its name |
| On | On | the same page as a **guide page** — two more columns beside each channel: what is on with its bar and window, and what is on next |

The artwork is what decides the *shape* — a mark needs more height than a line of text does, so `artPage` (`root.posterGrid`) is what turns the lineup from a list of names into a page of channels. The guide then fills that page's right-hand half or leaves it empty: one delegate draws both, the listing columns carrying `visible: channelsRoot.epg`, and the name widens into the room they gave up (`nameCol`) rather than stopping short in front of an empty row. The headings drop to `CHANNEL` alone the same way.

That page is the only screen in the app laid out as a table, so its columns are measured once on `channelsRoot` (`chanX`, `nowCol`, `nextX`, …) and read by both the heading row and every delegate — a heading cannot drift off the column it names. It takes the taller slot the poster views use, clipped to a **whole** number of rows: a row three lines deep cut through the middle by the list's edge reads as a fault, where a single line of text clipped by the same edge does not. Each column's text stops one gutter short of the next column, or two runs of text meet in the middle of the gutter and the row reads as one sentence. Long lines scroll on the selected row and clip on the others, the idiom every text list in the app uses; the station logo is `PosterCell`'s `logoArt` again, the same art the shelf draws, so a channel with no logo falls back to the titled card rather than to a hole in the column.

In **both** text layouts the channel number is a column of its own, measured off the *widest number the lineup actually has* (`widestNumber` through a hidden ruler `Text`, so nothing assumes the face is monospaced) — otherwise a lineup running 1 to 12 starts "ONE" a character further left than "TEN" and the names read as two lists. The plain row keeps its number and name as one moving line inside the clip, so the highlight still wraps the words and the scroll still carries them whole; only where the name starts is new. A column sized for three digits a lineup does not use would be width taken off the names it does. The time column is measured the same way, off the widest reading the clock writes (a 12-hour one carries its AM/PM), and for a sharper reason: a column taken as a *share of the row* is a fraction of the screen's width while the type in it is a fraction of the screen's height, so on a wide screen the column grows and the reading does not — and the gap that opens between the time and the programme name is width the name should have had.

The bar is the playback OSD's seek bar at list size — an outlined box with an inset fill, measuring the same thing. In the text list there is no line of height to spare for one, so it takes its thin form (`ProgressLine`): a two-pixel rule under the start time, since the reading belongs to the clock beside it, and only as wide as that reading — run on to the column's own width it reads as a rule under the row rather than under the time. No border and no inset at that size — those would be the whole of it — so the track is the same ink held back to 35%, which every theme's palette answers for on its own. It is driven by the **wall clock**, not by mpv's: the OSD's reading has to stop when the viewer pauses, and nobody is watching these channels yet. One `nowSecs` property ticked every 15 seconds moves every bar and every countdown on the screen together; a bar across a half-hour listing moves about a pixel in that time, and nothing here is worth a repaint per second on a Pi.

`PlexBackend::load_live_guide(channels)` answers the whole lineup with **one** request — the same provider-proxy `grid` route `load_live_programme` uses, over a window running from "has not ended" to four hours out, which is what buys the next column. Airings land under the channel they are on by `airingIsOnChannel`, the same match, tried against each channel until one takes it; `now` and `next` are then picked by clock rather than by position in the answer, since the sort is asked for and not promised and a guide can carry two overlapping airings on one channel. `liveGuideLoaded` carries `channelId -> {now, next}` with a channel the guide had nothing for **absent** rather than present and empty. `resolveLiveProvider` is the provider lookup both calls share, and hands back an empty identifier rather than an error, so each caller answers its own signal.

A listing's **rating** rides with its times: after the window on the guide page (`12:56-13:26 [G]`), after the start time in the text list (`12:56 [G]`). The mark is the playback OSD's — a box around the rating, which is as official as this can honestly look, the real marks being trademarked artwork — drawn shorter than the line it sits beside, since a rating is a footnote to the time rather than a second reading of it, and it appears only where the guide carries one. In the text list it sits on the row's own centre line, with the programme it belongs to: the time beside it is held above centre to leave room for the rule under it, and a mark following that would sit off the row's line for no reason. A guide writes a rating with the body that issued it (`us:TV-14`, `nz/PG`) and a box this size has room for the rating or for both, so `ratingOf` keeps what follows the issuer: where the viewer is watching is not news to them. In the text list the mark has a column held open for it, measured off `widestRating` the same way the clock and the numbers are measured — held open for every row or for none, since a mark drawn wherever each row's own clock happens to end would set the column zigzagging down the page.

The view re-reads the guide when the first programme in it ends, floored two minutes out — across a long lineup something ends most minutes, and the whole grid is one request — or in ten when the answer listed nothing on air anywhere, which is how long `LivePlayer.qml` waits on the same silence. A guide the server will not serve is not an `errorOccurred`: it costs the list its listings and nothing else, and every channel still tunes.

## Components (WIP)

Shared QML components live in `views/Components/` (registered via `qmldir`, imported as `import Components`).

### Clock (`views/Components/Clock.qml`)

The wall clock in the top-right corner. A VCR always shows the time, so it is instantiated **once in `Main.qml`**, over the module loader — every screen carries it without a view having to draw it. Minutes, not seconds: a per-second repaint on a Pi buys nothing, though the tick still runs each second so the display turns over *on* the minute. 12- or 24-hour follows `root.twelveHour`.

It hides while something else owns the display — `root.displayOwned`, a guarded mirror of `idleTracker.mpvActive || idleTracker.scriptActive` alongside `hints` and `appVersion`, since binding those context properties directly throws a TypeError when the root context is invalidated. A weather forecast or a takeover script draws its own full screen, clock included.

The clock and a screen's header share the top row, so `root.cornerReserve` (the clock's own width plus a gutter, and any status line beside it — therefore wider for `11:59 PM` than for `23:59`) is what anything at the right end of that row subtracts: `AppBar`'s width, and the IP address in `views/Settings.qml`.

### AppBar (`views/Components/AppBar.qml`)

| Property | Type | Description |
|---|---|---|
| `iconSource` | `url` | Module icon — use `moduleRoot.moduleIcon` |
| `title` | `string` | Module name — use `moduleRoot.moduleName` |
| `subtitle` | `string` | Optional context label (hidden when empty) |

The icon is automatically colorized to the app accent color

### PosterGrid (`views/Components/PosterGrid.qml`)

Cover-art browser: a `GridView` of poster cells with one shared title line beneath it for the selected item (per-cell captions do not fit at 480p). The app's only 2D-navigable view.

| Property | Type | Description |
|---|---|---|
| `model` | `var` | Item array, same model the text `ListView` uses |
| `currentIndex` | `int` | Selected cell |
| `posterSource` | `function(item, w, h)` | Returns the artwork URL, or `""` for none |
| `titleText` | `function(item)` | Row label, also used on the placeholder card |
| `rows` | `int` | Rows of art; the column count falls out of what fits |
| `browseEnabled` | `bool` | Right on the last column emits `browseRequested` instead of wrapping |
| `exitUpEnabled` | `bool` | Up off the top row emits `exitUp` instead of wrapping |

Signals: `activated()`, `browseRequested()`, `backRequested()`, `exitUp()`. Methods: `positionAtCurrent(atBeginning)`, `moveTo(i)`.

Rows are the fixed quantity and columns are whatever fits, so the grid narrows itself when the A–Z panel is up. A cell is exactly one poster plus one gutter in both axes — never `width / columns`, which pours the leftover into the column gap and makes the spacing read wider across than down; the grid instead picks whichever of two column counts wastes less. Wrap rules, since there is no other 2D view to copy: **Left/Right** move within the row and wrap at its ends; **Up/Down** move by a row and wrap top↔bottom into the same column, clamped to the last item.

### PosterShelf (`views/Components/PosterShelf.qml`)

One horizontal row of cover art under a section heading, and the unit `ShelfList` is built from. The heading is the shelf's primary text and the selected item's title is the caption beneath it. Everything sizes off the shelf's own height, so a host sets only width and height.

| Property | Type | Description |
|---|---|---|
| `sectionTitle` | `string` | Heading above the row; empty takes no room |
| `model` / `currentIndex` | `var` / `int` | Item array and selected cell |
| `posterSource` / `titleText` | `function` | Same contract as `PosterGrid` |
| `posterAspect` | `real` | Fallback cell shape when there is no per-item rule |
| `posterAspectFor` | `function(item)` | Per-item cell shape — see below |
| `badgeSource` | `function(item, w, h)` | Corner artwork URL, asked for on landscape cells only |
| `badgeAspect` | `real` | Shape of that corner art (`2/3` cover art unless the host says otherwise) |
| `captionSource` | `function(item)` | `{ top, bottom, corner }`, asked for on landscape cells only |
| `cornerTagSource` | `function(item)` | Bottom-corner identifying label, asked for on **every** cell |
| `logoArt` | `bool` | Cells hold logos, not cover art — see `PosterCell` |
| `showTitleLine` | `bool` | Selected item's title beneath the row; off inside a `ShelfList` |
| `headingMuted` | `bool` | Heading at the caption's size and colour, for a shelf whose cells name the row |
| `highlighted` | `bool` | Whether this shelf holds the selection; set by a host driving it from outside |
| `currentItemData` | `var` | The selected item (read-only) |

Signals: `activated()`, `moveUp()`, `moveDown()`, `backRequested()`, `moved()`. Methods: `positionAtCurrent()`, `moveTo(i)`, `moveLeft()`, `moveRight()`.

Cells share the shelf's height but not its width: with `posterAspectFor` supplied, each cell is cut to the shape of the art it holds, so a 16:9 still and a 2:3 cover both appear whole. Ragged widths are the cost, and the better trade here — a shelf is a handful of items, where `PosterGrid`'s uniform cells earn their crop.

`badgeSource` and `captionSource` are asked only when `aspectFor(item) > 1`: a portrait cell is already cover art, so a cover-art badge would be the same picture twice. The gate lives here rather than in every host because it follows from the cell's shape. `cornerTagSource` is outside it — a number *identifies* the cell rather than describing artwork the cover already shows, so a square cell wants it as much as a wide one.

**Left/Right** move along the shelf and wrap at its ends. **Up/Down** are *not* handled: a shelf never knows what is above or below it, so it reports them and the host decides.

### ShelfList (`views/Components/ShelfList.qml`)

A vertical stack of shelves — the sectioned browse view. Up/Down change shelf, Left/Right move along the focused one, so the whole thing is one 2D surface even though each shelf scrolls independently.

| Property | Type | Description |
|---|---|---|
| `model` | `var` | `[{ title: string, items: array }]`, one shelf per entry |
| `posterSource` / `titleText` | `function` | Same contract as `PosterGrid` |
| `posterAspectFor` / `badgeSource` / `badgeAspect` / `captionSource` | | Forwarded to every shelf |
| `shelfH` | `real` | One shelf's slot; two fit the 480p content box, the rest scroll |
| `wrapVertically` | `bool` | Off when the stack is one section of a larger column — the ends emit `exitUp`/`exitDown` instead of looping |
| `shelfIndex` / `itemIndex` | `int` | The two-part selection, for the host's saved list state (read-only) |

Signals: `activated(var item)` — the item itself, since the host cannot look it up from one index — `backRequested()`, and `exitUp()`/`exitDown()` when `wrapVertically` is off. Methods: `focusEnd(atLast)`, the entry point for a host handing focus back in, and `setPosition(shelfIdx, column)`, which seats the selection before the delegates exist.

Up and Down are **grid-like** — they land on the same column rather than wherever each shelf was left. The wanted `column` is kept separate from any shelf's index, the way a text cursor keeps its wanted column, so passing through a short shelf does not shrink it for every shelf after. It doubles as per-shelf memory: a shelf scrolled out of view is destroyed with its `currentIndex` and reads the column back when recreated.

### PosterCell (`views/Components/PosterCell.qml`)

One cover-art cell — artwork, titled placeholder when there is none, selection ring — shared by `PosterGrid` and `PosterShelf`. The ring is drawn on every cell at the same thickness and only coloured when selected, so nothing shifts as the selection travels. The gutter between neighbours is two rings wide, so adjacent rings meet exactly.

`badgeArt` draws a second, smaller artwork over the bottom-left corner, inset a pixel with a 1px `surfaceColor` hairline so the two images separate. Its width is what a 2:3 cover measures at a third of the cell's height whatever shape `badgeAspect` says it is, so every badge takes the same bite out of the artwork.

`captionTop`, `captionBottom` and `cornerLabel` are the words that go with it, named for where they sit: `captionTop` along the top edge, `captionBottom` along the bottom from wherever the badge leaves off, `cornerLabel` at the far end of that lower line. A line is an eighth of the cell tall, fixed rather than derived from the badge, so lines land at the same height on every cell in a row. Only the bottom line gives up width to `cornerLabel`; all of them are outlined in `surfaceColor`, since they lie over photography of any brightness.

`logoArt` says the cell holds a **mark** rather than cover art — a station logo, drawn on whatever canvas the broadcaster chose. It is fitted whole instead of cropped to fill, and inset an eighth of the cell's height, so the cell reads as a box with a mark in it rather than as a picture that happens to stop at the border (which is what a row of them cropped to fill reads as). The overlays keep the cell's real corners, so `cornerTagLabel` lands in the margin the mark gives up.

Such a cell is also **backed and bordered**, in the placeholder card's `tertiaryColor` hairline: a mark is as often black on transparent as white, and the app's background is black in every theme but one, so a logo left to sit on it can vanish outright. `logoBackdrop` is `Qt.tint(surfaceColor, rgba(.5,.5,.5,.18))` — a neutral veil over whatever the surface is rather than a colour of its own, which lifts a black surface to a dark grey and settles a light one without any theme naming a value. The placeholder takes the same shade, so a channel whose logo never arrived sits at the same weight as the ones beside it.

`cornerTagLabel` is the Plex live lineup's channel number, at the foot of the cell in the same corner `cornerLabel`'s runtime reads from — the two never appear together, and `captionBottom` yields width to whichever is showing. It is its own property rather than the end of a caption line because the cells that want it are small squares with no room for a caption beside it; its line is floored at `root.sh * 0.025` (an eighth of a 50px square is a 6px digit, and a number that cannot be read is not worth the corner) and it is held `root.sh * 0.0104167` off its edges rather than the captions' single pixel, since it sits inside a bordered card whose rule it would otherwise touch.

On the placeholder card a title past twice as tall as it is wide takes a quarter turn and is read up the card — a **spine**. Turning rather than stacking is what makes a long name fit: stacked, a word costs its length in height.

### MarqueeText (`views/Components/MarqueeText.qml`)

A single line that scrolls itself when it exceeds `maxWidth` (1500 ms pause → scroll → 2000 ms pause → reset). The idiom is hand-copied in every text list row; this is the shared copy the poster views use. Sizes its own width to the text so a highlight anchored to it hugs the glyphs.

### NfcCardWriter (`views/Components/NfcCardWriter.qml`)

Full-screen takeover that writes an NFC card for the item a detail view is showing. Shared so every module reachable from a card writes them the same way; the host supplies only what goes on the card.

| Property | Type | Description |
|---|---|---|
| `cardRef` | `string` | Line 2 of the tag file — e.g. a Plex guid |
| `cardTitle` | `string` | Filename **and** display title |
| `offerShuffle` | `bool` | Show the shuffle option — only meaningful for a show or season |
| `available` | `bool` | Read-only. True when the NFC module is enabled and a reader is connected — bind the host's entry-point row's `visible` to this |

Call `open()` to show it; it emits `closed()` when done. Two things worth preserving if you touch it:

- **Capture is armed only while it is open**, so a card resting near the reader while the user browses can never trigger a write. Arming is always a deliberate action, never a passive listen. The backend handles capture *ahead of* its module-active gate, because arming happens from another module's screen.
- **Choices carry a stable `action` field; behaviour never keys off the label text.** An earlier version matched `indexOf("shuffle")` on the label and silently broke the moment the wording changed.

Writing also offers an option to the user to replace any previous tag file for that UID, that way a card can be written easily from with the UI.

- **Two cards never share a filename.** `writeCardFile` suffixes the name (`Dune (2021) (2).txt`) when the target name already belongs to a different UID. Hosts should still qualify `cardTitle` so the suffix stays rare.  For example Plex names cards with the year of the item like: `Dune (2021)`, `Cowboy Bebop (1998) - S1`, `Cowboy Bebop (1998) - S1E5`.
- **The host's title is passed through verbatim.**  To keep the NFC writing generalized for other callers its built to just pass the name through cleanly and the NFC card writing portion doesn't reason about it. I had a use case in my Plex library where an item already carried the year in its title (e.g. Cowboy Bebop (2021)) so for that case the name written is `Cowboy Bebop (2021) (2021).txt`. This is deliberate because inferring if trailing `(NNNN)` is a year or something else would guess at a user's own metadata (think of the the use case for Cyberpunk 2077). The cost of guessing wrong I think outweighs a cosmetic repeat and users can always choose rename the tag file manually as well without any impact to the mapping.

## Config Storage

User configuration is stored in `config.json` in the app's data directory:

```json
{
  "app": { "color_scheme": "Video 1" },
  "modules": {
    "com.240mp.plex": { "enabled": true, "server_machine_id": "...", ... }
  }
}
```

Each module's settings live under `modules.<id>`. Use `save_setting` / `get_setting` (which support dot-notation keys) rather than writing the file directly. The data directory is created on first run and is separate from the app itself, so rebuilding never wipes user settings. For the exact per-OS path (macOS vs Raspberry Pi OS), see [BUILDING.md](BUILDING.md#configuration).
