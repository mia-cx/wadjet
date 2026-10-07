# Permissions, signing, and project setup

Research for [#5](https://github.com/mia-cx/wadjet/issues/5), checked 2026-10-07. Recommendations below are engineering judgments; linked documentation and source establish the underlying behavior.

## Short answer

Use a native Xcode macOS app target, macOS 26 deployment target, an unsandboxed app, and stable Apple Development signing. Keep the bundle ID and signing certificate identity consistent across builds. Ad-hoc signing binds identity to a particular build, which makes remembered privacy permissions unreliable. Paid membership and notarization are unnecessary for this private development setup. [1][2][3][4]

Use ScreenCaptureKit for Captures and KeyboardShortcuts for Workflow hotkeys. Standard hotkey registration needs neither Accessibility nor Input Monitoring consent. Request Screen Recording for Wadjet's custom Freeze Frame selection; request microphone access only for a Recording that uses it. [5][6][7]

The Mac already has a valid Apple Development identity. Start with that certificate rather than creating another. Its team ID is `VJKBGC9AMK`, read from the certificate's OU field. The suffix in its display name is not the team ID. See the local inspection below.

## Why permission disappears after rebuilding

TCC records a code requirement identifying the authorized app. New code must satisfy that requirement. An ad-hoc signature's designated requirement (DR) is specific to that version, commonly expressed using its cdhash. A changed binary changes that hash. Keeping just the same app name, bundle ID, or path does not solve this. [1]

Certificate signing permits a DR that survives code changes. Keep the signing identifier, certificate identity, and signing method consistent. Apple Development and Developer ID builds have different default requirements, so switching channels can require fresh consent. Certificate changes deserve a DR comparison too. [1]

Quinn explicitly recommends Development signing over Xcode's “Sign to Run Locally” when debugging TCC. He also explains that permission attribution depends on the responsible app process. Run the actual `.app`, with a native executable, rather than a shell launcher or loose `swift run` executable. [2]

Recommendation: choose `cx.mia.wadjet` once, use one stable development output location, and quit the old process before replacing its bundle. Keep daily-use and experimental builds distinct if both must run simultaneously. These are operational choices, not a claim that TCC keys solely on path. [1][2]

## Signing choices

| Choice | What it provides | Decision |
| --- | --- | --- |
| Ad-hoc / Sign to Run Locally | Local execution, without a durable certificate-based identity across changed code. [1] | Fine for compile-only checks; avoid for permission-bearing development. |
| Apple Development through a free Apple Account | Xcode Personal Team development signing and local testing. Limited capabilities; no Developer ID distribution or notarization. [3][4] | Enough for this private app without restricted capabilities. |
| Paid Apple Developer Program | Development signing plus distribution resources, including Developer ID and notarization. [3][4] | Defer until distributing downloadable binaries or needing paid capabilities. |

Apple documents seven-day Personal Team provisioning limits. Do not generalize that into “every Mac app expires after seven days.” macOS can run third-party code without a provisioning profile; profiles become necessary for restricted entitlements. Avoid adding those capabilities to the initial app. The existing certificate expires in July 2027, independently of any profile lifetime. [3][8]

A valid Apple Development certificate does not prove whether this Apple Account has paid membership. No account enrollment status was inspected. Developer ID and notarization concern distribution trust; they do not grant Screen Recording or Accessibility consent. [3][4][5]

## Screen Recording on macOS 26 and 27

There are separate authorization paths:

| Path | Consent model | Fit for Wadjet |
| --- | --- | --- |
| Custom selection with ScreenCaptureKit | The app obtains Screen Recording permission. Apple's sample documents initial consent and an app restart. [5] | Required for taking a Freeze Frame before Wadjet presents its own region/window selection. |
| `SCContentSharingPicker` | Explicit system selection authorizes selected content for the capture session, without a separate broad Screen Recording grant. [9] | Useful for an optional system-selected Recording; it changes the instant custom selection interaction. |

The picker is available since macOS 14. macOS 26 is not its introduction. Its authorization is session scoped, not a permanent grant for arbitrary future Captures. Apple recommends it when the system's selection interaction suits the app. [9]

Apple's macOS 15 release notes warn that deprecated capture APIs can produce additional awareness alerts. The 15.1 notes say alert frequency varies with acknowledged, regular use. Use ScreenCaptureKit rather than `CGDisplayStream` or `CGWindowListCreateImage`. This does not establish that every non-picker ScreenCaptureKit path avoids renewed consent. [10][11]

**Periodic prompts remain an open behavior to validate.** The screeny2 capture app's own plan explicitly handles monthly Sequoia reauthorization. That is an upstream app's report, not an Apple guarantee of a 30-day timer. Apple's release notes describe adaptive alert policies, and the macOS 26/27 notes reviewed do not specify a fixed recurring schedule. Do not promise “once forever,” “exactly monthly,” or “fixed by notarization.” Handle capture authorization errors even after a successful preflight. [11][12][13][14]

`com.apple.developer.persistent-content-capture` is an Apple-approved entitlement for VNC apps. It is not an unrestricted switch for a screenshot utility. Do not request it for Wadjet or build around Remote Desktop permission. [15]

For a passive permission check, use `CGPreflightScreenCaptureAccess()`. The Xcode 27 SDK header explicitly says it does not prompt. `CGRequestScreenCaptureAccess()` is the request path; a previously denied process needs the user to enable access in System Settings. Quinn confirms the API roles. Do not enumerate `SCShareableContent` as a supposedly passive permission probe. [16]

The SDK inspected also exposes macOS 26 screenshot configuration/output APIs in `SCScreenshotManager.h`. Their availability does not itself guarantee a new permission model. Validate the actual screenshot and `SCStream` paths separately. [17]

## Sandbox and minimum permissions

Recommendation: start unsandboxed. This is a private tool with user-configured file outputs and Destinations. App Sandbox is required for Mac App Store submission, but is separate from TCC. Removing it does not remove privacy consent. [6][18]

A sandboxed capture app is possible. KeyboardShortcuts supports sandboxing, and sandboxed file output can use panels and persistent security-scoped bookmarks. Uploads need outgoing network access. That adds file-access bookkeeping; unrestricted user workflows may need a later scope review. [6][18][19]

| Resource | Initial policy |
| --- | --- |
| Screen Recording | Ask when the user first invokes a custom Capture. Support denial, revocation, and restart where required. [5][16] |
| Accessibility / Input Monitoring | Do not require for Carbon hotkeys. Add only when a concrete feature needs broader event observation or automation. [6][20] |
| Microphone | Ask only when enabled for a Recording. Include `NSMicrophoneUsageDescription` and the appropriate audio-input entitlement for the capture/runtime configuration. [7] |
| Camera | No permission or entitlement until a camera feature exists. [7] |
| Protected save locations | Handle file-access failures. Unsandboxed apps still encounter Files and Folders protection; user selection is preferable to asking for Full Disk Access. [2][19] |

System audio and microphone are distinct. ScreenCaptureKit supports system audio; `NSAudioCaptureUsageDescription` documents Core Audio tap capture. Do not assume that key alone replaces Screen Recording authorization for a video stream. Follow the actual selected API's requirements. [5][21]

For baseline screen-only capture, omit App Sandbox and persistent-content-capture entitlements. Hardened Runtime is compatible with this setup. Add `com.apple.security.device.audio-input` when microphone recording lands; notarization is not needed to test privately. Azayaka and QuickRecorder demonstrate development-signed, hardened capture app targets without an App Sandbox entitlement. [22][23]

## Global hotkeys and replacing Apple's shortcuts

KeyboardShortcuts wraps Carbon `RegisterEventHotKey`, supports key down/up, and reports registration failure. Its source uses `CopySymbolicHotKeys` to detect enabled system shortcuts. Adopt the package through Xcode's Swift package integration and pin its resolution. [6][24]

| Mechanism | Tradeoff |
| --- | --- |
| Carbon via KeyboardShortcuts | Registers specific combinations; no consent dialogs. Best initial choice. [6][24] |
| `NSEvent.addGlobalMonitorForEvents` | Observes events in other apps, cannot consume them, and needs Accessibility trust for keyboard events. It cannot suppress Apple's screenshot command. [20] |
| Local AppKit events / SwiftUI shortcuts | Handle Wadjet's focused UI, including its selection overlay; not a global Workflow trigger. [25] |
| Lower-level event taps | Broader interception machinery. Defer until a feature needs it; do not introduce it just to register a hotkey. [6] |

Apple owns ⌘⇧3, ⌘⇧4, and ⌘⇧5 by default. For reliable replacement, Mia must disable or remap them under System Settings > Keyboard > Keyboard Shortcuts > Screenshots, then assign those combinations to Wadjet Workflows. Also consider the Control variants if Wadjet should own clipboard capture shortcuts. Do not edit Apple's preference files behind the user's back. [26][24]

Allowing a conflict in a recorder UI is not proof that Wadjet has taken over the shortcut. Check registration failure and test actual delivery. The macOS 15.0/15.1 Option-only hotkey restriction was addressed in 15.2; KeyboardShortcuts scopes its workaround to those older versions. Do not apply that old restriction to macOS 26+. [24][27]

## Xcode project, SwiftPM, and generators

Recommendation: commit a small `.xcodeproj` with one app target and a shared scheme. Use SwiftPM for KeyboardShortcuts and any later reusable core library. Xcode manages app packaging, Info.plist, signing, entitlements, and debugging directly. SwiftPM's ordinary products are executables and libraries; a package-only app needs extra app-bundle and signing machinery. This is a maintenance judgment, not a claim that SwiftPM cannot compile AppKit code. [28][29][22]

XcodeGen generates an Xcode project from YAML/JSON, including targets, schemes, and build settings. It is a reasonable later choice if project-file conflicts become a real problem. Tuist uses Swift manifests and offers project/workspace generation plus broader build tooling. Neither changes TCC identity rules. For this single private app, defer both generators to avoid another required tool and configuration language. [30][31][1]

## Concrete initial configuration

Suggested settings, based on Apple's build-settings reference and the inspected capture app projects. Team values belong in a local signing override if other contributors later use their own accounts. [28][22][23]

```xcconfig
MACOSX_DEPLOYMENT_TARGET = 26.0
PRODUCT_BUNDLE_IDENTIFIER = cx.mia.wadjet
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = VJKBGC9AMK
ENABLE_APP_SANDBOX = NO
ENABLE_HARDENED_RUNTIME = YES
GENERATE_INFOPLIST_FILE = YES
INFOPLIST_KEY_LSUIElement = YES
```

`LSUIElement` makes an agent app absent from the Dock. Use SwiftUI for settings and AppKit where Capture overlays need window control. Keep Debug and private Release signing consistent initially. Select the beta toolchain per command with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`, rather than changing the Mac's global Xcode selection. [32][28] The installed Apple `xcode-select(1)` manual documents this environment override; [33] documents command-line project builds.

## Local inspection and verification limits

Read-only inspection on 2026-10-07 returned:

```text
sw_vers
  macOS 27.2, build 26B5101f
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -version
  Xcode 27.0, build 27A5228h
security find-identity -v -p codesigning
  1 valid identity: Apple Development: mia@mia.cx (KMCJ596S53)
security find-certificate -c 'Apple Development: mia@mia.cx' -p
  decoded with openssl x509 -noout -subject -dates
  OU / team ID: VJKBGC9AMK
  valid 2026-07-24 through 2027-07-24 UTC
```

No capture API, permission request, signing operation, TCC reset, or Xcode account change was performed. The unusual OS version/build pairing above is exactly what the machine reported. This research establishes the setup, not a tested permission-persistence result for a Wadjet executable.

Suggested follow-up tickets:

1. Create the app target and verify two different signed builds satisfy the same DR using `codesign -d -r-` and `codesign --verify -R`. Then test that Screen Recording remains authorized after rebuilding. Requires Mia to approve initial consent; do not reset unrelated apps.
2. Verify the existing certificate is selectable in Xcode. Sign in or manage certificates only if unavailable. Confirm the Team shown there matches the certificate OU.
3. Test custom screenshots, Recordings, and picker sessions on macOS 26 and the current 27 beta. Record renewed-consent behavior and recovery; a short test cannot establish a monthly cadence.
4. If replacing Apple's shortcuts is chosen, Mia disables/remaps ⌘⇧3/4/5, then validates all Workflow triggers and conflicts.

## Sources

[1]: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
[2]: https://developer.apple.com/forums/thread/125438
[3]: https://developer.apple.com/help/account/basics/about-your-developer-account
[4]: https://developer.apple.com/developer-id/
[5]: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
[6]: https://github.com/sindresorhus/KeyboardShortcuts/blob/772133d9dbe800fdac0473226822994c5c162c58/readme.md
[7]: https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media
[8]: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
[9]: https://developer.apple.com/videos/play/wwdc2023/10053/
[10]: https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes
[11]: https://developer.apple.com/documentation/macos-release-notes/macos-15_1-release-notes
[12]: https://github.com/badlogic/screeny2/blob/main/plan.md
[13]: https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes
[14]: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
[15]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture
[16]: https://developer.apple.com/forums/thread/683860
[17]: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
[18]: https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
[19]: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
[20]: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
[21]: https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
[22]: https://github.com/Mnpn/Azayaka/blob/9fb0ac90b311c40a48a6563aab3ee2a30a6f2222/Azayaka.xcodeproj/project.pbxproj
[23]: https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder.xcodeproj/project.pbxproj
[24]: https://github.com/sindresorhus/KeyboardShortcuts/blob/772133d9dbe800fdac0473226822994c5c162c58/Sources/KeyboardShortcuts/HotKey.swift
[25]: https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
[26]: https://support.apple.com/guide/mac-help/take-a-screenshot-mh26782/mac
[27]: https://developer.apple.com/forums/thread/763878
[28]: https://developer.apple.com/documentation/xcode/build-settings-reference
[29]: https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html
[30]: https://github.com/yonaskolb/XcodeGen
[31]: https://tuist.dev/en/docs/guides/features/projects/manifests
[32]: https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement
[33]: https://developer.apple.com/library/archive/technotes/tn2339/_index.html

Additional inspected source: [Azayaka entitlements](https://github.com/Mnpn/Azayaka/blob/9fb0ac90b311c40a48a6563aab3ee2a30a6f2222/Azayaka/Azayaka.entitlements), [QuickRecorder entitlements](https://github.com/lihaoyun6/QuickRecorder/blob/e82051787f013ec2e811fcceab2d7de80e9d4dbe/QuickRecorder/QuickRecorder.entitlements), and [KeyboardShortcuts shortcut validation](https://github.com/sindresorhus/KeyboardShortcuts/blob/772133d9dbe800fdac0473226822994c5c162c58/Sources/KeyboardShortcuts/Shortcut.swift).

SDK evidence is from `CoreGraphics.framework/Headers/CGWindow.h` and `ScreenCaptureKit.framework/Headers/SCScreenshotManager.h`, under `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks`. Apple documentation pages with JavaScript-only HTML were also read through their corresponding `https://developer.apple.com/tutorials/data/documentation/...json` representations.
