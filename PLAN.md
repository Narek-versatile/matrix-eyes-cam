# Matrix Eyes Cam: plan

A virtual webcam for Google Meet (and Zoom, FaceTime, anything that picks a camera). You set up a look once (a background and what your silhouette becomes) and every call starts with it.

## Decisions

| Question | Answer |
| --- | --- |
| How video reaches Meet | A macOS **virtual camera** ("Matrix Eyes Cam" in the camera list), built as a CoreMediaIO camera extension |
| Signing | A friend's paid Apple Developer account (needed for the camera extension; see "Signing") |
| Silhouette options | Real you with effects, Matrix Eyes material looks, fill with image/video/animated texture, face-tracked avatars |
| Backgrounds | Endlessly animated "impossible" 3D spaces, animated scenes, blur / tidy room |
| Output | 1280×720 at 30 fps (1080p optional), sent **unmirrored** so text reads correctly for others; the studio preview is mirrored like a mirror |

## Architecture

```
camera (AVFoundation) ─┬─ person mask + face position (Vision)       ┐
                       ├─ depth (Depth Anything V2, Core ML) ─────── ├─► Engine (Metal) ─► 1280×720 frame ─┬─► Studio preview
                       └─ picture                                    ┘   background │ subject │ composite  └─► virtual camera
```

- **Engine** (`Sources/Engine`): one render per frame at the output size.
  1. *Background layer*: the room (as is / blurred / tidied) or a generated scene. Generated 3D scenes follow your head position (face tracking), so the background behaves like a window instead of a flat picture.
  2. *Subject layer*: your cut-out, kept as you are or turned into something else, with soft edges.
  3. *Composite*: subject over background with light wrap (background light bleeding onto your edges), trails, final grade.
- **Studio app** (`Sources/Studio`): live preview of exactly what the call sees, background / silhouette pickers with their parameters, presets, menu bar quick-switch. Presets are stored in Application Support; the active one is applied automatically when the camera starts.
- **Camera extension** (`Sources/Extension`): exposes the virtual camera. It has a *source* stream (what Meet reads) and a *sink* stream that the Studio app writes rendered frames into. When the app isn't sending, the camera shows a "open Matrix Eyes Cam" card.

## Phases

1. **Engine + Studio app** (no signing needed): all backgrounds and silhouette modes except avatars, presets, live preview, clean output window. **Done.**
2. **Virtual camera**: extension + sink stream + install/activation flow, project generated with XcodeGen. **Built and compiles (unsigned Xcode build verified); loading it needs signing.**
3. **Face-tracked avatars**: characters driven by Vision face landmarks (head turn, mouth, blinks). Next.
4. **Distribution**: Developer ID signing + notarization, installer, README, release.

## Signing

A camera extension is a system extension. macOS only loads it if it is signed by a real Apple developer team with the system-extension entitlement, and the user approves it once in System Settings › General › Login Items & Extensions. Ad-hoc signing (what Matrix Eyes uses) isn't accepted.

Using a friend's account works technically, but the app is then published under their name and their account is responsible for it under Apple's developer agreement. The cleanest set-ups:
- the friend adds you to their team (possible with an *organization* membership), or
- the friend does the final signing / notarization step on their Mac.

`Signing.xcconfig` holds the team ID; nothing else in the project depends on whose account it is.

## Backgrounds (v1)

| Kind | Notes |
| --- | --- |
| Room | camera as is |
| Blurred room | background-only blur (no halo around you) |
| Tidy room | blur + desaturate + darken: a calm "studio" look |
| Space | starfield, optional ray-traced black hole (from Matrix Eyes) |
| Matrix rain | digital rain |
| Aurora | night sky, aurora curtains, mountains |
| Synthwave | neon grid and sun |
| Infinite corridor | impossible: endless arched hall that slowly twists around its own axis |
| Escher stairs | impossible: staircases in every direction, slowly turning |
| Fractal cathedral | impossible: endless flight through a self-similar stone sponge |

## Silhouette (v1)

| Mode | Options |
| --- | --- |
| Real you | grade: natural / noir / warm film / cyberpunk |
| Effects | edge glow, hologram, neon outline, pixelate, ghost trails |
| Materials | Silver Surfer chrome, quartz, verdigris copper, bronze, doodle, 3D print, Matrix code |
| Fill | galaxy, fire, ocean caustics, lava, or your own image / video |
| Avatars | phase 3 |
