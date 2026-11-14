# FaceUnlock

A native SwiftUI menu-bar-only macOS application scaffold. Requires macOS 13 or later; the packaging script targets Apple Silicon (`arm64`). Uses `MenuBarExtra` with the SF Symbol `faceid` and a compact native popover. The packaged app has `LSUIElement = true`, so it has no Dock icon. A temporary setup window opens only when requested.

**Current safety status: a real different person was falsely accepted. Positive identity acceptance is disabled since v0.3.2 pending real-person validation; threshold passes report Inconclusive.**

Phase 3 adds one-person enrollment and live identity comparison using a genuine pretrained SFace model running locally through Core ML. Vision supplies face landmarks and quality signals; it is not the identity model. A temporary window collects six samples or performs verification, then stops capture. The menu shows enrollment status, Enroll/Replace, Verify, Delete with confirmation, Settings, and Quit.

**Prototype only: no reliable anti-spoofing and not suitable for security-critical authentication.** A photograph or screen replay may match. FaceUnlock does not unlock macOS, enter passwords, install login hooks, request administrator privileges, or modify authentication. The Enable switch remains a saved preference only and never starts a background camera session.

## v0.3.3 — developer recognition evaluation

**Positive identity acceptance remains disabled. The production threshold remains 0.363.** This release adds an opt-in measurement tool, not an authentication decision or a threshold recommendation. It does not resolve the confirmed real-person false acceptance from v0.3.2.

### Launch from VS Code or Terminal

Quit any running FaceUnlock instance before packaging or changing launch flags. In VS Code choose **Terminal → Run Task… → FaceUnlock: run recognition evaluation**. The new task packages the debug `.app` and opens it with the evaluation flag. Use this task or the bundled launch commands rather than an unbundled Swift Package F5 launch, so camera permission metadata and `LSUIElement` are present.

Equivalent commands from the repository root:

```sh
bash scripts/package-app.sh debug
open dist/FaceUnlock.app --args --recognition-evaluation
```

For a release build:

```sh
bash scripts/package-app.sh release
open dist/FaceUnlock.app --args --recognition-evaluation
```

Click the face menu-bar icon and choose **Evaluate Recognition…**. The action is absent without `--recognition-evaluation`, and the window controller also checks the flag. `open` does not replace arguments in an already-running process, so quit the previous instance first. Do not use `open -n` to create overlapping copies. Normal launch remains `open dist/FaceUnlock.app` and has no evaluation action. Existing `--recognition-diagnostics` and `--enrollment-diagnostics` flags remain independent; add them only if those separate diagnostic panels are wanted.

### Troubleshooting a missing Evaluate Recognition action

The action is implemented in `MenuBarView.swift` and connected by `FaceUnlockApp.swift` to `EnrollmentWindowController.evaluate()`, which opens the existing 15-comparison evaluation mode. Both menu visibility and the window action require the **exact** argument `--recognition-evaluation`. `--recognition-diagnostics` and `--enrollment-diagnostics` do not enable this menu action. Loading/Keychain activity or an already-open camera window disables the entry; those states do not hide it.

Investigation found two local copies: the workspace `dist/FaceUnlock.app` declared **0.3.3**, whereas `/Applications/FaceUnlock.app` declared **0.1.0** and contained a different executable. No app process was running during the initial inspection, so the precise path/arguments of the previously observed popover could not be recovered. Launching by name, Spotlight, or an old shortcut can choose the installed copy. The installed copy has not been replaced or modified. After rebuilding, the running process was verified as the workspace `dist` executable with `--recognition-evaluation`; all 53 tests and release bundle/model checks passed. Native UI inspection timed out, so the final menu click remains a manual check.

1. Quit **every running FaceUnlock copy** through its menu. Close any active camera window first. Passing `open --args` to an already-running app does not replace that process's startup arguments.
2. From the project folder, rebuild and launch the exact workspace bundle:

   ```sh
   cd /Users/muhammadabbas/Documents/FaceUnlock
   bash scripts/package-app.sh release
   open /Users/muhammadabbas/Documents/FaceUnlock/dist/FaceUnlock.app --args --recognition-evaluation
   ```

3. Click the face icon. **Evaluate Recognition…** should appear immediately below **Verify Face…**. Wait for Keychain loading to finish and close another camera window if the action is disabled. Choose it to open evaluation; no camera starts merely from launching the menu-bar app.
4. If it is still missing, inspect the running command and bundle metadata:

   ```sh
   pgrep -fl 'FaceUnlock.app/Contents/MacOS/FaceUnlock'
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Users/muhammadabbas/Documents/FaceUnlock/dist/FaceUnlock.app/Contents/Info.plist
   ```

   The process must point to the workspace `dist` executable and include `--recognition-evaluation`; metadata must report **0.3.3**. Do not use `open -a FaceUnlock`, the old Applications shortcut, or `open -n`. In VS Code use **FaceUnlock: run recognition evaluation**, after quitting the existing instance; **FaceUnlock: run app** deliberately launches without the developer flag.

