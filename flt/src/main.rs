use clap::{Parser, ValueEnum};

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    assets_dir: String,

    #[arg(long)]
    icu_data_path: String,

    /// For use when debugging, to disable advanced terminal features so the
    /// console output is not mangled.
    #[arg(long)]
    simple_output: bool,

    /// When enabled, the semantics tree will be dumped to
    /// `/tmp/flt-semantics.txt` whenever it is updated.
    #[arg(long)]
    debug_semantics: bool,

    /// When the alternate screen is used (default), the Flutter app will be
    /// drawn to a separate buffer, and the currrent terminal buffer will be
    /// restored when this process exits.
    ///
    /// Disabling the alternate screen is helpful for debugging, since
    /// everything from the process will be logged to this alternate buffer
    /// which will be lost.
    #[arg(long)]
    no_alt_screen: bool,

    /// When enabled, logs terminal events.
    ///
    /// Useful for debugging platform-specific / terminal emulator-specific
    /// issues.
    #[arg(long)]
    log_terminal_events: bool,

    /// Disables the kitty graphics protocol even if supported.
    #[arg(long)]
    no_kitty: bool,

    /// Disables GPU rendering (Metal) and forces software rendering.
    #[arg(long)]
    no_gpu: bool,

    /// Log to a file in addition to the terminal.
    #[arg(long)]
    log_file: Option<String>,

    /// Target frame rate hint sent to the Flutter engine (default: 60).
    #[arg(long)]
    fps: Option<usize>,

    /// Override device pixel ratio. Higher values make Flutter render at a
    /// finer DPI so text appears sharper (and smaller). Defaults to 0.3 in
    /// ANSI mode; ignored when Kitty graphics are active unless explicitly set.
    #[arg(long)]
    pixel_ratio: Option<f64>,

    /// Suppress all log output. The 4-line log window is hidden and engine
    /// messages are silenced. Combine with --log-file to still capture logs.
    #[arg(long)]
    quiet: bool,

    /// Character rendering mode for ANSI (non-Kitty) output.
    ///
    /// block  — ▀ half-block, 1×2 pixels per cell (default).
    /// braille — Unicode braille patterns, 2×4 pixels per cell (sharper).
    /// ascii   — ASCII density chars, 1×1 pixel per cell.
    #[arg(long, value_enum, default_value_t = CharRenderArg::Block)]
    char_render: CharRenderArg,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum CharRenderArg {
    Block,
    Braille,
    Ascii,
}

impl From<CharRenderArg> for flt::CharRender {
    fn from(arg: CharRenderArg) -> Self {
        match arg {
            CharRenderArg::Block => flt::CharRender::Block,
            CharRenderArg::Braille => flt::CharRender::Braille,
            CharRenderArg::Ascii => flt::CharRender::Ascii,
        }
    }
}

fn main() -> Result<(), flt::Error> {
    let args = Args::parse();

    let mut embedder = flt::TerminalEmbedder::new(
        &args.assets_dir,
        &args.icu_data_path,
        args.simple_output,
        !args.no_alt_screen,
        args.log_terminal_events,
        args.debug_semantics,
        args.no_kitty,
        args.no_gpu,
        args.log_file,
        args.fps,
        args.pixel_ratio,
        args.char_render.into(),
        args.quiet,
    )?;

    embedder.run_event_loop()?;

    Ok(())
}
