//! This should be the only file in this crate which depends on [crossterm]
//! functionality beyond the data classes.

use crate::event::PlatformEvent;
use base64::prelude::*;
use crossterm::cursor::{Hide, MoveTo, Show};
use crossterm::event::{read, DisableMouseCapture, EnableMouseCapture, Event};
use crossterm::style::{Color, Print};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::{ExecutableCommand, QueueableCommand};
use libc::{ftruncate, shm_open, shm_unlink, O_CREAT, O_RDWR, O_TRUNC};
use memmap2::MmapMut;
use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::sync::mpsc::Sender;
use std::thread;
use std::time::Instant;

/// Lines to reserve the terminal for logging.
const LOGGING_WINDOW_HEIGHT: usize = 4;

/// How the pixel buffer is mapped to terminal characters in ANSI (non-Kitty) mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CharRender {
    /// Two pixel rows per cell using the upper-half-block character (▀). Default.
    Block,
    /// Eight pixels per cell using Unicode braille patterns (2 cols × 4 rows).
    /// Gives 4× vertical and 2× horizontal resolution over Block.
    Braille,
    /// One pixel per cell using ASCII density characters.
    Ascii,
}

pub struct TerminalWindow {
    // Wraps /dev/tty opened directly, isolated from fd 1 so that Flutter app
    // output (print/stderr) cannot corrupt the terminal rendering.
    stdout: BufWriter<File>,

    // Double-buffered flat cell grids (row-major, stride = cell_cols).
    // Reused between frames to eliminate per-frame Vec allocations.
    cell_curr: Vec<TerminalCell>,
    cell_prev: Vec<TerminalCell>,
    cell_cols: usize,
    cell_rows: usize,
    // Force a full repaint on the next draw call (e.g. after resize / scroll).
    dirty: bool,

    // Pre-allocated output byte buffer reused across frames to avoid
    // re-allocating the ANSI escape sequence string every frame.
    render_buf: Vec<u8>,

    logs: VecDeque<String>,
    log_file_writer: Option<File>,
    semantics: HashMap<(usize, usize), String>,

    simple_output: bool,
    alternate_screen: bool,
    showing_help: bool,
    pub(crate) log_events: bool,
    kitty_mode: bool,
    pixels_per_col: f64,
    pixels_per_row: f64,
    device_pixel_ratio: f64,
    char_render: CharRender,
    /// Number of lines reserved at the bottom for the log window. 0 = quiet mode.
    log_height: usize,
    shm_buffer: Option<SharedMemoryBuffer>,
    frame_count: u64,
    logs_dirty: bool,
}

struct SharedMemoryBuffer {
    name: String,
    #[allow(dead_code)]
    file: File,
    map: Option<MmapMut>,
}

impl SharedMemoryBuffer {
    fn new(size: usize, suffix: u64) -> std::io::Result<Self> {
        let pid = std::process::id();
        let name = format!("/flt_{}_{}", pid, suffix);
        let c_name = std::ffi::CString::new(name.clone())?;

        unsafe { shm_unlink(c_name.as_ptr()) };

        let fd = unsafe { shm_open(c_name.as_ptr(), O_RDWR | O_CREAT | O_TRUNC, 0o600) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }

        let file = unsafe { File::from_raw_fd(fd) };

        if unsafe { ftruncate(fd, size as i64) } < 0 {
            return Err(std::io::Error::last_os_error());
        }

        let map = unsafe { MmapMut::map_mut(&file)? };

        Ok(Self { name, file, map: Some(map) })
    }
}

impl Drop for SharedMemoryBuffer {
    fn drop(&mut self) {
        if let Ok(c_name) = std::ffi::CString::new(self.name.clone()) {
            unsafe { shm_unlink(c_name.as_ptr()) };
        }
    }
}

impl Drop for TerminalWindow {
    fn drop(&mut self) {
        if !self.simple_output {
            if self.kitty_mode {
                let _ = self.stdout.execute(Print("\x1b_Ga=d,d=a\x1b\\"));
            }
            self.stdout.execute(DisableMouseCapture).unwrap();
            disable_raw_mode().unwrap();
            self.stdout.execute(Show).unwrap();
            if self.alternate_screen {
                self.stdout.execute(LeaveAlternateScreen).unwrap();
            }
            self.stdout.execute(Print("\n")).unwrap();
        }
    }
}