This procedure does not reset enrollment or camera permissions, change Keychain data, alter the 0.363 verification threshold, or enable positive identity acceptance.

### Attempt lifecycle and privacy

Evaluation reuses the same single temporary window/camera owner as enrollment and verification. It re-reads and validates the enrolled Keychain profile, loads the existing verified SFace model, and uses the unchanged Vision, pose, face-size, capture-quality, landmark alignment, lighting, blur, RGB, tensor/output, and cosine checks. Exactly one face is required. Evaluation never enrolls, replaces, deletes, or relabels an identity and never writes a score to Keychain or UserDefaults.

One attempt collects **exactly 15 valid comparisons**. It does not stop after three threshold passes. Distinct, finite, strictly increasing capture presentation timestamps are required; accepted comparisons are at least **0.5 seconds** apart. Camera analysis is throttled to roughly two frames per second. The developer must hold the test condition constant and use one consenting participant per attempt. The optional label is just a window-local description such as “With glasses”; it is never interpreted as identity, genuine/impostor ground truth, or an accuracy label.

A **45-second** deadline starts when the camera worker begins the attempt, including model preparation/permission waiting. It excludes the preceding Keychain read. Duration uses a monotonic clock through comparison completion or termination, so it includes processing time. The capture timer also ends an attempt if no useful frames arrive. A busy framework call may delay its queued shutdown until that call returns; the deadline is not a hard real-time preemption guarantee.

On 15 valid comparisons, an error, timeout, Cancel, Done, close, or app shutdown, capture stops and queued results cannot restart the closed presentation. A timeout/failure may show **partial** statistics, explicitly distinct from a completed 15/15 evaluation. Cancel/Done/red close dismiss and discard results. Retry clears results, rejection counts, label, and custom threshold, fully stops/removes camera inputs/outputs, re-reads Keychain, creates a fresh processing pipeline and cancellation generation, resets frame counters, and starts a new capture run. Delegate callbacks from an old capture output are ignored even if they arrive after the next run starts. The shared `AVCaptureSession` object is reused after teardown; capture inputs and outputs are rebuilt. A second menu action cannot start a simultaneous camera session.

The optional label and custom threshold live only in SwiftUI state. Evaluation windows disable macOS window restoration and release their content on close. Raw images, frames, full model inputs, embeddings, templates, and biometric-derived scores are never logged, recorded, uploaded, exported or written to disk by this feature. At most 15 scores and bounded scalar rejection/streak events are held in process memory; the camera/view references are cleared on close. This is application-level disposal, not a claim of secure memory zeroization. There is no result history or export action. Normal verification's five-second retry delay and three-attempts-per-minute limiter are unchanged; evaluation uses its separate bounded, explicitly started attempt lifecycle and does not consume or reset that limiter.

### Statistics and experimental thresholds

The window contains a live preview, 0/15→15/15 progress, current quality/status guidance, latest comparison score, statistics, experimental threshold analysis, and a pinned Cancel/Retry/Done footer. Content scrolls vertically in a resizable 420…560-point-wide window; text wraps. Completed capture is visibly marked stopped. Additional threshold inspection is local to the current evaluation and never writes to `VerificationPolicy`.

Statistics include min, max, arithmetic mean, median, **population** standard deviation (`sqrt(sum((x−mean)^2)/N)`), valid count, rejected analyzed-frame count, rejection-reason counts, and duration. Even-size partial medians average the two middle sorted values; zero valid comparisons have no similarity statistics rather than fabricated zero similarity. The final duration stays fixed after capture stops.

“Rejected frames” means frames actually analyzed at the throttled cadence that failed freshness, timing, or quality/recognition gates. Higher-rate camera frames skipped only for sampling cadence are not counted as quality rejections. A session interruption is a sequence break, not a rejected camera frame. Fatal failure before a frame exists (for example camera denial or model load failure) has no rejected-frame count; the main status shows the error. Failed analyzed frames and their reasons are counted without accepting a comparison.

