# Packaging P5M for macOS

Build with `mac/compilar.sh`, then run:

```sh
python3 mac/package.py
```

The script preserves `build-mac/gui/chiaki.app` and creates a separate
`dist/P5M.app` and `dist/P5M.zip`. It refuses to overwrite an existing
output. Choose `--output /path/P5M-next.app` for another iteration.

Qt Quick imports, plugins, QtWebEngine helpers/resources, and the recursive
Mach-O dependencies are bundled. This includes the locally built SDL and
cpp-steam-tools libraries. Each dependency is relocated to the bundle, and
non-system dependencies and run paths are checked recursively. No Homebrew
installation should be needed on the receiving Mac. The app is never
launched during packaging or verification. DWARF/STABS debugging information
is stripped from the distribution copy only; the build output is preserved.
The package is rejected if private build paths remain in binary constants,
notices, dependency manifests or App Intents metadata.

The minimum system version is computed from **all** bundled Mach-O files,
including plugins and helper apps, and applied to the top-level Info.plist.
A build made with macOS 27 libraries can require macOS 27 even when the app's
own CMake deployment target says 13. Changing the plist cannot make those
libraries run on older systems. To support older macOS versions, rebuild
all dependencies on a compatible build machine/SDK and rerun this audit.
The generated `Contents/Resources/packaging-manifest.json` lists each
binary's deployment target and has no build-machine personal paths.

Audit an already packaged app:

```sh
python3 mac/package.py --audit-only dist/P5M.app
codesign --verify --deep --strict --verbose=2 dist/P5M.app
```

## Signing and notarization

The default is an **ad-hoc signature**, verified recursively. This verifies
bundle integrity locally but is not Developer ID signing and is not Apple
notarization. Gatekeeper will not treat it as a notarized Internet download.
Do not describe this build as notarized in a public release.

For Developer ID, use an identity already installed in Keychain and an
explicitly reviewed entitlements file suitable for QtWebEngine JIT:

```sh
python3 mac/package.py --output dist/P5M-release.app \
  --identity 'Developer ID Application: YOUR INSTALLED IDENTITY' \
  --entitlements /path/to/reviewed-entitlements.plist
```

The script signs code from the inside out, enables hardened runtime for
Developer ID, and verifies the complete bundle. It does not create
credentials, modify the Keychain, upload a build, or invoke notarization.
Once Apple Developer enrollment and an existing notarytool Keychain profile
are configured locally, submit the generated ZIP with `xcrun notarytool
submit --keychain-profile PROFILE --wait`, then staple the approved app
with `xcrun stapler staple` and verify using `spctl --assess --type execute`.
Recreate the ZIP with `ditto` after stapling. Never put passwords or account
secrets in chat, scripts, repository files, or release logs.

## Release checklist

- Test the copied app on another Mac without Homebrew, including PSN login
  (QtWebEngine), controller input/audio, SDR and HDR, full screen and reconnect.
- Preserve the generated manifest and record the source commit/build version.
- Review bundled `ThirdPartyLicenses` notices, including static dependencies,
  and publish the exact Corresponding Source with the binary. License
  collection is a starting point, not a substitute for reviewing the build's
  dependency/source inventory. Qt licenses may need to be obtained from the
  exact upstream source when Homebrew omits its notice files.
- Validate Developer ID, notarization and Gatekeeper before presenting the
  download as ready for general users.
- Check the release diff and package resources for private links, local IPs,
  personal information and credentials. The script does not copy user
  settings, console registration keys or application logs.
