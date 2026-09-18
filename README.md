# iPhone Duo App Patcher

A portable macOS command-line utility to patch iOS Simulator application bundles for Apple's dual-screen foldable device layout (iPhone Duo).

Below command installs all apps from the 27.2 simruntime into the Duos'.
```bash
# Patch and install all stock apps to the booted iPhone Duo:
./patch_duo_app.zsh --from-runtime 27.2 --device booted
```

---

## Overview

The iPhone Duo simulator introduces a dual-display foldable architecture:
- **Display 1 (Outer / Cover Screen):** Standard compact phone display (`1398 × 2034 @ 3x`, Compact horizontal size class).
- **Display 3 (Inner / Unfolded Screen):** Expanded dual-screen canvas (`2007 × 2853 @ 3x`, Regular horizontal size class) divided by a central physical hinge.

Applications running on the unfolded screen require specific bundle attributes to adapt to the expanded canvas:
1. **Regular Width Idiom (`UIDeviceFamily`):** Apps configured strictly with `UIDeviceFamily = [1]` (iPhone only) run in single-screen compatibility mode. Injecting `2` (`[1, 2]`) enables UIKit multi-column sidebars, split views, and expanded toolbars across the hinge.
2. **SDK Build Stamp (`LC_BUILD_VERSION`):** UIKit checks the Mach-O `LC_BUILD_VERSION` load command (`minos` and `sdk`). Binaries built with older or mismatched SDKs trigger UIKit backward-compatibility fallbacks, locking the interface into single-column layouts with fixed bottom tab bars.
3. **Cross-Runtime OS Version Gate (`MinimumOSVersion`):** Extracting stock apps from newer preview runtimes (such as iOS 27.2 Beta) to install onto an iOS 27.1 Duo simulator fails during `simctl install` because `MinimumOSVersion = 27.2` exceeds the host runtime (`error 16: Have 27.1; need 27.2`).

`patch_duo_app.zsh` automates resolving, patching, signing, and installing bundles in a single command.

---

## How It Works

1. **Dynamic Discovery:** Uses `xcrun simctl list runtimes -j` and `xcrun simctl list devices -j` to resolve simulator runtime roots and target devices dynamically. It does not depend on hardcoded mount paths or Xcode bundle names (`Xcode.app` vs `Xcode-27.1.0-Beta.app`).
2. **Mach-O Binary Patching:** Uses `xcrun vtool` to update `LC_BUILD_VERSION` (`minos` and `sdk`) to match the target simulator OS version across all architectures (`arm64`, `x86_64`).
3. **Property List Updates:** Uses `/usr/libexec/PlistBuddy` to update `UIDeviceFamily = [1, 2]`, `UIApplicationSupportsMultipleScenes = true`, and align `MinimumOSVersion`, `DTPlatformVersion`, and `DTSDKName`.
4. **Recursive Code Signing:** Re-signs the entire bundle hierarchy ad-hoc using `codesign --force --deep -s -`.
5. **Simulator Installation:** Deploys the patched bundle directly to the target simulator via `xcrun simctl install`.

---

## Requirements

- macOS with Command Line Tools or Xcode installed:
  - `zsh`
  - `xcrun`
  - `vtool`
  - `codesign`
  - `/usr/libexec/PlistBuddy`
  - `/usr/bin/python3` (macOS system Python for JSON parsing)

No external package managers, Ruby gems, or third-party dependencies required.

---

## Usage

```text
patch_duo_app.zsh [options] [app-name-or-path...]
```

### Options

| Flag | Argument | Description |
| :--- | :--- | :--- |
| `-r, --from-runtime` | `<query>` | Extract apps from a simulator runtime (e.g. `27.2`, `iOS 27.2`) |
| `-d, --device` | `<target>` | Target simulator (`booted`, UDID, or device name) |
| `-i, --install` | `<target>` | Alias for `--device` |
| `-s, --sdk` | `<version>` | Target SDK version (automatically inferred from `--device` if omitted) |
| `-o, --output` | `<dir>` | Staging directory (defaults to `/tmp/duo_patched_apps` with `--from-runtime`) |
| `-l, --list-runtimes`| None | List all detected simulator runtimes and exit |
| `-n, --dry-run` | None | Inspect operations without modifying files or installing |
| `-v, --verbose` | None | Print detailed per-file diagnostic output |
| `-q, --quiet` | None | Silence non-error output |
| `-V, --version` | None | Print version and exit |
| `-h, --help` | None | Show usage help |

---

## Examples

### 1. One-line extraction from iOS 27.2 Beta to booted Duo
Automatically locates the iOS 27.2 Beta runtime image, detects the booted Duo device and its OS version (e.g., iOS 27.1), stages the apps, patches Mach-O load commands and plists, re-signs, and installs:

```bash
./patch_duo_app.zsh --from-runtime 27.2 --device booted Contacts.app Preview.app
```

### 2. Install to a specific simulator UDID
```bash
./patch_duo_app.zsh --from-runtime 27.2 --device 2A7E75C0-4F47-4286-BBFA-55AA7948A549 Contacts Files Maps
```

### 3. Extract and patch all default stock apps
If no app names are specified, the script automatically selects the core stock applications (`Contacts`, `Preview`, `Files`, `Maps`, `MobileCal`, `Reminders`, `Shortcuts`, `Passwords`, `News`):

```bash
./patch_duo_app.zsh --from-runtime 27.2 --device booted
```

### 4. Patch a local application bundle in-place
```bash
./patch_duo_app.zsh /path/to/MyApp.app --install booted
```

### 5. Inspect available simulator runtimes
```bash
./patch_duo_app.zsh --list-runtimes
```

---

## Technical Notes

- **Read-Only Runtime Roots:** Simulator runtime volumes mounted by macOS (`/Library/Developer/CoreSimulator/Volumes/...` or `/private/var/run/com.apple.security.cryptexd/mnt/...`) are read-only. When `--from-runtime` is specified, the script automatically copies bundles to a writable staging directory (`/tmp/duo_patched_apps` or `--output <dir>`) before modifying them.
- **Protected System Applications:** Built-in system applications marked non-removable in the host runtime (such as `com.apple.mobilesafari` on iOS 27.1) cannot be replaced via `simctl install` (`System app upgrade is missing upgrade entitlement`).
- **Private Framework Dependencies:** Certain applications in newer beta runtimes may link against private framework symbols introduced in that specific OS build. If an app relies on APIs absent from the host runtime's private frameworks, dyld will fail symbol resolution at launch. Apps with standard system linkage (e.g., `Contacts.app`, `Preview.app`) execute immediately without modification.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