impl TerminalWindow {
    pub(crate) fn new(
        simple_output: bool,
        alternate_screen: bool,
        log_events: bool,
        disable_kitty: bool,
        event_sender: Sender<PlatformEvent>,
        log_file: Option<String>,
        char_render: CharRender,
        pixel_ratio_override: Option<f64>,
        quiet: bool,
    ) -> Self {
        // Open /dev/tty directly as our terminal output channel, independent of
        // fd 1 and fd 2 so Flutter/Dart app output to those fds cannot corrupt
        // the display.
        let tty_fd: RawFd = unsafe {
            let fd = libc::open(
                b"/dev/tty\0".as_ptr() as *const libc::c_char,
                libc::O_RDWR,
            );
            if fd >= 0 { fd } else { libc::dup(1) }
        };

        // Redirect fd 1 / fd 2 to /dev/null when in terminal-rendering mode so
        // that stray print() / stderr calls from the Flutter app do not write raw
        // text into the terminal and corrupt the crossterm display.
        // We only redirect if the fd currently points to a tty; shell-level
        // redirections (2>file) are respected.
        if !simple_output {
            unsafe {
                let null = libc::open(b"/dev/null\0".as_ptr() as *const _, libc::O_WRONLY);
                if null >= 0 {
                    if libc::isatty(1) == 1 {
                        libc::dup2(null, 1);
                    }
                    if libc::isatty(2) == 1 {
                        libc::dup2(null, 2);
                    }
                    libc::close(null);
                }
            }
        }

        let tty_file = unsafe { File::from_raw_fd(tty_fd) };
        let mut stdout = BufWriter::new(tty_file);

        if !simple_output {
            if alternate_screen {
                stdout.execute(EnterAlternateScreen).unwrap();
            }
            stdout.execute(Hide).unwrap();
            enable_raw_mode().unwrap();
            stdout.execute(EnableMouseCapture).unwrap();
        }

        let kitty_mode = if !simple_output && !disable_kitty {
            crate::feature::kitty_graphics_supported(&mut stdout)
        } else {
            false
        };

        let fd = stdout.get_ref().as_raw_fd();

        let (pixels_per_col, pixels_per_row) = if kitty_mode {
            match tty_ioctl_size(fd) {
                Some((cols, rows, w_px, h_px)) if w_px > 0 && h_px > 0 && rows > 0 && cols > 0 => {
                    (w_px as f64 / cols as f64, h_px as f64 / rows as f64)
                }
                _ => (10.0, 20.0),
            }
        } else {
            match char_render {
                CharRender::Block => (1.0, 2.0),
                CharRender::Braille => (2.0, 4.0),
                CharRender::Ascii => (1.0, 1.0),
            }
        };

        let device_pixel_ratio = pixel_ratio_override.unwrap_or_else(|| {
            if kitty_mode {
                pixels_per_row.max(1.0) / 22.0
            } else {
                crate::constants::DEFAULT_PIXEL_RATIO
            }
        });

        let log_height = if quiet { 0 } else { LOGGING_WINDOW_HEIGHT };

        thread::spawn(move || {
            let mut should_run = true;
            while should_run {
                let event = read().unwrap();
                let event = normalize_event_height(event, pixels_per_col, pixels_per_row, log_height);
                should_run = event_sender
                    .send(PlatformEvent::TerminalEvent(event))
                    .is_ok();
            }
        });

        let log_file_writer =
            log_file.and_then(|path| OpenOptions::new().create(true).append(true).open(path).ok());

        Self {
            stdout,
            cell_curr: Vec::new(),
            cell_prev: Vec::new(),
            cell_cols: 0,
            cell_rows: 0,
            dirty: true,
            render_buf: Vec::with_capacity(64 * 1024),
            logs: VecDeque::new(),
            log_file_writer,
            semantics: HashMap::new(),
            simple_output,
            showing_help: false,
            alternate_screen,
            log_events,
            kitty_mode,
            pixels_per_col,
            pixels_per_row,
            device_pixel_ratio,
            char_render,
            log_height,
            shm_buffer: None,
            frame_count: 0,
            logs_dirty: true,
        }
    }

