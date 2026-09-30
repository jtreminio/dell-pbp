# Dell PBP development

This app controls a daily-use Dell U4025QW monitor. Keep writes restricted to supported PBP modes and input-source settings. Never introduce firmware writes or experimental mode values.

- `make test` must remain entirely offline and must not access a monitor.
- Build with `make build`; full Xcode is not required.
- Hardware tests are separate and opt-in. Preserve the starting input pair and split, and verify restoration.
- Before a test that changes the live display, alert the user and wait for confirmation that their work is saved.
- Treat transport success as insufficient: validate readback before marking a layout selected.
- Do not retry writes blindly. Reconnect after video renegotiation.
- Keep UI work on the main thread and monitor I/O on the serial worker queue.
- Preserve E8's upper bits and distinguish VCP 60's local connection byte from its selected-source byte.
- Keep wake protection temporary. Do not modify persistent power settings or fake keyboard/mouse input.
