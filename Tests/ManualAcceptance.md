# VantaShot product acceptance

Record the exact build, OS, architecture, display scale and evidence file for each run. A source-connected feature is not a runtime pass.

The current execution record and 60-feature matrix live in `../../notes/vantashot-implementation-2026-10-27/`.

- Capture: region, fullscreen, window, previous area, timer completion/cancellation, All-in-One area/window actions; window→area/fullscreen transitions must export the final target.
- Selection: move and resize without creating a replacement rectangle; distinguish points from output pixels on 1×/2× displays.
- Lifecycle: reopen editor/history20 times; close launcher and reopen from Dock; cancel selection/countdown/scrolling/recording/startup/export and start another operation.
- Documents: opaque redaction→later pixelation→crop→PNG/copy/drag, with Undo/Redo; portrait/landscape/Retina images preserve original pixels; rendering errors never return the unmodified source.
- Editing: arrow variants, rectangles, ellipse, line, pen, freehand highlighter, text/fonts, numbering, pixelation, opaque concealment, spotlight union, image insertion, select/move/resize/delete. Text properties work with background inspector hidden. Cmd+C/Z/Shift+Z remain native inside text fields.
- Background/pin: padding/corners/shadow/gradient/wallpaper and sampled colors; pin opacity/zoom/lock; desktop cover matches configured fit. Hide icons before recording; the recording must preserve the cover while omitting application controls.
- Output: unique files, injected write failures, one clipboard item, actual Finder/Dropover/browser drag and cancellation. GIF/MP4 cards must export their animated/media file, never their preview PNG.
- Scrolling: stationary frames, low-information/unmatched frames, forward/reverse movement, horizontal movement and fixed header/footer; compare every seam pixel to a known fixture.
- OCR: known Arabic/English and URL fixtures, unsupported language, no text, failure, cancellation, stale completion while copying a newer image.
- Recording: actual45+ seconds with late visible markers; five-minute memory samples; pause gap excluded; system/microphone/both tracks audible and within150ms of a visible/audio marker; disconnect/interruption has an explicit result.
- Trim/project/history: trim1…3 produces2 seconds without replacing original; valid .vantashot saves/reopens layers/source/crop/font; restart retains still/GIF/MP4; restore does not duplicate; soft-delete can be restored after restart. Interrupted history commit must be retryable.
- Environments: macOS13 and current macOS, Intel/arm64, Retina, two displays with negative origins/mixed scales, unplug/reflow, TCC denial/regrant. Mark absent environments unavailable, never passed.

G (Flow, cloud, extensions, distribution/update channel, loupe/snapping/freeze) remains separately specified and gated. No full CleanShot parity is implied.