    pub(crate) fn device_pixel_ratio(&self) -> f64 {
        self.device_pixel_ratio
    }

    pub(crate) fn size(&self) -> (usize, usize) {
        let fd = self.stdout.get_ref().as_raw_fd();

        if self.kitty_mode {
            if let Some((_, rows, w_px, h_px)) = tty_ioctl_size(fd) {
                let rows = rows as usize;
                let h_px = h_px as usize;
                let w_px = w_px as usize;

                if w_px > 0 && h_px > 0 && rows > 0 {
                    let height_rows = rows.saturating_sub(self.log_height);
                    let cell_height = h_px / rows;
                    let height_px = cell_height * height_rows;
                    return (w_px, height_px);
                }
            }
        }

        let (width, height) = tty_ioctl_chars(fd);
        let height = (height as usize).saturating_sub(self.log_height);

        (
            (width as f64 * self.pixels_per_col).round() as usize,
            (height as f64 * self.pixels_per_row).round() as usize,
        )
    }

    pub(crate) fn update_semantics(&mut self, label_positions: Vec<((usize, usize), String)>) {
        self.semantics = label_positions.into_iter().collect();
    }

    pub(crate) fn draw(
        &mut self,
        buffer: Vec<u8>,
        width: usize,
        height: usize,
        (x_offset, y_offset): (isize, isize),
    ) -> Result<(), std::io::Error> {
        if self.simple_output {
            return Ok(());
        }
        if self.showing_help {
            return Ok(());
        }

        let fd = self.stdout.get_ref().as_raw_fd();
        let (term_cols, term_rows) = tty_ioctl_chars(fd);
        let start_instant = Instant::now();

        if self.kitty_mode {
            self.draw_kitty(buffer, width, height)?;
        } else {
            let cell_cols = term_cols as usize;
            let cell_rows = (term_rows as usize).saturating_sub(self.log_height);
            let total = cell_cols * cell_rows;

            // Resize cell buffers if the terminal dimensions changed, and force
            // a full repaint so no stale cells remain visible.
            if cell_cols != self.cell_cols || cell_rows != self.cell_rows {
                self.cell_curr.resize(total, TerminalCell::DIRTY);
                self.cell_prev.resize(total, TerminalCell::DIRTY);
                self.cell_cols = cell_cols;
                self.cell_rows = cell_rows;
                self.dirty = true;
            }

            // Fill cell_curr from the pixel buffer (no allocation — writes in place).
            match self.char_render {
                CharRender::Block => fill_block(
                    &mut self.cell_curr, &buffer, width, height,
                    x_offset, y_offset, cell_cols, cell_rows,
                ),
                CharRender::Braille => fill_braille(
                    &mut self.cell_curr, &buffer, width, height,
                    x_offset, y_offset, cell_cols, cell_rows,
                ),
                CharRender::Ascii => fill_ascii(
                    &mut self.cell_curr, &buffer, width, height,
                    x_offset, y_offset, cell_cols, cell_rows,
                ),
            }

            // Build ANSI output: diff curr vs prev, track cursor position and
            // current fg/bg so redundant escape sequences are suppressed.
            let render_buf = &mut self.render_buf;
            render_buf.clear();

            // Sentinel values that cannot appear as real cursor/color state.
            let mut cur_col: isize = -2;
            let mut cur_row: isize = -2;
            let mut cur_fg = TerminalCell::DIRTY.fg;
            let mut cur_bg = TerminalCell::DIRTY.bg;

            for y in 0..cell_rows {
                for x in 0..cell_cols {
                    let idx = y * cell_cols + x;
                    let cell = &self.cell_curr[idx];

                    // Skip unchanged cells unless a full repaint was requested.
                    if !self.dirty && self.cell_prev.get(idx) == Some(cell) {
                        cur_col = -2; // cursor no longer at a known position
                        continue;
                    }

                    // MoveTo — omit when cursor is already at the right column.
                    if cur_row != y as isize || cur_col != x as isize {
                        write_move_to(render_buf, x + 1, y + 1);
                        cur_row = y as isize;
                    }

                    // fg color — emit only when it changes.
                    if cur_fg != cell.fg {
                        if let Color::Rgb { r, g, b } = cell.fg {
                            write_fg(render_buf, r, g, b);
                        }
                        cur_fg = cell.fg;
                    }

                    // bg color — emit only when it changes.
                    if cur_bg != cell.bg {
                        if let Color::Rgb { r, g, b } = cell.bg {
                            write_bg(render_buf, r, g, b);
                        }
                        cur_bg = cell.bg;
                    }

                    // Character (UTF-8 encoded directly into the buffer).
                    let mut tmp = [0u8; 4];
                    render_buf.extend_from_slice(cell.ch.encode_utf8(&mut tmp).as_bytes());

                    // Cursor has advanced one column after this write.
                    cur_col = x as isize + 1;
                }
            }

            self.stdout.write_all(render_buf)?;
            self.dirty = false;

            // Swap cell buffers so curr becomes prev for the next frame.
            std::mem::swap(&mut self.cell_curr, &mut self.cell_prev);
        }

        // Log window (bottom log_height rows).
        if self.log_height > 0 && term_rows as usize >= self.log_height {
            let cols = term_cols as usize;
            let rows = term_rows as usize;

            for i in 0..self.log_height {
                let is_last_line = i == self.log_height - 1;
                if !self.logs_dirty && !is_last_line {
                    continue;
                }

                let y = rows - self.log_height + i;
                self.stdout.queue(MoveTo(0, y as u16))?;
                self.stdout.queue(Clear(ClearType::CurrentLine))?;

                if let Some(line) = self.logs.get(i) {
                    self.stdout.queue(Print(line))?;
                }

                if is_last_line {
                    let draw_duration = Instant::now().duration_since(start_instant);
                    let hint_and_fps = format!("{HELP_HINT} [{}ms]", draw_duration.as_millis());
                    self.stdout.queue(MoveTo(
                        (cols.saturating_sub(hint_and_fps.len())) as u16,
                        y as u16,
                    ))?;
                    self.stdout.queue(Print(hint_and_fps))?;
                }
            }
        }
        self.logs_dirty = false;

        self.stdout.flush()?;
        Ok(())
    }