Candidates **0.363**, **0.500**, **0.600**, and **0.700** show `score >= threshold` count, percentage of valid comparisons passing, and whether any three consecutive comparisons in that attempt would have passed. Rejected analyzed frames, interruptions and gaps over two seconds break the hypothetical streak. Earlier three-pass runs remain counted even if a later rejection occurs, because ordinary verification would already have ended at that earlier point. With zero comparisons the percentage is displayed as unavailable. These percentages are not probabilities, accuracy, confidence, or false-accept rates; nearby video frames are correlated.

Use **Inspect another experimental threshold** to enter one finite value in **[−1,1]** using a decimal point, then click Inspect or press Return in that field. The custom candidate is added to the comparison list (duplicates are merged); inspecting another value replaces that custom candidate. Invalid/NaN/infinite values show an error. All results are labeled **Experimental — not an authentication decision**. Nothing automatically selects a cutoff or re-enables acceptance. Normal Verify still ends as **Inconclusive** after three threshold passes, as No match after its normal comparison/deadline limits, or with an error; its behavior has not been replaced by evaluation.

### Files and architecture

New files:

- `Sources/RecognitionCore/RecognitionEvaluation.swift`: transient score/event accumulator, exact 15-comparison completion, timing/freshness guards, statistical summaries, and pure experimental threshold simulation. Types intentionally have no Codable/storage/export interface.
- `Sources/FaceUnlock/EvaluationView.swift`: temporary evaluation UI and reusable results summary; window-local label and custom threshold; no identity inference from labels.
- `Sources/FaceUnlock/DeveloperFeatures.swift`: explicit command-line gate for the action and window.
- `Tests/RecognitionCoreTests/RecognitionEvaluationTests.swift`: statistics, threshold boundaries/counts, sequence breaks, cadence, timestamps, timeout/failure and fresh-state tests.
- `Tests/RecognitionCoreTests/EvaluationPipelineTests.swift`: real pipeline interface with test-only model doubles; 15/15 completion, rejection/error handling, missing/corrupt enrollment, unchanged Verify decisions, retry/cancellation and idle camera cleanup.
- `Tests/RecognitionCoreTests/EvaluationLayoutTests.swift`: camera-free light/dark evaluation/results layout checks using synthetic scores and test-only storage.

Modified files: `RecognitionPipeline.swift` adds an isolated evaluate mode after the shared quality/model path; `CameraController.swift` publishes transient evaluation snapshots and tears down on terminal outcomes; `EnrollmentWindowController.swift` owns the third mode in its existing one-window lifecycle; `MenuBarView.swift` and `FaceUnlockApp.swift` connect the gated action; `.vscode/tasks.json` supplies the bundled debug launch task; `Resources/Info.plist` becomes version **0.3.3**, build **6**; this README documents operation and limits. The model asset bytes, preprocessing version, Keychain schema, enrollment transaction, production verification policy, normal rate limits, camera privacy description, LSUIElement, and packaging script remain unchanged.

### Automated validation

Run the requested checks from the repository root:

```sh
bash scripts/test.sh
swift run --arch arm64 ModelCheck
bash scripts/package-app.sh debug
bash scripts/package-app.sh release
bash scripts/validate-app.sh
```

All five commands above passed on this Apple Silicon machine. The packaged release also launched successfully with the evaluation flag, and macOS reported accessory activation policy (no Dock application icon). `LSUIElement`, camera metadata, arm64 architecture, signature and bundled real model validation passed.

The suite now contains **53 tests**, including every previous regression and the new evaluation statistics/pipeline/layout tests. Pure statistics tests use known synthetic values (including negative cosine values and odd/even median cases). Test-only model embeddings never substitute for production inference. The real checkpoint is exercised separately by ModelCheck and the packaged-resource validator using synthetic **non-face** inputs. Those checks establish numerical execution/resource integrity, not identity accuracy or calibration.

Camera-free synthetic light/dark layouts were rendered and visually inspected at 420-point width. At minimum window height the content is scrollable and Cancel/Retry/Done remain visible. Completed/partial summary labels, threshold rows, custom candidate and non-authentication warnings were inspected. Optional regeneration uses **synthetic test data only**, briefly shows test windows, and never captures a webcam:

```sh
FACEUNLOCK_EVALUATION_LAYOUT_SNAPSHOTS=/tmp/faceunlock-v033-layout bash scripts/test.sh
```

Live 15-frame completion, the actual camera indicator clearing, permission/disconnection/sleep behavior, real Keychain prompts, menu-bar icon interactions/visual appearance, labels and field interactions, and scores for real participants still require on-device verification. Empty-session shutdown tests are not claimed as active-camera hardware tests. No people's images or evaluation scores were gathered for automated validation.

### Manual MacBook test plan

