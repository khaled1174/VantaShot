# Shortcut acceptance

- Cmd+, and the gear open settings.
- Record, change, disable, clear and reset; persist across restart; label matches current physical-key binding and current input layout.
- A duplicate/system-reserved/failed registration retains the previous binding and a durable explanation after recorder dismissal.
- Suspend registration during recording a new chord; Esc cancels the recorder and restores bindings.
- Actual global dispatch from Finder and a browser with launcher hidden requires system/HID key delivery. App-targeted remote events bypass that layer; do not infer failure or success from those events.
- The automated Carbon integration test covers OS registration, application-target event dispatch, repeat suppression and conflict rollback with isolated preferences. It is separate from physical/HID acceptance.
- In text fields, Cmd+C/Z/Shift+Z edit text; outside text input they operate on the annotation document. Test Arabic and English keyboard layouts.