    fn draw_kitty(
        &mut self,
        buffer: Vec<u8>,
        width: usize,
        height: usize,
    ) -> Result<(), std::io::Error> {
        if buffer.is_empty() {
            return Ok(());
        }

        self.frame_count += 1;
        let needed_size = buffer.len();

        let mut new_shm = SharedMemoryBuffer::new(needed_size, self.frame_count)?;

        if let Some(map) = &mut new_shm.map {
            map[0..needed_size].copy_from_slice(&buffer);
            let _ = map.flush();
        }

        self.stdout.queue(MoveTo(0, 0))?;

        let code = format!(
            "\x1b_Gf=32,s={},v={},a=T,q=2,i=1,p=1,z=1,C=1,t=s;{}\x1b\\",
            width,
            height,
            BASE64_STANDARD.encode(&new_shm.name)
        );
        self.stdout.queue(Print(code))?;
        self.stdout.flush()?;

        self.shm_buffer = Some(new_shm);
        Ok(())
    }

    pub(crate) fn log(&mut self, message: String) {
        if self.log_height == 0 {
            if let Some(writer) = &mut self.log_file_writer {
                let _ = writeln!(writer, "{}", message);
            }
            return;
        }

        if self.simple_output {
            println!("{message}");
        }

        if let Some(writer) = &mut self.log_file_writer {
            if let Err(e) = writeln!(writer, "{}", message) {
                if self.simple_output {
                    eprintln!("Failed to write to log file: {}", e);
                }
            }
        }

        if self.logs.len() == self.log_height {
            self.logs.pop_front();
        }
        self.logs.push_back(message);
        self.logs_dirty = true;
    }

