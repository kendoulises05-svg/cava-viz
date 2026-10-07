# Cava Viz

**English** | [Español](README.es.md)

An audio visualizer widget for the KDE Plasma 6 desktop. It draws thin, reactive bars directly on the wallpaper (no window, no background) and adapts its colors to the current wallpaper. It also includes its own wallpaper rotation so the colors always match the image on screen.

![Cava Viz on the desktop](docs/screenshot.png)

| Configuration panel | Another wallpaper |
|---|---|
| ![Configuration panel](docs/Screenshot_config.png) | ![Another wallpaper](docs/Screenshot_test_1.png) |

## Features

**Wave**
- Bar count adjusts automatically to the widget width; you only choose bar width and gap in pixels.
- Three orientations: from the bottom, mirror (with an adjustable reflection line) and floating (centered).
- Stereo or mono, with normal or inverted frequency layout.
- Peak caps, hide on silence and smooth color transitions.
- Glow that pulses with the bass, using the bar color or an automatic contrasting color.

**Color modes**

| Mode | What it does |
|---|---|
| Accent + 2nd color | Bass uses the Plasma accent color; treble uses a vivid color taken from the wallpaper |
| By wallpaper zone | Each bar takes the color of the wallpaper area it sits under. Optional color swap between zones |
| Contrast | Same hue as the background behind the widget, with inverted brightness |
| Automatic (experimental) | Zone color, darkened or lightened only as needed to reach a WCAG contrast ratio of 3:1 against the background |

**Wallpaper**
- Rotation from a folder: random, alphabetical or newest first, with an interval in hours, minutes and seconds.
- "Next wallpaper" from the widget right-click menu or a keyboard shortcut.
- Reuses the folder and excluded images from the Plasma slideshow settings.

**Resource usage**
- Pauses cava and hides the widget when a window covers it (configurable: never, fullscreen only, fullscreen or maximized, or any window covering the widget, tiling included) or the screen is locked.
- Can be turned off and on by hand from the right-click menu or a shortcut (`/toggle`); the state survives restarts.
- Pauses while cava runs in a terminal (for example Konsole), so only that one shows; optional.
- cava in Konsole with the wallpaper colors: `cava -p ~/.config/cava/terminal.conf` (`install.sh` copies `terminal.conf`; the bridge updates its colors when it starts and when the wallpaper changes).
- Color calculations are cached and only recomputed when the wallpaper, mode or widget position changes.

## Requirements

- KDE Plasma 6 (developed and tested on Kubuntu 26.04 with Plasma 6.6.6, Wayland)
- PipeWire or PulseAudio
- `cava`, `python3-pil` (Pillow) and `curl`. The installer adds the missing ones with `apt`.
- `plasma-apply-wallpaperimage` and `qdbus6` (included with Plasma)

## Installation

```bash
git clone https://github.com/kendoulises05-svg/cava-viz.git
cd cava-viz
./install.sh
```

The script installs missing dependencies, copies the cava config (it never overwrites an existing one), creates and starts the `cava-bridge` user service, and installs or updates the widget. It asks before reloading the desktop.

First time only: right-click the desktop > **Add Widgets** > **Cava Viz**, and resize it to the area you want.

Run `./install.sh` again after any update. To remove everything:

```bash
./install.sh --uninstall
```

This removes the service and the widget; your cava config and wallpapers are not touched.

## Configuration

Right-click the widget > **Configure Cava Viz**:

| Page | Options |
|---|---|
| Wave | Bar width and gap, orientation, mirror line, audio channels and layout, glow, fps, pause when, pause with cava in a terminal, peaks, hide on silence |
| Color | Color mode, accent blend, color swap between zones |
| Wallpaper | Enable rotation, folder, order, interval, next wallpaper button |
| Keyboard Shortcuts | Shortcut for "next wallpaper" |

The zone, contrast and automatic modes need Cava Viz to control the wallpaper. If Plasma's own slideshow is active, the widget falls back to the accent color (see [Known limitations](#known-limitations)).

## How it works

```mermaid
flowchart LR
    A[PipeWire / PulseAudio] --> B[cava<br/>raw output]
    B --> C[cava_bridge.py<br/>HTTP on 127.0.0.1:8765]
    C --> D[Plasma widget<br/>QML]
    C -->|plasma-apply-wallpaperimage<br/>or D-Bus| E[Plasma wallpaper]
    E -->|image file| C
```

Plasma widgets cannot read a continuous process output, so a small Python bridge runs cava, keeps the latest frame and serves it over HTTP, bound only to `127.0.0.1`. The same bridge rotates the wallpaper, reads the image with Pillow and computes the colors for each mode.

| File | Purpose |
|---|---|
| `cava_bridge.py` | Bridge: cava process, HTTP server, wallpaper rotation, color modes, pause handling |
| `org.kendo.cavaviz/` | The Plasma widget (QML) and its configuration pages |
| `raw.conf` | Base cava config; the bridge only changes `bars` and `channels` in a runtime copy |
| `install.sh` | Installer and uninstaller |

Bridge endpoints, useful for scripting:

| Endpoint | Purpose |
|---|---|
| `/` | Latest cava frame (`P` while paused, `D` when turned off by hand) |
| `/next` | Next wallpaper |
| `/disable`, `/enable`, `/toggle` | Turn the visualizer off, on, or toggle it (survives restarts) |
| `/state` | `off` if turned off by hand, `on` otherwise |
| `/terminal?pause=1\|0` | Pause or not while another cava runs (sent by the widget) |
| `/pause`, `/resume` | Pause or resume cava (used by the widget when a window covers it) |
| `/bars?n=&ch=` | Bar count and `stereo` / `mono` |
| `/palette`, `/zones`, `/contrast`, `/auto` | Wallpaper colors (JSON) |
| `/rotation?enabled=&dir=&seconds=&order=` | Rotation settings |

To bind them to keyboard shortcuts: System Settings > Keyboard > Shortcuts > Add New > Command or Script, with one of these commands:

```bash
curl -s http://127.0.0.1:8765/toggle   # turn the visualizer off / on
curl -s http://127.0.0.1:8765/next     # next wallpaper
```

## Performance

Measured on 2026-10-07 with [`tools/bench.sh`](tools/bench.sh): real 10 s average per scenario, with music playing. HP laptop, Kubuntu 26.04, Plasma 6.6.6 (Wayland). Settings: 194 bars, 45 fps, glow on, mirror, automatic color.

| Scenario | plasmashell | cava | bridge | Total |
|---|---|---|---|---|
| Widget visible (active) | 28.7% | 1.9% | 3.3% | 33.9% |
| Fullscreen | 8.5% | 0.0% | 0.0% | 8.5% |
| Turned off by hand | 8.5% | 0.0% | 0.0% | 8.5% |
| Partial tiling with "Pause when: fullscreen or maximized" (no pause) | 32.9% | 1.9% | 3.4% | 38.2% |

How to read it:

- **plasmashell also draws the panel and the other widgets.** With Cava Viz off it measured 9.4%, so that ~9% is not Cava Viz. Cava Viz itself uses ~20% when active and ~0% when paused.
- **When paused, cava is frozen** (state `T`) and cava and the bridge drop to 0%.
- **Tiling:** with "Fullscreen or maximized", tiling does not count and the widget keeps drawing behind it. With "A window covers the widget" (the default) it pauses too.

Compared with the previous measurement (single `top` sample, plasmashell only: glow at 60 fps ~31%, glow at 30 fps ~16%, no glow at 30 fps ~13%, paused ~0%):

- **Active:** ~20% of its own at 45 fps with glow and mirror, between the previous 30 and 60 fps values. As expected: pausing on covered windows and the manual off switch added no measurable cost.
- **Improvement:** before, a maximized or tiled window paused nothing (~34% total kept running). Now Cava Viz drops to ~0% in those cases.
- Not a 1:1 comparison: the old numbers came from `top` (one sample) with other settings. From now on, `tools/bench.sh` repeats the same measurement before and after each change.

### Measure it yourself

```bash
cd ~/cava-viz && tools/bench.sh
```

The script walks you through each scenario: active, fullscreen, a window covering the widget, cava in Konsole and turned off (the last one runs on its own). Other ways to use it:

```bash
tools/bench.sh --now "glow 30 fps"     # measure only what is on screen now, no prompts
SECS=20 tools/bench.sh                 # 20 s measurements instead of 10
```

Results are saved in `~/.local/state/cava-viz/bench/`. To compare a change: measure, apply the change, measure again and compare the **total** column and the **Turned off by hand** row.

## Troubleshooting

| Problem | Check |
|---|---|
| Widget does not show bars | `curl -s http://127.0.0.1:8765/` should return numbers. If not: `journalctl --user -u cava-bridge -n 20 --no-pager` |
| Widget shows a QML error | `journalctl --user -u plasma-plasmashell -n 30 --no-pager \| grep -iE "cavaviz\|qml"` |
| All bars at 0 | cava is listening to the wrong source. List sources with `pactl list short sources` and set the `.monitor` one in `~/.config/cava/raw.conf` (`source = ...`), then `systemctl --user restart cava-bridge` |
| Wallpaper does not change | The bridge log shows the exact reason from Plasma |
| Desktop fails to restart ("start request repeated too quickly") | `systemctl --user reset-failed plasma-plasmashell` and `systemctl --user start plasma-plasmashell` |

Reload only what changed:

| Changed | Command |
|---|---|
| `cava_bridge.py` or `raw.conf` | `systemctl --user restart cava-bridge` |
| Widget files | `./install.sh` |

## Known limitations

- **Plasma slideshow:** Plasma does not expose which image its slideshow is showing (neither in its config file nor over D-Bus), so the wallpaper-based color modes need Cava Viz's own rotation.
- **Busy wallpapers:** with many small color areas, the zone mode averages them and may pick colors that do not look right.
- **Automatic mode** is experimental. On very detailed backgrounds it may push colors close to black or white to reach the contrast target.
- **Single screen:** tested with one monitor only.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## Author

Kendo ([kendoulises05-svg](https://github.com/kendoulises05-svg))
