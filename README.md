# FaceUnlock

A native SwiftUI menu-bar-only macOS application scaffold. Requires macOS 13 or later; the packaging script targets Apple Silicon (`arm64`). Uses `MenuBarExtra` with the SF Symbol `faceid` and a compact native popover. The packaged app has `LSUIElement = true`, so it has no Dock icon. A temporary setup window opens only when requested.

Phase 3 adds one-person enrollment and live identity comparison using a genuine pretrained SFace model running locally through Core ML. Vision supplies face landmarks and quality signals; it is not the identity model. A temporary window collects six samples or performs verification, then stops capture. The menu shows enrollment status, Enroll/Replace, Verify, Delete with confirmation, Settings, and Quit.

**Prototype only: no reliable anti-spoofing and not suitable for security-critical authentication.** A photograph or screen replay may match. FaceUnlock does not unlock macOS, enter passwords, install login hooks, request administrator privileges, or modify authentication. The Enable switch remains a saved preference only and never starts a background camera session.

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

There are no external Swift package dependencies. The real Core ML model and its license are included; normal builds need no Python installation or network downloads. SourceKit-LSP is supplied by the Swift toolchain. If the extension cannot find Swift, confirm the toolchain selection above, then restart VS Code from that terminal with `code .`.

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

Click the face icon in the menu bar to open the popover. Choose **Enroll Face…** to collect samples, **Verify Face…** to compare against the saved profile, or **Settings…** for its placeholder. Use **Quit FaceUnlock** to exit. Quit the running app before rebuilding and reopening it. If the icon is hidden behind a MacBook notch, free menu-bar space by closing other menu-bar apps.

The result is `dist/FaceUnlock.app`, containing `Contents/Info.plist` and `Contents/MacOS/FaceUnlock`. You can copy it to `~/Applications` if desired. No installer or administrator access is required. Ad-hoc signing supports local development; distribution to other machines requires your own Apple Developer signing and notarization workflow.

To inspect the packaged result:

```sh
plutil -lint dist/FaceUnlock.app/Contents/Info.plist
file dist/FaceUnlock.app/Contents/MacOS/FaceUnlock
codesign --verify --strict --verbose=2 dist/FaceUnlock.app
```

## Model source, license, and preprocessing

The selected checkpoint is **OpenCV Zoo SFace `face_recognition_sface_2021dec.onnx`**, a MobileFaceNet trained with the SFace identity loss. This is a face-identity embedding network, not Vision feature prints, detection confidence, image similarity, or random vectors.