    pub(crate) fn toggle_show_help(&mut self) -> Result<(), std::io::Error> {
        self.showing_help = !self.showing_help;

        self.stdout.execute(Clear(ClearType::All))?;
        self.mark_dirty();

        if self.showing_help {
            self.stdout.queue(MoveTo(0, 0))?;
            self.stdout.queue(Print("Ctrl + r: Reset the viewport."))?;
            self.stdout.queue(MoveTo(0, 2))?;
            self.stdout.queue(Print("Ctrl + 5: Increase the pixel ratio."))?;
            self.stdout.queue(MoveTo(0, 4))?;
            self.stdout.queue(Print("Ctrl + 4: Decrease the pixel ratio."))?;
            self.stdout.queue(MoveTo(0, 6))?;
            self.stdout.queue(Print("Ctrl + Mouse Scroll: Zoom in / out."))?;
            self.stdout.queue(MoveTo(0, 8))?;
            self.stdout.queue(Print(
                "Ctrl + Mouse Click and Drag: Pan the viewport. Some terminals might not allow this.",
            ))?;
            self.stdout.queue(MoveTo(0, 10))?;
            self.stdout.queue(Print(
                "Ctrl + z: Show semantic labels (very experimental and jank).",
            ))?;
            self.stdout.queue(MoveTo(0, 12))?;
            self.stdout.queue(Print("?: Toggle help."))?;
            self.stdout.queue(MoveTo(0, 14))?;
            self.stdout.queue(Print(
                "Tips: Changing the current terminal emulator's text size will make things look a lot better. ",
            ))?;
            self.stdout.queue(MoveTo(0, 15))?;
            self.stdout.queue(Print(
                "But the code is suboptimal and it might lead to more jank.",
            ))?;
            self.stdout.flush()?;
        }
        Ok(())
    }

    pub(crate) fn mark_dirty(&mut self) {
        self.dirty = true;
        self.logs_dirty = true;
    }
}

// ---------------------------------------------------------------------------
// Terminal size via ioctl (works even when fd 1 is redirected to /dev/null)
// ---------------------------------------------------------------------------

fn tty_ioctl_size(fd: RawFd) -> Option<(u16, u16, u16, u16)> {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws as *mut libc::winsize) == 0
            && ws.ws_col > 0
            && ws.ws_row > 0
        {
            return Some((ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel));
        }
    }
    None
}

fn tty_ioctl_chars(fd: RawFd) -> (u16, u16) {
    tty_ioctl_size(fd)
        .map(|(c, r, _, _)| (c, r))
        .unwrap_or((80, 24))
}

// ---------------------------------------------------------------------------
// Terminal cell
// ---------------------------------------------------------------------------

#[derive(PartialEq, Eq, Clone)]
struct TerminalCell {
    ch: char,
    fg: Color,
    bg: Color,
}

impl TerminalCell {
    /// Sentinel used to initialise the prev-frame buffer so that every cell is
    /// considered changed on the first draw after a resize or mark_dirty().
    /// Uses a null character and Reset colors that should never appear in a
    /// real rendered frame (real cells always have Rgb colors).
    const DIRTY: TerminalCell = TerminalCell {
        ch: '\0',
        fg: Color::Reset,
        bg: Color::Reset,
    };
}

// ---------------------------------------------------------------------------
// Raw ANSI output helpers — write directly into Vec<u8> to avoid formatting
// overhead and to keep escape-sequence generation allocation-free.
// ---------------------------------------------------------------------------

#[inline]
fn write_uint(out: &mut Vec<u8>, mut n: usize) {
    if n == 0 {
        out.push(b'0');
        return;
    }
    let start = out.len();
    while n > 0 {
        out.push(b'0' + (n % 10) as u8);
        n /= 10;
    }
    out[start..].reverse();
}

#[inline]
fn write_move_to(out: &mut Vec<u8>, col: usize, row: usize) {
    // ESC [ row ; col H
    out.push(b'\x1b');
    out.push(b'[');
    write_uint(out, row);
    out.push(b';');
    write_uint(out, col);
    out.push(b'H');
}

