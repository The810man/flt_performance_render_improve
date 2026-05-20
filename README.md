# flt (fork)

> **Fork of [jiahaog/flt](https://github.com/jiahaog/flt)** — a Flutter Terminal Embedder implementing the Flutter Engine's [Custom Embedder API](https://docs.flutter.dev/embedded).
> This fork adds CLI rendering controls, a quiet mode, performance improvements, and a purpose-built sample application.

## Changes in this fork

### CLI flags

New arguments for the `flt` binary:

| Flag | Default | Description |
|---|---|---|
| `--pixel-ratio <f64>` | `0.3` | Device pixel ratio sent to Flutter. Higher = sharper/smaller UI. |
| `--fps <usize>` | `60` | Target frame rate hint sent to the Flutter engine. |
| `--char-render <mode>` | `block` | ANSI character rendering mode: `block`, `braille`, or `ascii`. |
| `--quiet` | off | Suppress all stdout/stderr output from the Flutter app. |

Example — braille mode at higher DPI:
```sh
cargo run -- sample_app --pixel-ratio 0.5 --fps 60 --char-render braille
```

### Character rendering modes

- **block** (default) — `▀` half-block characters, 1×2 pixels per cell
- **braille** — Unicode braille patterns `⠿`, 2×4 pixels per cell — sharper detail in the same terminal space
- **ascii** — density characters (`` .:-=+*%#@ ``), 1×1 pixel per cell

### Terminal I/O isolation

All rendering now goes through `/dev/tty` directly instead of fd 1. This means:

- Flutter app `print()` / `stderr.write()` no longer corrupts the rendered display
- `--quiet` redirects fd 1 and fd 2 to `/dev/null` at the OS level
- Terminal size is read via `ioctl(TIOCGWINSZ)` on the tty fd, so it works correctly even when fd 1 is redirected

### Performance

- **Double-buffered cell grid** — flat `Vec<TerminalCell>` swapped each frame; zero per-frame heap allocations in steady state
- **Diff rendering** — only changed cells emit ANSI sequences; unchanged cells are skipped entirely
- **Cursor/color state tracking** — consecutive cells skip redundant `MoveTo` and color escape sequences
- **Allocation-free ANSI output** — escape sequences written directly into a pre-allocated `Vec<u8>` using integer-to-bytes helpers instead of `format!`
- **Braille fill without heap allocs** — running accumulators replace intermediate `Vec<Color>` per cell

### Sample application (`sample_app/`)

The original counter demo has been replaced with a **terminal plant surveillance dashboard** for cannabis research environments. Keyboard-only navigation (no mouse required).

**Tab 1 — System monitor** (btop-style)
- Per-core CPU bars with aggregate + temperature (color-coded at 70°C / 85°C)
- RAM and swap usage with GB display
- Network interfaces with rx/tx MB/s
- MQTT broker status: connection state, uptime, message count, rate

**Tab 2 — Grow monitor**
- Multi-zone selector (← → to switch zones)
- Sensor rows with range bars showing value relative to cannabis-optimal ranges: temperature, humidity, CO2, PPFD, VPD, pH, EC
- Reservoir panel: pH, EC, water temperature
- Environment panel: lights on/off, grow stage, day count
- ↑ ↓ to select sensor rows

**Navigation**: `Tab` or `1`/`2` to switch tabs, arrow keys within tabs.

**MQTT**: connects to `127.0.0.1:1883` by default, subscribes to `grow/+/<metric>` topics. Auto-reconnects on disconnect.

---

## Original project

Everything below is from the upstream README.

---

`flt` is a **Fl**utter **T**erminal Embedder, implementing the Flutter Engine's [Custom Embedder API](https://docs.flutter.dev/embedded).

With a terminal emulator that [supports](https://sw.kovidgoyal.net/kitty/graphics-protocol/) Kitty graphics, 60fps rendering can be achieved.

https://github.com/user-attachments/assets/2e912395-204a-4a81-9aae-649e7f02b090

Otherwise, it falls back to using [ANSI Escape Codes](https://en.wikipedia.org/wiki/ANSI_escape_code).

https://github.com/user-attachments/assets/b6e58c93-4f30-43e4-b0e5-07e50947da9c

This works over SSH though it may be slow depending on the network.

## Supported Platforms / Terminals

Kitty rendering was mostly developed on macOS. Tested on iTerm2 and Ghostty.

ANSI rendering should work on more terminals.

## Checkout

This project uses submodules, so pass the `--recurse-submodules` flag.

```sh
git clone --recurse-submodules git@github.com:jiahaog/flt.git
```

## Usage

Install [Rust](https://www.rust-lang.org/tools/install) first, then at the root of the monorepo, the following command will build the [Sample Flutter App](./sample_app/), and run it with the terminal embedder.

```sh
cargo run
```

### Other Flutter Projects

```sh
cargo run -- <path to the root of your flutter project>
```

### Usage with `flutter run` (Custom Device)

The terminal embedder can be registered as a [Custom Device](https://github.com/flutter/flutter/blob/master/docs/tool/Using-custom-embedders-with-the-Flutter-CLI.md#the-custom-devices-config-file) to use it directly with the `flutter` tool (supporting hot reload, hot restart etc.).

1.  Enable Custom Devices:

    ```sh
    flutter config --enable-custom-devices
    ```

2.  Build the Embedder:

    ```sh
    cargo build --release
    ```

3.  Install Custom Device:

    Run the installation script to configure the custom device and launcher:
    ```sh
    ./install_custom_device.sh
    ```

4.  Run:
    ```sh
    flutter run -d terminal
    ```

### More CLI help for development

```sh
# See help for `flt-cli`.
cargo run -- --help

# See help for `flt`.
cargo run -- --args=--help
```

## Project Structure

- [`flt`](./flt) - The terminal embedder.
- [`flt-cli`](./flt-cli/) - A small CLI utility to make local development easier. By default, the `cargo run` command at the root of the repository will run this.
- [`flutter-sys`](./flutter-sys/) - Safe Rust bindings to the Flutter Embedder API.
- [`sample_app`](./sample_app/) - A sample Flutter Project used for local development.
- [`third_party/flutter`](./third_party/flutter/) - A submodule checkout of the [Flutter Framework](https://github.com/flutter/flutter).

## References

- [Forking Chrome to render in a terminal](https://fathy.fr/carbonyl)
- [brow.sh](https://www.brow.sh/)
