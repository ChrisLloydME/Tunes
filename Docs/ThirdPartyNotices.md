# Third-party notices

## Kaset

Tunes uses source from [Kaset](https://github.com/sozercan/kaset),
revision `83513f6da059fd6b5e8816b2ae734be3475ca5a9` (MIT).
The license is also included in the app bundle as `Kaset-LICENSE.txt`.

- `Tunes/LibraryView.swift`: album card layout adapted from
  `Sources/Kaset/Views/LibraryView.swift`.
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
- `Tunes/Assets.xcassets/PlayerAccent.colorset`: copied Kaset's
  `Resources/Assets.xcassets/AccentColor.colorset`, scoped to the player so native
  sidebar selection keeps its system styling.

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
