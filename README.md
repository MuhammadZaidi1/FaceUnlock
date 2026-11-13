# FaceUnlock

A native SwiftUI menu-bar-only macOS application scaffold. Requires macOS 13 or later; the packaging script targets Apple Silicon (`arm64`). Uses `MenuBarExtra` with the SF Symbol `faceid` and a compact native popover. The packaged app has `LSUIElement = true`, so it has no Dock icon. A temporary setup window opens only when requested.

Phase 2 adds local camera preview and Vision face-presence detection in **Enroll Face…**. Identity enrollment and recognition are not implemented. The enable switch still saves only a local preference using `UserDefaults`; it does not start the camera. Settings remains a placeholder. No frames, face templates, or passwords are saved or uploaded. No password automation, administrator privileges, login hooks, or authentication changes are implemented.

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

In VS Code, **Terminal → Run Task… → FaceUnlock: run app** packages a debug bundle and opens it. Use this bundled launch flow to ensure macOS reads `LSUIElement`; `swift run` is not the supported camera launch path: camera permission requires the packaged app’s usage description and stable bundle identity.

Click the face icon in the menu bar to open the popover. Toggle the saved preference, open **Enroll Face…** for live detection or **Settings…** for its placeholder, and use **Quit FaceUnlock** to exit. Quit the running app before rebuilding and reopening it. If the icon is hidden behind a MacBook notch, free menu-bar space by closing other menu-bar apps.

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
- `Sources/FaceUnlock/MenuBarView.swift`: popover UI, setup action, and Settings placeholder.
- `Sources/FaceUnlock/CameraController.swift`: camera permission checks, serial capture/session lifecycle, device/session notifications, throttled Vision face detection (up to five requests per second), and main-thread UI status. Late permission replies and results are invalidated on close. Frames are processed synchronously in memory without a retained backlog.
- `Sources/FaceUnlock/CameraPreview.swift`: AppKit video-preview-layer bridge for SwiftUI, with a mirrored webcam preview. No image export or recording output.
- `Sources/FaceUnlock/EnrollmentView.swift`: temporary setup UI with preview, face-count/status indicator, Retry, privacy settings link, and Done.
- `Sources/FaceUnlock/EnrollmentWindowController.swift`: single setup-window ownership, close handling, and application delegate that waits for camera shutdown when the app quits. Opening the menu again does not create a second camera session.
- `Resources/Info.plist`: application metadata, Dock suppression, and `NSCameraUsageDescription`.
- `scripts/package-app.sh`: Apple Silicon build and bundle assembly.
- `.vscode/`: recommended extension and build/package/run tasks.

## Camera permission and live detection testing

Only **Camera** permission is requested, on first opening **Enroll Face…**, using AVFoundation. The system prompt explains local preview and face detection. No microphone input is configured; no microphone, Accessibility, Screen Recording, Full Disk Access, or administrator permission is requested. Vision processes frames locally and does not request a separate permission. See [Apple’s camera authorization guidance](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos).

Always quit FaceUnlock before rebuilding. Test the bundled app from the same location each time. Ad-hoc signatures can cause macOS to reconsider permission after a rebuild; a stable Developer ID signature is appropriate for distribution.

1. Build/package and run using the commands above. Opening the menu or toggling Enable must not activate the camera or show a permission prompt.
2. Choose **Enroll Face…**. On a fresh permission state, choose **Allow** in the macOS Camera prompt. Confirm live preview; move your face into and out of view. The indicator should change between **Face detected**, **No face detected**, and a face count when multiple faces are visible. This is presence detection, not identity or liveness verification. Use a normally oriented built-in/USB webcam; unusual camera mounting/orientation may reduce detection quality.
3. Choose **Done** or close the setup window with its red close button. Confirm the hardware camera light/system camera-use indicator clears (unless another app is using the camera). Reopen setup and repeat. Opening the menu-bar popover does not stop capture while setup remains open. The setup window has no minimize button.
4. Close setup while the permission prompt is pending, then respond to it. The camera must remain stopped until setup is opened again. The macOS permission dialog itself may remain visible after setup closes.
5. Test denial: quit, reset only this app’s camera decision as shown below, reopen, choose **Enroll Face…**, then **Don’t Allow**. Confirm explanatory text and **Camera Privacy Settings…** appear without a crash or repeated prompts. Enable FaceUnlock in **System Settings → Privacy & Security → Camera**, return, and choose **Retry**. If macOS requires an app restart, quit and reopen. A managed/restricted camera shows a restriction message instead.
6. With no camera attached (on a Mac without a built-in camera), confirm the unavailable message. Connect a camera and choose **Retry**. With a USB camera actively previewing, unplug it: confirm the indicator clears and an error/disconnection message offers Retry. Reconnect and retry. The app selects the system default video camera; there is no camera picker yet.
7. Try sleep/wake or a competing camera application. Session interruption clears the detected-face status; capture resumes on interruption-end when available. An unexpected stop/runtime error offers **Retry** instead of looping indefinitely. macOS can share cameras between apps, so another app may not cause an interruption. See [Apple’s session notifications](https://developer.apple.com/documentation/avfoundation/avcapturesession).
8. Quit FaceUnlock from its menu while setup is open. Confirm the app exits and camera use stops. Relaunch: the camera must remain off until setup opens. Detection runs regardless of the saved Enable preference because that switch remains a future recognition preference.

To retest the first-use permission prompt, first quit FaceUnlock, then run this optional command yourself. It resets only this bundle’s Camera decision; it does not grant access or change other apps:

```sh
tccutil reset Camera com.faceunlock.app
open dist/FaceUnlock.app
```

## Validation

Phase 2 validation includes debug/release builds on Apple Silicon, bundle/plist validation, ad-hoc signature verification, `arm64` architecture, a release-app launch/process smoke check, and verification that the packaged plist retains `LSUIElement` and contains `NSCameraUsageDescription`. No full Xcode installation is needed with the working Command Line Tools SDK. The `code` shell command was absent during initial setup; configure it using the VS Code instructions above if desired.

Live camera imagery, permission choices, disconnection, and sleep/wake scenarios require the manual hardware checks above; they are not claimed as automated test results. The UI inspection tool timed out during validation. No permission decisions were reset automatically.
