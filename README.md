# FaceUnlock

A native SwiftUI menu-bar-only macOS application scaffold. Requires macOS 13 or later; the packaging script targets Apple Silicon (`arm64`). Uses `MenuBarExtra` with the SF Symbol `faceid` and a compact native popover. The packaged app has `LSUIElement = true`, so it has no Dock icon or regular application window.

The enable switch saves a local preference using `UserDefaults`. It does **not** activate recognition. Enrollment and Settings show placeholder alerts. No camera access, biometric collection, password automation, administrator privileges, or authentication changes are implemented.

## Toolchain setup

1. Install VS Code for macOS and the **Swift** extension (`swiftlang.swift-vscode`). In VS Code, use the Command Palette → **Shell Command: Install 'code' command in PATH** if you want to open the project from Terminal.
2. Install Apple's Command Line Tools with `xcode-select --install`, or install full Xcode from the Mac App Store. Swift 5.9 or newer and a macOS SDK are required. Full Xcode is optional for this package and local `.app` packaging.
3. If using full Xcode, open it once and complete its first-launch setup. Select its toolchain without changing the system-wide developer directory:

   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   ```

   Run this export in each terminal session that should use Xcode. To use the standalone Command Line Tools explicitly instead:

   ```sh
   export DEVELOPER_DIR=/Library/Developer/CommandLineTools
   ```

4. Verify the selected tools:

   ```sh
   swift --version
   xcrun --find swift
   xcrun --show-sdk-path
   uname -m
   ```

   On an Apple Silicon terminal, `uname -m` should report `arm64`. If using full Xcode, `xcodebuild -version` should also succeed; it is expected to fail when only Command Line Tools are selected.

## Open and build in VS Code

Open this folder with **File → Open Folder…**, or from its parent directory:

```sh
code FaceUnlock
```

Let the Swift extension discover `Package.swift`. Run **Terminal → Run Build Task…** (`⇧⌘B`) for a debug build. Equivalent terminal commands, from the repository root:

```sh
swift build
swift build --configuration release --arch arm64
```

There are no external package dependencies. SourceKit-LSP is supplied by the Swift toolchain. If the extension cannot find Swift, confirm the toolchain selection above, then restart VS Code from that terminal with `code .`.

## Package and run the real app

Swift Package Manager builds an executable, not a macOS application bundle. Use the included script to build the executable, assemble the bundle, validate its plist, and apply a local ad-hoc signature:

```sh
bash scripts/package-app.sh
open dist/FaceUnlock.app
```

The default configuration is `release`. For a debug bundle:

```sh
bash scripts/package-app.sh debug
open dist/FaceUnlock.app
```

In VS Code, **Terminal → Run Task… → FaceUnlock: run app** packages a debug bundle and opens it. Use this bundled launch flow to ensure macOS reads `LSUIElement`; `swift run` is not the supported menu-bar-only launch path.

Click the face icon in the menu bar to open the popover. Toggle the saved preference, open the two placeholder alerts, and use **Quit FaceUnlock** to exit. Quit the running app before rebuilding and reopening it. If the icon is hidden behind a MacBook notch, free menu-bar space by closing other menu-bar apps.

The result is `dist/FaceUnlock.app`, containing `Contents/Info.plist` and `Contents/MacOS/FaceUnlock`. You can copy it to `~/Applications` if desired. No installer or administrator access is required. Ad-hoc signing supports local development; distribution to other machines requires your own Apple Developer signing and notarization workflow.

To inspect the packaged result:

```sh
plutil -lint dist/FaceUnlock.app/Contents/Info.plist
file dist/FaceUnlock.app/Contents/MacOS/FaceUnlock
codesign --verify --strict --verbose=2 dist/FaceUnlock.app
```

## Structure

- `Package.swift`: executable package, macOS 13 minimum.
- `Sources/FaceUnlock/FaceUnlockApp.swift`: application entry point and menu-bar scene.
- `Sources/FaceUnlock/AppState.swift`: observable state and preference persistence.
- `Sources/FaceUnlock/MenuBarView.swift`: popover UI and placeholder alerts.
- `Resources/Info.plist`: application metadata and Dock suppression.
- `scripts/package-app.sh`: Apple Silicon build and bundle assembly.
- `.vscode/`: recommended extension and build/package/run tasks.

## Validation

Run the debug and release builds plus the bundle checks above. Manually verify that the bundled app displays the face icon, has no Dock icon, opens a compact popover, persists its toggle across launches, shows both placeholder alerts, and quits. This scaffold has no recognition engine to test.

Verified during initial implementation on Apple Silicon with Apple Swift 6.3.3 and Command Line Tools: debug and release compilation, `.app` assembly, plist validation, ad-hoc signature verification, `arm64` executable architecture, and a debug app launch/process smoke check. Visual interactions have not been manually verified. The initial restricted build could not write global Swift caches; workspace-local caches and a build with normal local cache access succeeded. No full Xcode installation was needed. The `code` shell command was absent, so configure it using the VS Code instructions above if desired.