#[inline]
fn write_fg(out: &mut Vec<u8>, r: u8, g: u8, b: u8) {
    // ESC [ 38 ; 2 ; r ; g ; b m
    out.extend_from_slice(b"\x1b[38;2;");
    write_uint(out, r as usize);
    out.push(b';');
    write_uint(out, g as usize);
    out.push(b';');
    write_uint(out, b as usize);
    out.push(b'm');
}

#[inline]
fn write_bg(out: &mut Vec<u8>, r: u8, g: u8, b: u8) {
    // ESC [ 48 ; 2 ; r ; g ; b m
    out.extend_from_slice(b"\x1b[48;2;");
    write_uint(out, r as usize);
    out.push(b';');
    write_uint(out, g as usize);
    out.push(b';');
    write_uint(out, b as usize);
    out.push(b'm');
}

// ---------------------------------------------------------------------------
// Render modes — fill a flat (row-major) Vec<TerminalCell> in place.
// No allocations inside the hot loop.
// ---------------------------------------------------------------------------

fn fill_block(
    out: &mut Vec<TerminalCell>,
    buffer: &[u8],
    buf_w: usize,
    buf_h: usize,
    x_offset: isize,
    y_offset: isize,
    cols: usize,
    rows: usize,
) {
    out.resize(cols * rows, TerminalCell::DIRTY);
    for y in 0..rows {
        for x in 0..cols {
            let px = x_offset + x as isize;
            let py_top = y_offset + (y * 2) as isize;
            let py_bot = y_offset + (y * 2 + 1) as isize;
            out[y * cols + x] = TerminalCell {
                ch: '▀',
                fg: pixel_to_color(get_pixel(buffer, buf_w, buf_h, px, py_top)),
                bg: pixel_to_color(get_pixel(buffer, buf_w, buf_h, px, py_bot)),
            };
        }
    }
}

fn fill_braille(
    out: &mut Vec<TerminalCell>,
    buffer: &[u8],
    buf_w: usize,
    buf_h: usize,
    x_offset: isize,
    y_offset: isize,
    cols: usize,
    rows: usize,
) {
    out.resize(cols * rows, TerminalCell::DIRTY);
    for y in 0..rows {
        for x in 0..cols {
            // Braille dot layout (bit index → col offset, row offset within 2×4 block):
            //   bit 0 = (0,0)  bit 3 = (1,0)
            //   bit 1 = (0,1)  bit 4 = (1,1)
            //   bit 2 = (0,2)  bit 5 = (1,2)
            //   bit 6 = (0,3)  bit 7 = (1,3)
            let px0 = x_offset + (x * 2) as isize;
            let px1 = x_offset + (x * 2 + 1) as isize;
            let py = [
                y_offset + (y * 4) as isize,
                y_offset + (y * 4 + 1) as isize,
                y_offset + (y * 4 + 2) as isize,
                y_offset + (y * 4 + 3) as isize,
            ];

            // Fixed-size arrays — no heap allocation per cell.
            let dot_coords = [
                (px0, py[0]), (px0, py[1]), (px0, py[2]),
                (px1, py[0]), (px1, py[1]), (px1, py[2]),
                (px0, py[3]), (px1, py[3]),
            ];
            let mut rgbs = [[0u8; 3]; 8];
            let mut lumas = [0f32; 8];

            for (i, (dx, dy)) in dot_coords.iter().enumerate() {
                if let Some(rgb) = get_pixel(buffer, buf_w, buf_h, *dx, *dy).map(pixel_to_rgb) {
                    rgbs[i] = rgb;
                    lumas[i] = luma(rgb);
                }
            }

            let mean_luma = lumas.iter().sum::<f32>() * (1.0 / 8.0);

            let mut bits: u32 = 0;
            let mut on_r = 0u32; let mut on_g = 0u32; let mut on_b = 0u32; let mut on_n = 0u32;
            let mut off_r = 0u32; let mut off_g = 0u32; let mut off_b = 0u32; let mut off_n = 0u32;

            for (i, l) in lumas.iter().enumerate() {
                let [r, g, b] = rgbs[i];
                if *l >= mean_luma {
                    bits |= 1 << i;
                    on_r += r as u32; on_g += g as u32; on_b += b as u32; on_n += 1;
                } else {
                    off_r += r as u32; off_g += g as u32; off_b += b as u32; off_n += 1;
                }
            }

            let ch = char::from_u32(0x2800 + bits).unwrap_or('⣿');
            let (fr, fg_v, fb) = if on_n > 0 {
                ((on_r / on_n) as u8, (on_g / on_n) as u8, (on_b / on_n) as u8)
            } else {
                (255, 255, 255)
            };
            let (br, bg_v, bb) = if off_n > 0 {
                ((off_r / off_n) as u8, (off_g / off_n) as u8, (off_b / off_n) as u8)
            } else {
                (0, 0, 0)
            };

            out[y * cols + x] = TerminalCell {
                ch,
                fg: Color::Rgb { r: fr, g: fg_v, b: fb },
                bg: Color::Rgb { r: br, g: bg_v, b: bb },
            };
        }
    }
}

