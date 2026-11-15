# Leo app icon — plan (2026-10-20)

Approved art: three layers (background, terminal, cat) as an Icon Composer bundle. No specular (owner dislikes glossy shine). One icon only: Ghostty's `macos-icon*` variants are ignored.

Scope: shared `images/Ghostty.icon` gives both platforms the icon. Swift changes are Mac-only (iOS has no runtime icon code). Zero Zig changes. TDD exception: assets + UI glue, verified by build, asset inspection and screenshots.

## Steps

1. **Swift ignores icon config (macOS)**
   - `AppDelegate.swift` `updateAppIcon`: pass `nil` instead of `AppIcon(config:)` with comment `// Leo: one icon; macos-icon* ignored` (each config load clears any persisted custom icon).
   - `DockTilePlugin.swift` `iconDidChange`: ignore `newIcon`, always `resetIcon` (the Dock loads the plugin pre-launch; a stale persisted `.retro` would hit `image(forResource:)!` on a deleted imageset).
   - `DockTilePlugin.swift` `resetIcon`: drop the `#if DEBUG` BlueprintImage branch; macOS 26+ always nil.
   - `AboutView.swift`: replace `CyclingIconView()` with a static `ghosttyIconImage()` (drops cycle hint + Copy Icon Config).
   - Leave `CyclingIconView`, `AboutViewModel`, `AppIcon.swift`, `ColorizedGhostty*`, `Ghostty.Config`, `ConfigTypes` as compiling dead code (small upstream diff).
   - Verify: build, `swiftlint lint --strict --quiet` on changed files, in-host tests touching `ConfigTests.macosIcon*` and `ColorizedGhosttyIconTests`.
2. **Delete variant artwork**: `macos/Assets.xcassets/Alternate Icons/` and `Custom Icon/` (folder-reference catalog, no pbxproj edit; the DockTilePlugin target also bundles `Assets.xcassets`). Verify build + grep Sources for deleted names.
3. **Replace `images/Ghostty.icon` contents** (keep bundle name, `APPICON_NAME=Ghostty`): delete old `Assets/*.png`, copy the three layer PNGs (verify with `cmp`), write `icon.json` (navy gradient fill; groups Cat > Terminal > Background; `specular:false`, no translucency, no glass). Verify both builds and render with ictool if available.
4. **Regenerate `AppIconImage.imageset` PNGs** (pre-Tahoe fallback; keep filenames, `Contents.json` unchanged) from the built `Ghostty.icns` (256/512/1024). They need the macOS rounded-square shape with ~100px padding; otherwise mask `leo-icon-fullbleed-1024.png` to an 824px continuous-corner square at (100,100) with a soft shadow.

## Verification
- macOS: `xcodebuild build-for-testing` (Xcode 26.3); `CFBundleIconName` = Ghostty; `assetutil` on app and DockTilePlugin `Assets.car` shows no variant/Custom icon names.
- iOS: `xcodegen generate` leaves `Leo.xcodeproj` unchanged; `xcodebuild build` (Xcode 26.5, iPhone 17 Pro sim); `assetutil`; simulator home screenshots (default/dark; tinted/clear if a CLI exists).
- macOS icon render via `qlmanage -t`, no input events to any running app.