1. Quit any previous build; launch with the evaluation flag. Confirm one `faceid` menu icon, no Dock icon, the new action only with the flag, and a compact menu. On a normal launch confirm Evaluate Recognition is absent. Choose Evaluate without enrollment or with denied/unreadable Keychain access: show a clear error and do not start capture.
2. With enrollment available, establish the condition **before** opening Evaluate. Choose a neutral optional label. In good light, hold still; confirm 1/15 through 15/15, continued collection past three threshold passes, and no authentication success message. The camera must stop at completion. Inspect statistics and expand rejected reasons. Do not interpret a high pass fraction as verified identity.
3. Try the four candidates and an additional value (such as 0.65). Confirm the displayed candidate counts/percentages change without modifying 0.363, enrollment or normal Verify. Invalid values should show an error. No export/save action should exist.
4. Use Retry for each new condition/person: confirm 0/15, empty label/custom field, empty prior results and fresh capture counters before new comparisons arrive. Test the enrolled person with/without glasses, different light, slight angles within existing pose limits, and distances large enough to pass the existing face-size gate. For different participants obtain consent and use a separate attempt; the label does not define ground truth. Keep the condition stable for each attempt. Results exist only in the current window; there is no cross-attempt history.
5. Obscure/blur/darken the view, move too far away or include two faces. Valid count must not increase from rejected frames, latest score must clear, and rejection reasons/counts must update. Restore a valid condition to resume. Keep the view unusable long enough to reach the 45-second deadline; confirm partial, not completed, results and camera shutdown.
6. Cancel, Done, red close, unplug a USB camera, and quit during collection. Confirm capture stops, no result/profile is saved and no closed window restarts after a permission reply. Reopen: there must be no previous scores/label. A model/device failure should stop the attempt with a clear error/partial state. Test closing during a Keychain read; any later read completion must not open a camera.
7. Try other menu camera actions while the window is open: no overlapping capture may start. Close evaluation and verify normal enrollment, replacement cancellation, confirmed deletion and Verify still work as before. Normal Verify must retain its existing retry limits and Inconclusive result for threshold passes.
8. Resize to minimum width/height in both macOS light and dark appearance. Scroll to all statistics/threshold controls, verify no horizontal scrolling or ellipsized status text, and confirm Cancel/Retry/Done remain reachable.

Known limitations: one active attempt only; no saved datasets, export, participant identity/ground-truth inference, threshold recommendation, cross-condition comparison history, or reliable anti-spoofing. Fifteen correlated frames and a few participants cannot establish security or a false-accept rate. The prior real-person false acceptance remains unresolved; use this feature to inspect behavior while all positive identity authentication remains disabled.

## v0.3.2 — confirmed false acceptance; identity acceptance disabled (historical audit)

The user confirmed that their enrolled face **and another real person** both received Match in **separate verification attempts**. This is a genuine false acceptance, not explained by re-reading the first completed result. **The live root cause remains unresolved. Do not use this system for authentication.** No consented face-image test set was supplied for this investigation, and no personal images were downloaded, collected, saved, or used by the automated checks.

The release deliberately fails closed: a sequence of three threshold passes ends with **Inconclusive**, never a positive identity Match. No command-line flag re-enables positive acceptance. The 0.363 threshold remains unchanged for diagnostic comparison and sample-consistency checks; it has not been increased to conceal the failure. Below-threshold attempts still end as No match, and model/profile/quality errors never produce an identity acceptance. Enrollment, encrypted local Keychain protection, explicit atomic Save/Cancel, confirmed deletion, and camera lifecycle remain available.

### End-to-end audit and demonstrated findings

