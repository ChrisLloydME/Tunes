# Third-party notices

## About page design reference

The independent About Tunes window uses AudioMator's About page as a visual
layout reference (Christopher Lloyd; user-provided `AudioMator-main.zip`, archive
revision `e9deb6b0a0f468ff32a6467477a851dcefa74ea4`). The Tunes implementation
uses its own app information, release summary, privacy text, and acknowledgements.

## Kaset

Tunes uses source from [Kaset](https://github.com/sozercan/kaset),
revision `83513f6da059fd6b5e8816b2ae734be3475ca5a9` (MIT).
The license is also included in the app bundle as `Kaset-LICENSE.txt`.

- `Tunes/LibraryView.swift`: album card layout adapted from
  `Sources/Kaset/Views/LibraryView.swift`.
- `Tunes/Album/AlbumDetailView.swift`: directly adapted the album branch of
  `Sources/Kaset/Views/PlaylistDetailView.swift` and its
  `PlaylistDetailView+HeaderActions.swift`. Preserves the single lazy scroll stack,
  180-point cover, header typography/spacing, Play button style, and track dividers.
  Removed queue editing, playlist management, likes, AI refinement, pinning, and
  artist navigation. Optional uploads and alternate versions live in secondary menus.
- `Tunes/Album/AlbumTrackRow.swift`: copied the album branch of
  `Sources/Kaset/Views/PlaylistTrackRow.swift`, replacing YouTube song/player data
  with Samply state and removing likes, explicit badges, and artist links.
- `Tunes/Album/Kaset/`: copied `AccentBackground.swift`, `TopFade.swift`,
  `SharedViews/DetailContentLayout.swift`, `SharedViews/EqualizerView.swift`,
  and the row style from `SharedViews/InteractiveCardStyle.swift`.
  Copied the palette extraction code from `Utilities/ColorExtractor.swift` with
  the existing Tunes memory-only artwork cache. Removed previews, haptics, and
  the upstream palette cache dependency; inlined the quick animation constant.
  Tunes uses its theme accent for interactive controls. Palette extraction retains
  bright saturated artwork pixels, ignores transparent pixels, and uses a neutral
  fallback instead of borrowing the system accent.
- `Tunes/Playback/PlayerBar.swift`: directly adapted from
  `Sources/Kaset/Views/PlayerBar.swift`. Preserves the glass container, fixed
  section widths, compact breakpoint, transport/volume placement, timeline,
  margins, artwork glow, marquee, and volume capsule. Samply supplies playback
  data and commands. Unsupported account actions, AirPlay, shuffle/repeat, lyrics,
  queue, video, mini player, and artist/album resolution were removed.
- `Tunes/Playback/Kaset/`: copied `PlayerBarIconButton`, `PlayerBarIconMenu`,
  `PlayerBarMarqueeText`, `PlayerBarMetadataLink`, `PlayerBarArtworkView`,
  `PlayerBarArtworkGlow`, `PlayerBarProgressLane`, `PlayerBarSliderVisuals`,
  `PlayerBarSliderLoadingShimmer`, `PlayerBarVerticalSlider`,
  `PlayerBarVolumeOverlayHost`, and `PlayerBarSeekHold` from `Sources/Kaset/Views/`.
  Local changes inline Kaset's quick animation constant, remove its macOS 15
  compatibility environment, and replace its artwork cache with a memory-only
  Tunes cache. `PlayerBarGlass.swift` retains the native macOS branch of
  `Sources/Kaset/Utilities/LiquidGlassCompat.swift`.
- Interactive controls use SwiftUI `Color.accentColor`; Kaset's fixed pink/red
  accent asset has been removed.

All copied files carry a provenance comment. Tunes' Sidebar uses standard
SwiftUI `List(selection:)` styling rather than Kaset's custom sidebar row.

```text
MIT License

Copyright (c) 2025 sozercan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