// Density characters from sparse (dark) to dense (bright).
const ASCII_CHARS: &[char] = &[' ', '.', ':', '-', '=', '+', '*', '%', '#', '@'];

fn fill_ascii(
    out: &mut Vec<TerminalCell>,
    buffer: &[u8],
    buf_w: usize,
    buf_h: usize,
    x_offset: isize,
    y_offset: isize,
    cols: usize,
    rows: usize,
) {
    out.resize(cols * rows, TerminalCell::DIRTY);
    for y in 0..rows {
        for x in 0..cols {
            let rgb = get_pixel(buffer, buf_w, buf_h, x_offset + x as isize, y_offset + y as isize)
                .map(pixel_to_rgb)
                .unwrap_or([0, 0, 0]);
            let l = luma(rgb) as usize;
            out[y * cols + x] = TerminalCell {
                ch: ASCII_CHARS[l * (ASCII_CHARS.len() - 1) / 255],
                fg: Color::Rgb { r: rgb[0], g: rgb[1], b: rgb[2] },
                bg: Color::Black,
            };
        }
    }
}

// ---------------------------------------------------------------------------
// Pixel helpers
// ---------------------------------------------------------------------------

#[inline]
fn get_pixel(buffer: &[u8], width: usize, height: usize, x: isize, y: isize) -> Option<&[u8]> {
    if x < 0 || y < 0 || x >= width as isize || y >= height as isize {
        return None;
    }
    let idx = (y as usize * width + x as usize) * 4;
    if idx + 4 <= buffer.len() { Some(&buffer[idx..idx + 4]) } else { None }
}

#[inline]
fn pixel_to_rgb(slice: &[u8]) -> [u8; 3] {
    if cfg!(target_os = "macos") {
        [slice[0], slice[1], slice[2]]
    } else {
        [slice[2], slice[1], slice[0]]
    }
}

#[inline]
fn pixel_to_color(pixel: Option<&[u8]>) -> Color {
    match pixel {
        Some(slice) => {
            let [r, g, b] = pixel_to_rgb(slice);
            Color::Rgb { r, g, b }
        }
        None => Color::Rgb { r: 0, g: 0, b: 0 },
    }
}

#[inline]
fn luma(rgb: [u8; 3]) -> f32 {
    0.299 * rgb[0] as f32 + 0.587 * rgb[1] as f32 + 0.114 * rgb[2] as f32
}

// ---------------------------------------------------------------------------
// Event normalization
// ---------------------------------------------------------------------------

fn normalize_event_height(event: Event, x_scale: f64, y_scale: f64, log_height: usize) -> Event {
    match event {
        Event::Resize(columns, rows) => {
            let rows = rows.saturating_sub(log_height as u16);
            Event::Resize(
                (columns as f64 * x_scale).round() as u16,
                (rows as f64 * y_scale).round() as u16,
            )
        }
        Event::Mouse(mut mouse_event) => {
            mouse_event.column = (mouse_event.column as f64 * x_scale).round() as u16;
            mouse_event.row = (mouse_event.row as f64 * y_scale).round() as u16;
            Event::Mouse(mouse_event)
        }
        x => x,
    }
}

const HELP_HINT: &str = "? for help";
