# Desktop branding and macOS installation

## Changes

- Generate every macOS AppIcon PNG (16 through 1024 pixels) and the Windows
  multi-size ICO (16/24/32/48/64/128/256) from the same original geometry as
  the Android launcher icon. Existing Android PNGs remain byte-identical.
- Keep generation reproducible with the standard-library-only command
  `python3 tool/branding/generate_icons.py`.
- Stage the signed macOS app, an Applications symlink and README.txt before
  DMG creation. The README explains drag-to-install and the manual first-launch
  exception in System Settings > Privacy & Security > Open Anyway.
- Run portable icon checks in the shared CI test job, and the macOS-specific
  staging regression in the macOS job. No receiver/ABI changes.

## Gatekeeper investigation

On the installed `/Applications/AirSDR.app`:

- `codesign -dvv`: Signature=adhoc, TeamIdentifier=not set.
- `codesign --verify --deep --strict`: passes.
- `spctl --assess --type execute --verbose=4`: rejected.
- `security find-identity -v -p codesigning`: no valid identities.

This is an unnotarized ad-hoc build, not a broken code signature. The user
confirmed no Apple Developer certificate is available and selected manual
launch permission. No security settings or installed app were modified.
Removing this warning requires Developer ID signing and Apple notarization.
References: https://support.apple.com/102445 and
https://developer.apple.com/developer-id/.

## Verification (macOS arm64, 2026-10-18)

- RED: `python3 test/ci/desktop_assets_test.py` rejects the old macOS/Windows
  artwork and missing DMG staging helper.
- GREEN: `python3 -m unittest discover -s test/ci -p '*_test.py'`: 8 pass.
  Compares icon payloads with the Android geometry and checks the staged
  app, Applications symlink and first-launch README.
- `xcrun actool macos/Runner/Assets.xcassets --compile /private/tmp/airsdr-desktop-icon-catalog --platform macosx --minimum-deployment-target 12.0 --app-icon AppIcon --output-partial-info-plist /private/tmp/airsdr-desktop-icon-catalog/info.plist`: pass.
- llvm-mingw 20261006 `x86_64-w64-mingw32-windres` compiles a resource file
  referencing the new ICO: pass. Native Windows resource display is unverified.
- Created an actual UDZO DMG with `hdiutil create`, mounted it read-only with
  `hdiutil attach`, verified its root entries, Applications target and compiled
  AppIcon.icns bytes, then detached it. The smoke app was a temporary copy of
  the installed CI release with freshly compiled icon resources and renewed
  ad-hoc signing. `codesign --verify --deep --strict` passes on the mounted copy.
- `flutter analyze`: no issues.
- `flutter test --concurrency=1`: 510 passed, 17 skipped.
- `flutter build apk --debug`: pass.
- `git diff --check`: pass.

Full macOS/Windows Flutter application rebuilds, Finder/Dock icon cache behavior,
Windows runtime, Linux receiver hardware and Android emulator behavior remain
unverified. The DMG check validates actual packaging and signature integrity;
it does not claim Apple notarization or automatic Gatekeeper acceptance.