- [Official model directory and provenance](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface): contributed by Yaoyao Zhong; original ONNX conversion credited to Chengrui Wang. Its README explicitly states that **all files in that model directory** are Apache-2.0. The model-specific license and conversion notice are bundled under `Sources/FaceModel/Models` and inside the app. This is independent of the surrounding code license.
- [Published weight pointer](https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx): source SHA-256 `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`. Downloaded weights were checked against this digest before conversion.
- Input: aligned **RGB**, float32 **[1, 3, 112, 112]**, byte values **0…255**, channels first, rows top to bottom. The original graph contains its own subtraction/scaling; do not apply a second normalization. Output: raw float32 **[1, 128]**, then L2-normalized by the app.
- [OpenCV's implementation](https://github.com/opencv/opencv/blob/4.x/modules/objdetect/src/face_recognize.cpp) provides five canonical alignment points. This app estimates a nonreflecting similarity transform using Vision eye centers, nose tip from the nose crest, and outer mouth corners; camera frames stay unmirrored for inference. The preview alone is mirrored. Bitmap orientation has a synthetic-color smoke check. Core Image color management is disabled during alignment to preserve RGB byte values.
- Matching uses cosine similarity of unit vectors. The initial internal threshold is **0.363**, from [OpenCV's SFace evaluation/tutorial](https://docs.opencv.org/4.12.0/d0/dd4/tutorial_dnn_face.html). Equality passes. This is a starting point from that published pipeline, **not a calibrated false-accept rate for Vision landmarks, this camera, averaged profiles, or this user**. No scores are presented as probabilities. Internal settings live in `VerificationPolicy.swift`; there is no user-facing threshold slider.
- The included model is a float32 Core ML **ML Program** targeted at macOS 13. It is compiled locally on first use on a background queue and runs with CPU-only compute for predictable conversion parity. No Python, ONNX Runtime, remote service, or model download is used at app runtime.

Other candidates were considered: [InsightFace](https://github.com/deepinsight/insightface) distinguishes its MIT code from supplied weights restricted to noncommercial research, so those weights were not bundled. [FaceNet](https://github.com/davidsandberg/facenet) would require a separate checkpoint/conversion/provenance evaluation; its code license alone was not treated as a license for arbitrary redistributed weights. SFace was selected because its actual model directory supplies an explicit redistribution license and its inference graph could be numerically validated here.

The [SFace research](https://github.com/zhongyy/SFace) discusses CASIA-WebFace, VGGFace2, and MS-Celeb-1M; the exact dataset lineage for this particular checkpoint is not specified in the model directory. The upstream license is not a guarantee of training-data consent, demographic fairness, or security suitability. The artifact is redistributable under the upstream model directory's stated Apache-2.0 terms; no unrelated weights or inherited code-license assumptions were used.

## Enrollment, quality, and verification behavior

Enrollment accepts **six** samples: two front-facing, two with a small yaw in one direction, then two in the opposite direction. Samples are at least 0.7 seconds apart. Exactly one face must be present; its detected width and height must each be at least 100 camera pixels. Vision capture quality must be at least 0.4. Roll/pitch and yaw are limited. Alignment residual must be at most five pixels in the 112-pixel crop. Aligned-image lighting must have mean luminance 45…210 and fewer than 30% near-clipped pixels; Laplacian variance must be at least 70.

These quality cutoffs are conservative engineering heuristics, not published SFace accuracy guarantees. Missing landmarks and low capture quality can reject obstruction, but masks, occlusion, blur, and lighting are **not** detected reliably in every situation. A valid sample must also match the first sample at the initial cosine threshold to reduce accidental identity mixing. Guidance explains how to improve a rejected sample; head-turn instructions change when turning the wrong way.

Samples are normalized individually, averaged, and normalized again. Once all six are ready, capture automatically stops. **Save Enrollment** explicitly commits one centroid; **Cancel** discards the candidate. Until Save succeeds, the previous Keychain profile remains unchanged. Cancel/close clears pending samples and the candidate from application state. While a Keychain write is pending, window dismissal is disabled; quitting waits for the operation to finish rather than interrupting it.

Verification re-reads and validates the Keychain profile before each start/retry, so a stale in-memory template does not conceal a storage failure. Verification requires three consecutive matching, distinct camera frames, at least 0.4 seconds apart. A bad-quality/multiple-face/no-face frame or session interruption resets the streak. Identity analysis is throttled to about two frames per second with late frames discarded. The attempt ends on Match, after 15 usable comparisons without a match, or at a 20-second deadline. Camera use then stops automatically; the result remains visible until dismissal. Enrollment has a 90-second deadline. There is one shared setup window/session; a second action focuses it instead of starting another session.

At most three verification starts are allowed per rolling minute, with a five-second delay after an attempt/dismissal. Limits are in-memory prototype controls and reset when the process exits; they are not a security boundary. No enrollment, unreadable storage, missing/corrupt model resources, and inference errors yield explicit unavailable/error states without a match. **Retry** rebuilds the temporary processing pipeline. Denial/unavailable camera cannot start capture; runtime errors and disconnects clear the indicator, and retries remain subject to limits.

## Local storage and permissions

The only persistent enrollment record is a normalized 128-float centroid plus schema version, model name, original weight digest, preprocessing/pipeline version, dimensions, and creation date. It is stored as a **non-synchronizing generic-password Keychain item containing enrollment data, not a password**:

- Service: `com.faceunlock.app.enrollment.v1`
- Account: `single-identity`
- Label: `FaceUnlock local face enrollment`

The store explicitly uses the classic local macOS login Keychain, which works with the existing ad-hoc signing flow without pretending to have an entitled app identity. It does not set the data-protection Keychain flag or claim `WhenUnlockedThisDeviceOnly`: Apple documents that [accessibility classes require the appropriate Keychain mode](https://developer.apple.com/documentation/security/ksecattraccessible). Protection depends on the encrypted login Keychain, its lock state, and macOS access controls. This is not Secure Enclave storage, memory zeroization, or protection from other code already authorized by the user or from system compromise. It makes no device-only backup guarantee for the classic Keychain. The app does not sync, export, or upload the record.

Replacement uses `SecItemUpdate` on the single record (or `SecItemAdd` for the first enrollment). It never deletes the previous record before saving. A failed write/delete is shown and does not report success. **Delete Enrollment…** requires confirmation and removes the item; no camera operation can run while deletion is requested. App code does not store frames, recordings, individual sample embeddings, passwords, or enrollment vectors in files, UserDefaults, logs, or this repository. Temporary frame buffers and embeddings exist only in process memory. The enable preference is the only UserDefaults setting.

Only **Camera** privacy permission is requested, after opening a temporary camera window; see [Apple's authorization guidance](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos). No microphone, Accessibility, Screen Recording, Full Disk Access, or administrator permissions are requested. macOS may also show a **Keychain access/unlock dialog**, especially after rebuilding. Enter any login-Keychain password only into macOS's own dialog; FaceUnlock never receives or stores it.

[Ad-hoc signatures have version-specific designated requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/), so a rebuild or move may prompt again for camera/Keychain access or fail access to an older item. Do not weaken Keychain ACLs to allow every application. Allow the intended build through the system dialog, use **Retry Enrollment Access**, or remove only the FaceUnlock record in Keychain Access and re-enroll if recovery is needed. Stable Apple Development/Developer ID signing is recommended for ongoing use/distribution; distribution still requires the normal signing/notarization workflow. No developer account is needed to build this local prototype.

Schema/pipeline/model metadata must match exactly. An incompatible or corrupt profile is never silently accepted, auto-migrated, or deleted; it stays in Keychain until explicit replacement or deletion. Model/landmark/preprocessing changes require a pipeline version bump and re-enrollment. Upgrades must preserve the old record until replacement saves successfully.

## Swift source map

- `Sources/FaceUnlock/FaceUnlockApp.swift`: SwiftUI entry point, menu-bar scene, shared application delegate/state.
- `Sources/FaceUnlock/AppState.swift`: existing saved Enable preference; independent of camera use.
- `Sources/FaceUnlock/MenuBarView.swift`: compact status/actions, deletion confirmation, and storage-access retry.
- `Sources/FaceUnlock/CameraController.swift`: existing AVFoundation session/permissions extended with landmarks, capture quality, distinct-frame throttling, bounded recognition work, deadlines, and clean shutdown. Queue updates are invalidated when a presentation closes.
- `Sources/FaceUnlock/CameraPreview.swift`: existing native video preview layer; no recording output.
- `Sources/FaceUnlock/EnrollmentView.swift`: temporary enrollment/verification UI, progress, Save/Cancel, error/result text, Retry.
- `Sources/FaceUnlock/EnrollmentWindowController.swift`: one shared window/camera, mode selection, rate-limit checks, atomic Save coordination, and app termination cleanup.
- `Sources/FaceUnlock/EnrollmentManager.swift` **(new)**: observable enrollment status, serial background Keychain access, and process-local attempt limiter.
- `Sources/FaceUnlock/RecognitionPipeline.swift` **(new)**: background enrollment/verification state machine, quality and pose gating, sample collection, and result transitions; accepts an injected model interface for tests.
- `Sources/FaceModel/SFaceModel.swift` **(new)**: real Core ML inference interface/implementation, resource checksum/schema validation, five-landmark alignment, lighting/blur checks, RGB tensor construction. The app never substitutes a mock if this fails.
- `Sources/RecognitionCore/Embedding.swift` **(new)**: finite-vector validation, stable L2 normalization, cosine comparison, centroid calculation, and typed errors.
- `Sources/RecognitionCore/EnrollmentProfile.swift` **(new)**: versioned profile, storage interface, and testable enrollment transaction with atomic-commit contract.
- `Sources/RecognitionCore/VerificationPolicy.swift` **(new)**: internal threshold, distinct/consecutive-frame accumulator, and attempt limits.
- `Sources/RecognitionCore/KeychainEnrollmentStore.swift` **(new)**: local Keychain load/update/add/delete; no plaintext file fallback.
- `Tools/ModelCheck/main.swift` **(new)**: camera-free, Keychain-free real-model and bitmap-orientation smoke check on synthetic non-face inputs; never prints vectors.
- `Tests/RecognitionCoreTests/RecognitionCoreTests.swift` **(new)**: normalization, metric boundaries, sample consistency, replacement/cancellation/deletion/error, corruption/versioning, and limiter unit tests.
- `Tests/RecognitionCoreTests/PipelineTests.swift` **(new)**: injected deterministic mock of the production model interface, quality gating, several-frame decisions, no-match/model-error/no-enrollment/timeout tests, and asynchronous storage-read/save/delete recovery tests. Mock embeddings exist only in test targets.

`Sources/FaceModel/Models` contains the real model, license, notice, and manifest (hashes/shapes/version/scalar conversion results, never enrollment data). `Package.swift` separates core logic and inference from the app and test tool. The existing packaging script copies model resources into `Contents/Resources/Models`, validates the plist, and ad-hoc signs the app. Packaged inference uses its own resources; it cannot fall back to a developer's `.build` folder. `.vscode` remains the VS Code workflow.

## Automated checks

From the repository root, with the Swift toolchain selected:

```sh
bash scripts/test.sh
swift run --arch arm64 ModelCheck
bash scripts/package-app.sh debug
bash scripts/package-app.sh release
bash scripts/validate-app.sh
open dist/FaceUnlock.app
```

Tests use **Swift Testing**, so use Swift 6/Xcode 16 or newer and a macOS 14+ test host with this test framework. The app itself still targets macOS 13. `scripts/test.sh` supplies the extra framework/runtime paths needed by this standalone Command Line Tools installation and disables unavailable XCTest. A linker warning about the testing framework's macOS 14 minimum is expected when testing a package whose app minimum is macOS 13; it does not change the app's deployment target. With full Xcode, `swift test --arch arm64 --disable-xctest` may work directly.

The unit suite uses test-only synthetic embeddings and an in-memory storage double; it does not write to or prove access to your real Keychain. ModelCheck runs the actual bundled pretrained model, verifies a finite 128-element output, deterministic repeated inference, and input-dependent output on synthetic non-face images. It does **not** measure identity accuracy, false accepts/rejects, or liveness. `validate-app.sh` additionally verifies signing, plist flags, executable architecture, and model loading from a temporary app bundle copied from the packaged resources, without camera or Keychain access. Disposable missing-model/corrupt-manifest copies must fail cleanly with exit status 1; these checks cannot fall back to developer resources.

## Reproduce the model conversion (optional)

The Swift app already includes the converted model. Python is needed only to rebuild/audit that conversion. The following tools were used in a project-local Python 3.9 virtual environment (Python 3.14 does not have the required matching wheels). No system Python packages were changed:

```sh
/usr/bin/python3 -m venv .model-tools
.model-tools/bin/python -m pip install -r scripts/model-requirements.txt
mkdir -p .model-work
curl -fL --retry 2 https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx -o .model-work/sface.onnx
shasum -a 256 .model-work/sface.onnx
.model-tools/bin/python scripts/convert-sface.py
```

`convert-sface.py` refuses a different source checksum. It translates only this exact ONNX graph into Core ML MIL/ML Program, preserves the inference operations, and validates actual CPU inference against ONNX Runtime on four synthetic inputs before saving. The included conversion had cosine agreement **>0.99999** and maximum absolute output error **<0.000023**. No human face test images or vectors are stored. The manifest fingerprints the converted package as sorted relative UTF-8 paths followed by NUL and file bytes. Runtime verifies this digest and the expected source/model/pipeline metadata. This detects accidental damage; it is not a substitute for code-signing trust if an attacker can replace both manifest and model.

The generated Core ML package includes a conversion/modification notice and Apache-2.0 license. Its weights are application assets, not personal enrollment embeddings. `.model-tools/` and `.model-work/` are ignored. Downloaded ONNX weights and conversion environments are not required by app users. To remove conversion tooling later, delete those two generated directories; do not delete `Sources/FaceModel/Models`.

## Manual hardware and permission tests

The user reported all eight Phase 2 manual tests passing before this change. Phase 3 live-camera identity, enrollment persistence/Keychain prompts, false matches, and hardware interruption scenarios still require testing; automated/synthetic inference checks do not establish them.

1. **Idle/no enrollment:** quit any previous build, package/open the app. Confirm one face menu-bar icon, no Dock icon, and Not Enrolled. Toggle Enable: no camera or background capture should start. Verify without enrollment: show No enrollment and leave the camera off.
2. **Camera permission:** open Enroll. On a fresh decision, allow access only through the macOS Camera prompt. To test denial, quit and optionally reset only this app's decision using the command below, reopen Enroll, and choose Don't Allow. Confirm an explanation/settings link, no crash/repeated prompt. Allow FaceUnlock under System Settings → Privacy & Security → Camera, then Retry/relaunch as required. Close while a permission dialog is pending; a late Allow must not start a closed session.
3. **Enroll/save:** alone in good light, collect two front samples, turn slightly until two more are accepted, then turn the other way. Confirm 6/6, camera stops, and no record is changed until Save Enrollment. Save, respond to any genuine macOS Keychain dialog, confirm Enrolled. Quit/reopen and verify status persists.
4. **Match:** Verify, face the camera, confirm Looking/Checking progresses to Match only after several frames. Camera use must stop with the result visible. This is not a macOS unlock and does not prove liveness.
5. **Nonmatching person and limits:** with consent, test a different person against your profile. Expect No match after usable comparisons/deadline and camera shutdown. A five-second delay applies after attempts; more than three starts/minute must be refused. A false Match is a failed prototype test; do not treat this as authentication or lower the threshold to hide failures.
6. **Quality/multiple faces:** try dark/overexposed lighting, motion blur, distance, large head turns, covered facial landmarks, and two people. Expect guidance and no accepted sample/decision from these rejected frames. Return to normal light and distance; guidance should recover. Not all obstruction/spoof cases can be detected reliably.
7. **Cancel/replace:** with a working saved profile, begin Replace, collect some/all samples, then Cancel or close before Save. Verify the old identity still matches. Complete a new replacement and explicitly Save; verify it replaces the previous record. Do not let different people alternate during collection.
8. **Shutdown/session ownership:** open Enroll, then click Verify through the menu. No second session/window should start. Close using Done/Cancel or red close button; camera-use indicators clear unless another app is using it. Quit with capture active; it must stop. Quit during a Keychain operation: finish/cancel the system prompt so the pending atomic operation can complete.
9. **Unavailable/disconnected/interrupted camera:** test an external camera unplug/reconnect, no available camera, and sleep/wake or a competing camera app. Confirm clear guidance and reset match streaks. Retry reconnects; session-interruption end can resume while the window remains open. Timeouts must stop capture even when no useful frames arrive. macOS may share cameras, so a competing app need not cause an interruption.
10. **Delete/storage failure:** cancel Delete confirmation first and verify nothing changed; then confirm Delete, relaunch, and confirm Not Enrolled. Deny an actual Keychain prompt or lock the login Keychain using Keychain Access; the app should show an error and offer Retry Enrollment Access, not report a match from unavailable storage. Unlock/allow access in the system UI and retry. Rebuild with ad-hoc signing to check the documented access-prompt behavior.
11. **Corrupt/incompatible data and missing model:** corrupt/version-mismatch handling is covered by isolated unit tests. For manual UI coverage, use a disposable enrollment and Keychain Access to change only the FaceUnlock item's data to invalid JSON; confirm restart shows an error, replacement failure/cancellation doesn't erase it, and explicit Delete recovers. Do not edit any unrelated Keychain item. For model failure, use a disposable copy of the app, remove its `Contents/Resources/Models` directory, re-sign that copy ad hoc, and open Enroll. It must report a model error without a match. Restore the normal bundle afterward. Do not reset production biometric data automatically.

Optional, user-run reset of **only this app's Camera permission**, after quitting:

```sh
tccutil reset Camera com.faceunlock.app
open dist/FaceUnlock.app
```

No Keychain item or camera decision is reset automatically by the tests or build scripts. Hardware camera indicators are shared with other applications. The current implementation has no camera selector and assumes a normally oriented macOS webcam; unusual mounting/orientation and demographic/camera-domain differences can reduce accuracy.

## Validation record

Automated validation on this Apple Silicon machine: 19 Swift Testing unit/pipeline/manager tests; real Python Core ML versus ONNX parity on four synthetic inputs; real Swift Core ML inference and pixel-orientation checks; debug/release arm64 builds and packaging; signature/plist/model-resource checks; missing-model/corrupt-manifest failure checks; and a release launch/process smoke check. No actual face enrollment, live identity result, macOS Keychain authorization/persistence, or anti-spoofing result is claimed from these checks. Full Xcode is optional for app builds with the installed working Command Line Tools; use the toolchain instructions above if your SDK differs.