- The live path uses the current `CMSampleBuffer` pixel buffer. There is no stored enrollment photo and no production mock. Only the loaded `MLModel` is cached; new RGB tensors, prediction calls, and copied output vectors are created per evaluated frame. A test changes the contents of the same pixel-buffer object and observes the changed comparison score on every call. This verifies the code path with a test-only model, not the behavior of real people.
- Enrollment individually L2-normalizes six accepted real-model outputs, averages them, and normalizes the centroid. Cosine comparison re-normalizes both operands and uses a bounded dot product. The threshold direction is `score >= 0.363`; equality passes. No reversed sign, probability conversion, or centroid arithmetic error was found.
- A **calibration mismatch** is established: [OpenCV's published SFace threshold](https://docs.opencv.org/4.12.0/d0/dd4/tutorial_dnn_face.html) is used for pair comparisons, while this app uses a six-sample centroid and Vision-derived alignment. A synthetic geometry counterexample passes the existing enrollment-consistency gate: each sample has cosine **0.34000000** to a test direction, yet the normalized centroid has cosine **0.47671880**. Thus averaging can move a comparison across 0.363 with perfectly correct cosine code. These are test vectors, not people; this does **not** establish that centroid calibration caused the reported live false acceptance, nor justify choosing 0.48 or any other replacement threshold.
- [OpenCV preprocessing](https://github.com/opencv/opencv/blob/4.x/modules/objdetect/src/face_recognize.cpp) uses five-point alignment to 112×112 and RGB input at unscaled 0…255 before the graph's internal normalization. The app retains these canonical points, unmirrored upright inference, lower-left landmark coordinates, and top-to-bottom planar RGB. Eye centers, nose-crest endpoint, and mouth corners remain Vision-derived approximations, not a claim of equivalence to YuNet landmarks or exact OpenCV resampling. Synthetic tests verify coordinate conversion, nonreflecting transform geometry, channel order, row order, and byte scale. They cannot validate landmark placement on actual faces.
- Alignment now explicitly rejects invalid anatomical point ordering, degenerate/nonfinite geometry, and a transformed crop extending beyond the camera image rather than padding an unsupported partial crop. Point conversion now accounts for a nonzero image-extent origin (ordinary camera buffers start at zero). The tested transform for valid, origin-zero crops is unchanged. Existing illumination, blur, capture-quality, pose, and alignment-residual cutoffs are not loosened.
- The old model boundary accepted any output with 128 elements. It now requires **float32 [1,128]**, a present multi-array feature, finite/nonzero data, and exact input shape/type and Core ML version metadata. Wrong shapes such as [2,64], doubles, strings, missing outputs, zero outputs, and NaNs fail closed. RGB input is exactly float32 [1,3,112,112], finite and in 0…255, with no second normalization. Model files, source digest, package fingerprint, model version and preprocessing version checks remain enforced. The real checkpoint passes these stricter checks.
- Verification still re-reads Keychain on every attempt/retry. Profiles are validated before inference, so corrupt templates and incompatible model/pipeline metadata cannot be used. No profile was deleted, replaced, or silently migrated by this investigation. Model and valid-crop preprocessing identity remain version 1 because this change adds guards and extraction tests without changing the valid input mapping or weights; previously enrolled data remains readable but is not trusted for positive acceptance.
- Freshness is checked at both capture and pipeline boundaries using strictly increasing **capture presentation timestamps**, not buffer-object identity or embedding hashes. Repeated, out-of-order, or invalid frame timestamps cannot invoke inference or advance the streak. Nonmatch and quality rejection reset the streak; gaps longer than two seconds reset it too. Duplicate/backward/nonfinite comparison timestamps reset the accumulator. Distinct frames remain at least 0.4 seconds apart; the normal camera analysis throttle is about 0.5 seconds.
- A completed attempt is terminal. The UI now overlays **Camera stopped** and says the result belongs to that completed attempt; Retry creates a fresh processing pipeline and clears prior diagnostics before re-reading Keychain. This addresses a misleading stale-result presentation, but **does not explain the user's separate-attempt false acceptance**.

### Developer-only recognition diagnostics

Quit the running app first, then:

```sh
bash scripts/package-app.sh release
open dist/FaceUnlock.app --args --recognition-diagnostics
```

Open **Verify Face…**, then expand **Recognition diagnostics — not identity probabilities**. Normal launches have no recognition-score panel. The flag exposes no passwords, templates, vector hashes, full inputs, images, or positive-acceptance override.

For each evaluated frame the panel updates the current cosine score, unchanged threshold, threshold-pass Boolean, consecutive pass count, evaluated-frame count, fresh-frame status/capture timestamp, model/preprocessing versions, and rejection/error reason. A rejected frame clears the prior score rather than showing a stale successful score. A completed result remains visible as explicitly stopped, not live. Only the current scalar snapshot is held in memory; there is no history, file/console logging of live scores, telemetry upload, recording, or embedding export. Closing/Retry clears the snapshot. An error before a frame can be evaluated is shown as the main error with no stale score. Scores are **not identity probabilities**.

The existing `--enrollment-diagnostics` flag remains independent and unchanged; both flags may be supplied if needed. No camera starts until its temporary window is opened.

### Numerical evidence and test limits

The original ONNX checkpoint on two deterministic synthetic non-face inputs produced cosine **−0.03143172**, with finite, normalized outputs. The Swift/Core ML path on the same generated inputs produced cosine **−0.03143212**, repeat-input cosine **1.00000000**, and output unit norm **1.00000000**. The actual different model outputs produce No match through the comparison accumulator. These figures show input dependence and numeric agreement on **non-face inputs only**, not same/different-person separation. The earlier four-fixture Core ML/ONNX parity report remains unchanged. No accuracy, false-accept rate, or fairness claim is made from these tests.

The expanded suite has **40 tests** covering metric/threshold boundaries, actual changed-buffer routing through a test-only model, several consecutive threshold passes, nonmatch/quality/gap resets, capture freshness, terminal attempts/retries, stale/corrupt profiles, malformed outputs, centroid calibration counterexample, alignment/RGB contracts, storage replacement/deletion, cancellation/shutdown, and diagnostic layout. Existing mock models remain only in test targets. Active-camera shutdown, real-person discrimination and real Keychain authorization remain hardware/manual tests.

### On-device retest and threshold selection

1. Keep your current enrollment initially. Launch with the recognition flag, open Verify, and read the warning that identity acceptance is disabled. In good light, test your own face; inspect changing capture timestamps/evaluation count, scalar score, threshold pass and streak. Three passes must end **Inconclusive** with camera off, not Match.
2. Use **Retry or close/reopen Verify for every person/attempt**. Respect the five-second retry delay and three-attempts-per-minute limit. With a consenting other participant, repeat under similar conditions and inspect whether scores stay below the threshold. If both people still pass, that is continued evidence of unreliable discrimination even though the app now refuses positive acceptance. Do not lower quality gates or choose a new cutoff from these two subjects.
3. Check no-face/multiple-face/poor lighting/blur/pose rejection: the current score must clear and streak must reset. Disconnect the camera, cancel, retry, and quit: no prior result should become a fresh comparison, no candidate should be committed, and capture must stop. These live checks are not replaced by the empty-session shutdown unit test.
4. If investigating enrollment quality, explicitly replace your profile only after inspecting enrollment diagnostics. Cancel must preserve the old profile; Save commits only a completed replacement. No enrollment was reset automatically. Re-enrollment alone is not proof that the false acceptance is fixed.
5. The current task supplies no authorized local image dataset. If you later explicitly provide consented same-person images across lighting/angles and images of other consenting people, evaluate them locally through this same preprocessing/model path. Do not download strangers' face photos or silently gather camera images. Do not save or export templates/model inputs while investigating.
6. Before considering any positive acceptance, freeze model, landmark/alignment, capture domain, and centroid construction. Use a consented calibration set with multiple identities and conditions, split by identity/session from a separate held-out evaluation set; use each participant's enrollment separately from their probes. Examine genuine and impostor **attempt-level** score distributions, not correlated video frames as independent trials. Select a conservative threshold on calibration data according to a stated false-accept/false-reject objective, then evaluate that fixed choice on held-out identities/sessions. If distributions overlap too much or data is insufficient, report that limitation and leave acceptance disabled. One or two subjects and synthetic tensors cannot establish a safe threshold or false-accept rate. No new threshold is recommended in this release.

Changed/new files: `RecognitionPipeline.swift`, `VerificationPolicy.swift`, `FreshFrameGate.swift` (new), `CameraController.swift`, `SFaceModel.swift`, `SFaceTensorContract.swift` (new), `FaceAlignment.swift` (new), `RecognitionDiagnostics.swift` and `RecognitionDiagnosticsView.swift` (new), `EnrollmentView.swift`, `MenuBarView.swift`, the regression/layout tests, `Tools/ModelCheck/main.swift`, version metadata, and this README. Keychain storage format, model asset bytes, menu-bar-only architecture, LSUIElement, permissions and packaging flow remain intact. No unlocking, password entry, login hooks, administrator privileges, commits or pushes are implemented.

Validation commands:

```sh
bash scripts/test.sh
swift run --arch arm64 ModelCheck
bash scripts/package-app.sh debug
bash scripts/package-app.sh release
bash scripts/validate-app.sh
```

## v0.3.1 — enrollment stall investigation and layout (historical)

Confirmed code defect: the old pipeline read `face.yaw?.doubleValue ?? 0` from landmark observations. Missing yaw therefore passed the first two front-facing samples as zero, but could never enter either side range. Repeated missing measurements reproduced the permanent 2/6 state until timeout. The capture path only requested landmarks, while [Apple documents yaw on face-detection observations, in radians, and permits nil when not computed](https://developer.apple.com/documentation/vision/vnfaceobservation/yaw). v0.3.1 explicitly runs revision-3 face detection, passes those observations into landmarks, and transports the detector's pose separately to the pipeline. Missing yaw is now reported as unavailable and never counted as a validated front or side pose.

The suspected contradictory global/side yaw limits are **not present**: positive side samples require 0.1…0.3 radians (5.73…17.19°), negative samples −0.3…−0.1, all inside the unchanged global limit ±0.35 radians (20.05°). Regression tests exercise both signed boundaries and 0/6→6/6. Both global limits and side ranges are now defined in one tested policy. Radians are used for gating; degrees are display-only. Capture remains unmirrored and `.up` for normally oriented macOS webcams; the preview alone is mirrored. No yaw-sign flip is applied based on preview mirroring. Guidance uses “one side / other side” rather than guessing the person's left/right from screen coordinates.

**The exact runtime cause on the reported MacBook is not yet confirmed.** We reproduced the missing-yaw failure, not the user's camera measurements. Coarse/unchanging yaw (for example 0 and ±π/4), insufficient capture quality, alignment residual, blur, lighting, or identity rejection could independently prevent progression. A synthetic coarse-yaw test demonstrates why enlarging a side range alone cannot solve that case without violating the global limit. This release does not assert that Apple always quantizes yaw, nor claim that live enrollment is fixed from passing tests alone. There was no code evidence of a global-range contradiction, angle conversion, preview-sign flip, sample-counter race, or timestamp deadlock. Existing 0.5-second analysis throttling and 0.7-second sample spacing deliberately accept at most roughly one enrollment sample per second.

The normal UI now shows accepted count, stage, and contextual rejection guidance. Scalar model-quality telemetry reports alignment RMS, brightness/clipping, and blur variance for the current evaluated frame only. It does not change the SFace model, alignment algorithm, thresholds, embedding metadata, or Keychain storage format. Identity similarity remains 0.363; capture quality remains 0.4; all other quality limits are preserved.

If a single good-quality face has no yaw, or repeatedly fails pose checks (six analyzed frames since the last acceptance), **Use guided samples with unvalidated turns…** becomes available. This is an explicit, confirmed fallback, not an automatic claim that head movement was verified. Confirming restarts all six samples and labels the flow and completion result **head turns NOT validated**. Vary pose naturally. Global pose limits when measured, exactly-one-face, size, quality, landmarks/alignment, lighting, blur, real-model inference, and same-identity checks still apply. Retry remains in the chosen mode until the window closes; reopening starts with validated turns again. Cancelling or declining fallback never changes the saved profile. Use this only when the diagnostic readings cannot validate small turns on your hardware; it is not a liveness check.

The window is resizable from 420 points wide (maximum 560), starts within the screen's visible height, and has a vertically scrolling content region with wrapping labels. Action buttons sit outside the scroll view so they remain visible at the minimum 420-point content height. The preview is 220 points high. A camera-free test rendered and visually inspected light/dark layouts at 420×460 with a long status message: text wraps and Retry/Cancel remain visible. Content below the viewport is reached by vertical scrolling, not ellipsized labels or horizontal scrolling. Actual camera preview, expanded diagnostics, Save/permission-dialog combinations, and your system's accessibility/text settings still need manual inspection.

Changed files in this release:

- `RecognitionPipeline.swift`: explicit pose input, missing-pose rejection, stage diagnostics, contextual reasons, and explicit guided-sample mode.
- `EnrollmentPosePolicy.swift` (new): centralized radians/ranges, stages, degree conversion, and pose guidance.
- `CameraController.swift`: rectangle→landmark→quality requests, separate detector pose, current-frame diagnostics, explicit unmirrored capture.
- `CameraCoordinates.swift` (new) and `CameraPreview.swift`: shared, tested capture/preview orientation convention.
- `SFaceModel.swift`: transient scalar quality metrics, without changing inference or quality cutoffs.
- `EnrollmentDiagnostics.swift` (new): transient diagnostic snapshot; no vectors, images, profile data, logs, or persistence.
- `EnrollmentView.swift` and `EnrollmentWindowController.swift`: wrapping/scrolling, pinned footer, resizable screen-aware sizing, explicit fallback confirmation/restart, developer disclosure.
- `EnrollmentRegressionTests.swift` and `EnrollmentLayoutTests.swift` (new): pose/state/fallback/quality/identity/shutdown regressions and light/dark minimum-size layout checks.
- `Resources/Info.plist`: version 0.3.1, build 4; camera description and `LSUIElement` preserved. `README.md`: this investigation and testing guide. Packaging/model assets, secure storage, deletion confirmation, and verification thresholds remain unchanged.

### Developer diagnostics and MacBook retest

Quit the previous app first. Do not use `-n` to run simultaneous copies. Build and launch with the developer-only flag:

```sh
bash scripts/package-app.sh release
open dist/FaceUnlock.app --args --enrollment-diagnostics
```

Open Enroll/Replace, then expand **Developer diagnostics — transient, not logged**. This section is absent on normal launches and collapsed initially even with the flag. It displays the stage, accepted count, yaw/pitch/roll degrees, expected yaw range, latest rejection, capture quality, face size, alignment/brightness/clipping/blur metrics, processed-frame counter, time since the last analyzed frame, and whether capture is active. “—” means unavailable or not evaluated on that frame. Nothing is written to disk or the console. Do not share camera imagery or enrollment vectors when reporting a problem.

1. In good light, accept the two front samples. Slowly turn one way; reverse if the guidance says the other side. Watch the **raw signed yaw**, expected range, latest rejection, and advancing frame count. A valid pose in the expected range must still pass all quality/identity checks before the count increases. Then turn the opposite way for samples 5–6.
2. If yaw stays at zero, becomes unavailable, or jumps outside the global limit, note that scalar observation and the rejection text. Do not increase pose or identity thresholds. Try explicit guided mode only if pose validation remains unusable; confirm its restart at 0/6, persistent unvalidated-turn warning, and eventual 6/6 quality samples. If quality/alignment/blur is failing instead, correct that condition rather than using fallback to bypass it (fallback cannot do so).
3. Expand diagnostics while resizing to minimum size, in both system light and dark appearances. Scroll through all text; verify no ellipses, no horizontal scroll, and that Cancel, Retry, Camera Settings (after denial), and Save Enrollment (after completion) remain reachable. Test closing/cancelling at 2/6 and at 6/6 without Save: old enrollment must remain intact. Then explicitly save a replacement and run Match/nonmatch tests.
4. Unplug a USB camera, deny camera access, and close/quit during capture. Confirm the camera-use indicator clears, no sample/candidate is committed after an error, and the old enrollment remains. Automated shutdown checks exercise an empty session plus pipeline terminal-error results; they do not replace these active-hardware tests.

Normal launch without diagnostics, after quitting the diagnostic instance:

```sh
open dist/FaceUnlock.app
```

Regression commands (the optional snapshot command uses only an empty preview/test storage and briefly shows a test window; it captures no webcam images):

```sh
bash scripts/test.sh
FACEUNLOCK_LAYOUT_SNAPSHOTS=/tmp/faceunlock-v031-layout bash scripts/test.sh
bash scripts/package-app.sh debug
bash scripts/package-app.sh release
bash scripts/validate-app.sh
```

The suite now has **29 tests**. Existing replacement/cancellation/deletion tests remain in place alongside the new regressions. Core ML model parity and packaged-resource checks remain separate from deterministic model mocks used only in unit tests. Live confirmation on the MacBook is still required. Native app automation timed out during the final menu-bar inspection; the release launch/process check succeeded, but clicking the menu-bar icon and checking a live preview remain manual tests.

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

Verification re-reads and validates the Keychain profile before each start/retry, so a stale in-memory template does not conceal a storage failure. Diagnostic verification requires three consecutive threshold-passing, distinct camera frames, at least 0.4 seconds apart. A bad-quality/multiple-face/no-face frame or session interruption resets the streak. Identity analysis is throttled to about two frames per second with late frames discarded. The attempt ends as Inconclusive on three threshold passes (positive acceptance disabled), after 15 usable comparisons without three passes as No match, or at a 20-second deadline. Camera use then stops automatically; the result remains visible until dismissal. Enrollment has a 90-second deadline. There is one shared setup window/session; a second action focuses it instead of starting another session.

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
4. **Diagnostic threshold passes:** Verify, face the camera, confirm Looking/Checking progresses to Inconclusive after three passes; positive Match is disabled. Camera use must stop with the result visible. This is not a macOS unlock and does not prove liveness.
5. **Nonmatching person and limits:** with consent, test a different person against your profile. Expect No match after usable comparisons/deadline and camera shutdown. A five-second delay applies after attempts; more than three starts/minute must be refused. If the different person also produces three threshold passes, the discrimination test has failed even though the result is now Inconclusive; do not treat this as authentication or lower the threshold to hide failures.
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

Automated validation on this Apple Silicon machine: 53 Swift Testing unit/pipeline/manager/layout tests; real Python Core ML versus ONNX parity on four synthetic inputs; real Swift Core ML inference and pixel-orientation checks; debug/release arm64 builds and packaging; signature/plist/model-resource checks; missing-model/corrupt-manifest failure checks; and a release launch/process smoke check. No actual face enrollment, live identity result, macOS Keychain authorization/persistence, or anti-spoofing result is claimed from these checks. Full Xcode is optional for app builds with the installed working Command Line Tools; use the toolchain instructions above if your SDK differs.
