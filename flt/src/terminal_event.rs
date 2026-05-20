use crate::{
    constants::{SCROLL_DELTA, ZOOM_FACTOR},
    Error, TerminalEmbedder,
};
use crossterm::event::{
    Event, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use flutter_sys::{FlutterPointerMouseButton, FlutterPointerPhase, FlutterPointerSignalKind};

/// Modifier to intercept events which will not be forwarded to Flutter.
const CONTROL_KEY: KeyModifiers = KeyModifiers::CONTROL;

impl TerminalEmbedder {
    pub(crate) fn handle_terminal_event(&mut self, event: Event) -> Result<(), Error> {
        if self.terminal_window.log_events {
            self.terminal_window.log(format!("event: {:?}", event));
        }

        match event {
            crossterm::event::Event::FocusGained => todo!(),
            crossterm::event::Event::FocusLost => todo!(),
            crossterm::event::Event::Key(KeyEvent {
                code, modifiers, ..
            }) => {
                if modifiers == CONTROL_KEY {
                    return self.handle_control_char(code);
                }
                if code == KeyCode::Char('?') {
                    self.terminal_window.toggle_show_help()?;
                    return Ok(());
                }

                // IME text input
                match code {
                    KeyCode::Char(c) => {
                        self.engine.send_text_input_char(c).ok();
                    }
                    KeyCode::Backspace => {
                        self.engine.send_text_input_backspace().ok();
                    }
                    _ => {}
                }

                // Hardware key events (HardwareKeyboard in Flutter framework)
                if let Some((physical, logical)) = terminal_key_codes(code) {
                    let char_arg = if let KeyCode::Char(c) = code { Some(c) } else { None };
                    let down = flutter_sys::sys::FlutterKeyEventType_kFlutterKeyEventTypeDown;
                    let up   = flutter_sys::sys::FlutterKeyEventType_kFlutterKeyEventTypeUp;
                    self.engine.send_key_event(down, physical, logical, char_arg).ok();
                    self.engine.send_key_event(up,   physical, logical, None).ok();
                }

                Ok(())
            }
            crossterm::event::Event::Mouse(MouseEvent {
                kind,
                column,
                row,
                modifiers,
            }) => {
                if modifiers == CONTROL_KEY {
                    match kind {
                        MouseEventKind::Down(MouseButton::Left) => {
                            self.mouse_down_pos = (column as isize, row as isize);
                            self.prev_window_offset = self.window_offset;
                        }
                        MouseEventKind::Drag(MouseButton::Left) => {
                            let delta = (
                                column as isize - self.mouse_down_pos.0,
                                row as isize - self.mouse_down_pos.1,
                            );
                            self.window_offset = (
                                // Negate delta because when mouse is moved to the right
                                // (positive delta), the terminal needs to be offset to the
                                // left (negative offset) to create the illusion of panning the
                                // window it.
                                self.prev_window_offset.0 - delta.0,
                                self.prev_window_offset.1 - delta.1,
                            );

                            self.engine.schedule_frame()?;
                        }
                        MouseEventKind::ScrollDown | MouseEventKind::ScrollUp => {
                            self.zoom = if kind == MouseEventKind::ScrollUp {
                                self.zoom * ZOOM_FACTOR
                            } else {
                                self.zoom / ZOOM_FACTOR
                            };

                            self.engine.schedule_frame()?;

                            // TODO(jiahaog): Zoom towards the cursor instead of
                            // the top left.
                        }
                        _ => (),
                    }
                } else {
                    let (column, row) = (
                        column as f64 + self.window_offset.0 as f64,
                        row as f64 + self.window_offset.1 as f64,
                    );
                    match kind {
                        crossterm::event::MouseEventKind::Down(mouse_button) => {
                            self.engine.send_pointer_event(
                                FlutterPointerPhase::Down,
                                (column as f64, row as f64),
                                FlutterPointerSignalKind::None,
                                0.0,
                                vec![to_mouse_button(mouse_button)],
                            )?;
                        }
                        crossterm::event::MouseEventKind::Up(mouse_button) => {
                            self.engine.send_pointer_event(
                                FlutterPointerPhase::Up,
                                (column as f64, row as f64),
                                FlutterPointerSignalKind::None,
                                0.0,
                                vec![to_mouse_button(mouse_button)],
                            )?;
                        }
                        crossterm::event::MouseEventKind::Drag(_) => (),
                        crossterm::event::MouseEventKind::Moved => {
                            self.engine.send_pointer_event(
                                FlutterPointerPhase::Hover,
                                (column as f64, row as f64),
                                FlutterPointerSignalKind::None,
                                0.0,
                                vec![],
                            )?;
                        }
                        crossterm::event::MouseEventKind::ScrollUp => {
                            self.engine.send_pointer_event(
                                FlutterPointerPhase::Up,
                                (column as f64, row as f64),
                                FlutterPointerSignalKind::Scroll,
                                -SCROLL_DELTA,
                                vec![],
                            )?;
                        }
                        crossterm::event::MouseEventKind::ScrollDown => {
                            self.engine.send_pointer_event(
                                FlutterPointerPhase::Down,
                                (column as f64, row as f64),
                                FlutterPointerSignalKind::Scroll,
                                SCROLL_DELTA,
                                vec![],
                            )?;
                        }
                        crossterm::event::MouseEventKind::ScrollLeft
                        | crossterm::event::MouseEventKind::ScrollRight => {}
                    }
                }
                Ok(())
            }
            crossterm::event::Event::Paste(_) => todo!(),
            crossterm::event::Event::Resize(columns, rows) => {
                self.dimensions = (columns as usize, rows as usize);
                self.terminal_window.mark_dirty();
                self.engine.schedule_frame()?;
                Ok(())
            }
        }
    }

    fn handle_control_char(&mut self, code: KeyCode) -> Result<(), Error> {
        match code {
            KeyCode::Char('c') => {
                self.should_run = false;
                Ok(())
            }
            KeyCode::Char('z') => {
                self.show_semantics = !self.show_semantics;
                // Flutter does not update the semantics callback when they are disabled.
                if !self.show_semantics {
                    self.terminal_window.update_semantics(vec![]);
                    self.terminal_window.mark_dirty();
                }
                self.engine.update_semantics(self.show_semantics)?;
                Ok(())
            }
            KeyCode::Char('r') => {
                self.reset_viewport()?;
                Ok(())
            }
            KeyCode::Char('5') => {
                self.scale *= ZOOM_FACTOR;
                self.engine.schedule_frame()?;
                Ok(())
            }
            KeyCode::Char('4') => {
                self.scale /= ZOOM_FACTOR;
                self.engine.schedule_frame()?;
                Ok(())
            }
            _ => Ok(()),
        }
    }
}

/// Map crossterm KeyCode → (physical HID, logical Flutter) key codes.
/// Physical = (hid_page << 16) | hid_usage; values from USB HID spec page 0x07.
/// Logical values from Flutter's LogicalKeyboardKey.
fn terminal_key_codes(code: KeyCode) -> Option<(u64, u64)> {
    Some(match code {
        // Navigation
        KeyCode::Tab         => (0x0007002b, 0x00100000009),
        KeyCode::Enter       => (0x00070028, 0x0010000000d),
        KeyCode::Up          => (0x00070052, 0x00100000304),
        KeyCode::Down        => (0x00070051, 0x00100000301),
        KeyCode::Left        => (0x00070050, 0x00100000302),
        KeyCode::Right       => (0x0007004f, 0x00100000303),
        KeyCode::Home        => (0x0007004a, 0x00100000306),
        KeyCode::End         => (0x0007004d, 0x00100000305),
        KeyCode::PageUp      => (0x0007004b, 0x00100000308),
        KeyCode::PageDown    => (0x0007004e, 0x00100000307),
        KeyCode::Esc         => (0x00070029, 0x00100000001),
        KeyCode::Backspace   => (0x0007002a, 0x00100000008),
        KeyCode::Delete      => (0x0007004c, 0x0010000007f),
        KeyCode::Char(c)     => {
            let logical = c as u64;
            // Physical: printable ASCII maps to USB HID page 7 usage.
            // Use logical as physical stand-in — Flutter accepts this for text.
            (logical, logical)
        }
        _ => return None,
    })
}

fn to_mouse_button(value: crossterm::event::MouseButton) -> FlutterPointerMouseButton {
    match value {
        crossterm::event::MouseButton::Left => FlutterPointerMouseButton::Left,
        crossterm::event::MouseButton::Right => FlutterPointerMouseButton::Right,
        crossterm::event::MouseButton::Middle => FlutterPointerMouseButton::Middle,
    }
}
