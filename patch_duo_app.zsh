#!/usr/bin/env zsh
# ==============================================================================
# patch_duo_app.zsh
#
# A macOS CLI tool to patch iOS Simulator application bundles to work in the Duo simulator.
#
# License: MIT
# ==============================================================================

set -eo pipefail

SCRIPT_NAME="${0:t}"
SCRIPT_VERSION="2.0.0"

# Configuration defaults
SDK_VER=""
FROM_RUNTIME=""
DEVICE_TARGET=""
OUTPUT_DIR=""
DRY_RUN=false
VERBOSE=false
QUIET=false

declare -a TARGET_ARGS=()

# Terminal colors
if [[ -t 1 ]]; then
    BOLD="%B"
    RESET="%b"
    C_BLUE="%F{blue}"
    C_CYAN="%F{cyan}"
    C_GREEN="%F{green}"
    C_YELLOW="%F{yellow}"
    C_RED="%F{red}"
    C_RESET="%f"
else
    BOLD=""
    RESET=""
    C_BLUE=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_RESET=""
fi

log_info()    { if [[ "$QUIET" == false ]]; then print -P "${C_BLUE}==>${C_RESET} ${BOLD}$1${RESET}"; fi }
log_step()    { if [[ "$QUIET" == false ]]; then print -P "  ${C_CYAN}➜${C_RESET} $1"; fi }
log_detail()  { if [[ "$VERBOSE" == true && "$QUIET" == false ]]; then print -P "    ${BOLD}•${RESET} $1"; fi }
log_success() { if [[ "$QUIET" == false ]]; then print -P "  ${C_GREEN}✔${C_RESET} ${BOLD}$1${RESET}"; fi }
log_warn()    { print -P "${C_YELLOW}[!] Warning:${C_RESET} $1" >&2; }
log_error()   { print -P "${C_RED}[✘] Error:${C_RESET} $1" >&2; }

usage() {
    cat <<EOF
patch_duo_app.zsh v${SCRIPT_VERSION}
Patch iOS app bundles for iPhone Duo foldable layouts and cross-runtime compatibility.

USAGE:
  $SCRIPT_NAME [options] [app-name-or-path...]

OPTIONS:
  -r, --from-runtime <query>   Extract apps from a simulator runtime (e.g. '27.2', 'iOS 27.2')
  -d, --device <target>        Target simulator ('booted', UDID, or device name)
  -i, --install <target>       Alias for --device
  -s, --sdk <version>          Target SDK version (auto-detected from --device if omitted)
  -o, --output <dir>           Output/staging directory (default: /tmp/duo_patched_apps when using --from-runtime)
  -l, --list-runtimes          List all available simulator runtimes and exit
  -n, --dry-run                Inspect without writing any changes to disk
  -v, --verbose                Print detailed per-file patching diagnostics
  -q, --quiet                  Silence non-error output
  -V, --version                Show script version and exit
  -h, --help                   Show this help message and exit

EXAMPLES:
  # One-line automated extraction, patching, and installation to a booted Duo:
  $SCRIPT_NAME --from-runtime 27.2 --device booted Contacts.app Preview.app

  # Automatically detect target SDK from UDID and patch stock apps:
  $SCRIPT_NAME --from-runtime 27.2 --device 2A7E75C0-4F47-4286-BBFA-55AA7948A549 Contacts Files Maps

  # Patch an existing local application bundle in-place:
  $SCRIPT_NAME /path/to/MyApp.app

  # List all simulator runtimes detected on this system:
  $SCRIPT_NAME --list-runtimes
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Dependency Verification
# ------------------------------------------------------------------------------
check_dependencies() {
    local missing=()

    if ! command -v xcrun >/dev/null 2>&1; then
        missing+=("xcrun (Xcode Command Line Tools)")
    fi

    if ! xcrun -f vtool >/dev/null 2>&1; then
        missing+=("vtool (Apple Mach-O Version Tool)")
    fi

    if ! command -v codesign >/dev/null 2>&1; then
        missing+=("codesign (Apple Code Signing Utility)")
    fi

    if [[ ! -x /usr/libexec/PlistBuddy ]]; then
        missing+=("/usr/libexec/PlistBuddy")
    fi

    if [[ ! -x /usr/bin/python3 ]]; then
        missing+=("/usr/bin/python3")
    fi

    if [[ -n "$DEVICE_TARGET" ]] && ! xcrun -f simctl >/dev/null 2>&1; then
        missing+=("simctl (CoreSimulator CLI)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools:"
        for tool in "${missing[@]}"; do
            print -P "  - $tool" >&2
        done
        print -P "\nInstall Xcode or run: ${BOLD}xcode-select --install${RESET}\n" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Dynamic Simctl & Runtime Queries
# ------------------------------------------------------------------------------
simctl_query() {
    /usr/bin/python3 -c "
import sys, json, subprocess, re

action = sys.argv[1]

if action == 'list_runtimes':
    try:
        data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))
        print('Available Simulator Runtimes:')
        for r in data.get('runtimes', []):
            avail = 'Available' if r.get('isAvailable', True) else 'Unavailable'
            name = r.get('name', 'Unknown')
            ident = r.get('identifier', '')
            root = r.get('runtimeRoot', 'N/A')
            print(f'  • {name} [{ident}] ({avail})')
            print(f'    Root: {root}')
    except Exception as e:
        sys.stderr.write(f'Failed to query runtimes: {e}\n')
        sys.exit(1)

elif action == 'resolve_runtime':
    query = sys.argv[2].strip().lower()
    try:
        data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))
        matches = []
        for r in data.get('runtimes', []):
            name = r.get('name', '').lower()
            ident = r.get('identifier', '').lower()
            root = r.get('runtimeRoot')
            if not root:
                continue
            if query == name or query == ident or query == name.replace('ios ', ''):
                matches.insert(0, r)
            elif query in name or query in ident:
                matches.append(r)
        if matches:
            chosen = matches[0]
            print(chosen.get('runtimeRoot', ''))
            print(chosen.get('name', ''))
            sys.exit(0)
        sys.stderr.write(f'No runtime matching \"{sys.argv[2]}\" found.\n')
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f'Error resolving runtime: {e}\n')
        sys.exit(1)

elif action == 'resolve_device':
    target = sys.argv[2].strip() if len(sys.argv) > 2 else 'booted'
    try:
        data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))
        devices = []
        for rt_id, d_list in data.get('devices', {}).items():
            m = re.search(r'iOS[- ](\d+)[-.](\d+)', rt_id)
            rt_ver = f'{m.group(1)}.{m.group(2)}' if m else '27.1'
            for d in d_list:
                devices.append({
                    'udid': d.get('udid', ''),
                    'name': d.get('name', ''),
                    'state': d.get('state', ''),
                    'runtime_id': rt_id,
                    'runtime_ver': rt_ver
                })

        selected = None
        if target.lower() not in ('booted', 'auto', ''):
            for d in devices:
                if d['udid'].lower() == target.lower() or d['name'].lower() == target.lower():
                    selected = d
                    break
        else:
            booted = [d for d in devices if d['state'] == 'Booted']
            if booted:
                duos = [d for d in booted if 'duo' in d['name'].lower()]
                selected = duos[0] if duos else booted[0]

        if selected:
            print(selected['udid'])
            print(selected['name'])
            print(selected['runtime_ver'])
            sys.exit(0)

        sys.stderr.write(f'No simulator device found matching \"{target}\".\n')
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f'Error resolving device: {e}\n')
        sys.exit(1)
" "$@"
}

# ------------------------------------------------------------------------------
# Plist Patching
# ------------------------------------------------------------------------------
patch_plist_file() {
    local plist="$1"
    [[ -f "$plist" && ! -L "$plist" ]] || return 0

    if [[ "$DRY_RUN" == true ]]; then
        log_detail "[Dry-Run] Would update Plist: ${plist}"
        return 0
    fi

    # 1. UIDeviceFamily: Ensure regular width idiom (2) is present
    if ! /usr/libexec/PlistBuddy -c "Print :UIDeviceFamily" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" "$plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:0 integer 1" "$plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:1 integer 2" "$plist" 2>/dev/null || true
        log_detail "Created UIDeviceFamily = [1, 2] in ${plist:t}"
    else
        if ! /usr/libexec/PlistBuddy -c "Print :UIDeviceFamily" "$plist" 2>/dev/null | grep -q '^\s*2$'; then
            /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily: integer 2" "$plist" 2>/dev/null || true
            log_detail "Added idiom 2 (regular width) to UIDeviceFamily in ${plist:t}"
        fi
    fi

    # 2. Multi-Scene Manifest Support
    if /usr/libexec/PlistBuddy -c "Print :UIApplicationSceneManifest" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes true" "$plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool true" "$plist" 2>/dev/null || true
        log_detail "Enabled UIApplicationSupportsMultipleScenes in ${plist:t}"
    fi

    # 3. MinimumOSVersion & SDK sync
    local sdk_name="iphonesimulator${SDK_VER}.internal"
    local keys_values=(
        "DTPlatformVersion" "$SDK_VER"
        "DTSDKName" "$sdk_name"
        "MinimumOSVersion" "$SDK_VER"
    )

    for ((i = 1; i <= ${#keys_values[@]}; i += 2)); do
        local key="${keys_values[i]}"
        local val="${keys_values[i+1]}"
        /usr/libexec/PlistBuddy -c "Set :$key $val" "$plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :$key string $val" "$plist" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------
# Mach-O Binary Patching
# ------------------------------------------------------------------------------
patch_macho_file() {
    local bin="$1"
    [[ -f "$bin" && ! -L "$bin" ]] || return 1

    if ! file -b "$bin" 2>/dev/null | grep -q "Mach-O"; then
        return 1
    fi

    if ! xcrun vtool -show-build "$bin" >/dev/null 2>&1; then
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_detail "[Dry-Run] Would patch Mach-O build version (sdk/minos ${SDK_VER}) -> ${bin:t}"
        return 0
    fi

    if xcrun vtool -set-build-version iossim "$SDK_VER" "$SDK_VER" -replace -output "$bin" "$bin" >/dev/null 2>&1; then
        log_detail "Patched LC_BUILD_VERSION (${SDK_VER}) in ${bin:t}"
        return 0
    else
        log_warn "Failed to update build version for ${bin:t}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Application Bundle Processing
# ------------------------------------------------------------------------------
patch_bundle() {
    local src_app="$1"
    local app_name="${src_app:t}"
    local working_app="$src_app"

    log_info "Processing ${app_name}"

    if [[ -n "$OUTPUT_DIR" ]]; then
        working_app="$OUTPUT_DIR/$app_name"
        if [[ "$DRY_RUN" == false ]]; then
            log_step "Copying bundle to staging directory..."
            mkdir -p "$OUTPUT_DIR"
            rm -rf "$working_app"
            cp -R "$src_app" "$working_app"
            chmod -R u+w "$working_app" 2>/dev/null || true
            xattr -cr "$working_app" 2>/dev/null || true
        fi
    fi

    # Step 1: Info.plist files
    log_step "Configuring plists (UIDeviceFamily [1, 2] & MinimumOSVersion ${SDK_VER})..."
    patch_plist_file "$working_app/Info.plist"

    for sub_plist in "$working_app"/**/Info.plist(.N); do
        if [[ "$sub_plist" != "$working_app/Info.plist" ]]; then
            patch_plist_file "$sub_plist"
        fi
    done

    # Step 2: Mach-O binaries
    log_step "Updating Mach-O build versions to SDK ${SDK_VER}..."
    local count=0
    for file_candidate in "$working_app"/**/*(.N); do
        if patch_macho_file "$file_candidate"; then
            ((count += 1))
        fi
    done
    log_detail "Total Mach-O binaries updated: $count"

    # Step 3: Re-signing
    if [[ "$DRY_RUN" == false ]]; then
        log_step "Re-signing bundle ad-hoc..."
        for item in "$working_app"/Frameworks/*(N) "$working_app"/PlugIns/*(N); do
            if [[ -e "$item" ]]; then
                codesign --force -s - "$item" >/dev/null 2>&1 || true
            fi
        done
        if codesign --force --deep -s - "$working_app" >/dev/null 2>&1; then
            log_detail "Code signature valid."
        else
            log_warn "codesign returned non-zero code for $app_name."
        fi
        sync 2>/dev/null || true
        sleep 0.5
    else
        log_step "[Dry-Run] Would re-sign bundle with ad-hoc signature."
    fi

    # Step 4: Simulator Deployment
    if [[ -n "$INSTALL_UDID" ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            log_step "Installing to simulator '${INSTALL_NAME}' (${INSTALL_UDID})..."
            if xcrun simctl install "$INSTALL_UDID" "$working_app" 2>/dev/null || \
               (sleep 1 && xcrun simctl install "$INSTALL_UDID" "$working_app"); then
                log_success "Successfully installed $app_name onto ${INSTALL_NAME}!"
            else
                log_error "Installation failed for $app_name onto simulator."
                return 1
            fi
        else
            log_step "[Dry-Run] Would install onto simulator '${INSTALL_NAME}' (${INSTALL_UDID})."
        fi
    fi

    log_success "Completed ${app_name}\n"
    return 0
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--from-runtime)
                [[ -n "$2" ]] || { log_error "Missing argument for $1"; exit 1; }
                FROM_RUNTIME="$2"
                shift 2
                ;;
            -d|--device|-i|--install)
                [[ -n "$2" ]] || { log_error "Missing argument for $1"; exit 1; }
                DEVICE_TARGET="$2"
                shift 2
                ;;
            -s|--sdk)
                [[ -n "$2" ]] || { log_error "Missing argument for $1"; exit 1; }
                SDK_VER="$2"
                shift 2
                ;;
            -o|--output)
                [[ -n "$2" ]] || { log_error "Missing argument for $1"; exit 1; }
                OUTPUT_DIR="${2:A}"
                shift 2
                ;;
            -l|--list-runtimes)
                check_dependencies
                simctl_query list_runtimes
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -V|--version)
                print -P "${BOLD}$SCRIPT_NAME${RESET} version $SCRIPT_VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                TARGET_ARGS+=("$1")
                shift
                ;;
        esac
    done

    check_dependencies

    # 1. Resolve Target Device (if requested)
    INSTALL_UDID=""
    INSTALL_NAME=""
    if [[ -n "$DEVICE_TARGET" ]]; then
        log_info "Resolving target simulator device..."
        local dev_info
        dev_info="$(simctl_query resolve_device "$DEVICE_TARGET")" || {
            log_error "Could not resolve simulator device: $DEVICE_TARGET"
            exit 1
        }
        INSTALL_UDID="$(print "$dev_info" | sed -n '1p')"
        INSTALL_NAME="$(print "$dev_info" | sed -n '2p')"
        local detected_os_ver="$(print "$dev_info" | sed -n '3p')"

        log_step "Target device: ${BOLD}${INSTALL_NAME}${RESET} (${INSTALL_UDID})"

        # Automatically infer SDK version if not explicitly provided
        if [[ -z "$SDK_VER" ]]; then
            SDK_VER="${detected_os_ver:-27.1}"
            log_step "Auto-detected target SDK: ${BOLD}${SDK_VER}${RESET}"
        fi
    fi

    # Default SDK fallback if neither device nor --sdk provided
    if [[ -z "$SDK_VER" ]]; then
        SDK_VER="27.1"
    fi

    # 2. Resolve Source Runtime (if requested)
    local runtime_apps_dir=""
    if [[ -n "$FROM_RUNTIME" ]]; then
        log_info "Resolving simulator runtime matching '${FROM_RUNTIME}'..."
        local rt_info
        rt_info="$(simctl_query resolve_runtime "$FROM_RUNTIME")" || {
            log_error "Could not locate simulator runtime matching: $FROM_RUNTIME"
            exit 1
        }
        local rt_root="$(print "$rt_info" | sed -n '1p')"
        local rt_name="$(print "$rt_info" | sed -n '2p')"
        log_step "Resolved runtime: ${BOLD}${rt_name}${RESET}"
        log_detail "Runtime root: $rt_root"

        runtime_apps_dir="$rt_root/Applications"
        if [[ ! -d "$runtime_apps_dir" ]]; then
            log_error "Applications directory not found in runtime root: $runtime_apps_dir"
            exit 1
        fi

        # If pulling from runtime and no output dir set, stage in /tmp
        if [[ -z "$OUTPUT_DIR" ]]; then
            OUTPUT_DIR="${TMPDIR:-/tmp}/duo_patched_apps"
            log_step "Staging patched apps in: $OUTPUT_DIR"
        fi
    fi

    # 3. Resolve Target Applications
    declare -a APPS=()

    if [[ -n "$runtime_apps_dir" ]]; then
        if [[ ${#TARGET_ARGS[@]} -gt 0 ]]; then
            for item in "${TARGET_ARGS[@]}"; do
                local candidate="$runtime_apps_dir/$item"
                [[ -d "$candidate" ]] || candidate="$runtime_apps_dir/${item}.app"
                if [[ -d "$candidate" ]]; then
                    APPS+=("$candidate")
                else
                    log_warn "App not found in runtime: $item"
                fi
            done
        else
            # Default core stock apps if none specified
            local defaults=("Contacts.app" "Preview.app" "Files.app" "Maps.app" "MobileCal.app" "Reminders.app" "Shortcuts.app" "Passwords.app" "News.app")
            for d in "${defaults[@]}"; do
                [[ -d "$runtime_apps_dir/$d" ]] && APPS+=("$runtime_apps_dir/$d")
            done
        fi
    else
        if [[ ${#TARGET_ARGS[@]} -eq 0 ]]; then
            log_error "No target application bundles or directories specified."
            usage
        fi
        for item in "${TARGET_ARGS[@]}"; do
            local abs_item="${item:A}"
            if [[ -d "$abs_item" ]]; then
                if [[ "$abs_item" == *.app ]]; then
                    APPS+=("$abs_item")
                else
                    for sub in "$abs_item"/*.app(N); do
                        [[ -d "$sub" ]] && APPS+=("$sub")
                    done
                fi
            else
                log_warn "Target does not exist or is not a directory: $item"
            fi
        done
    fi

    if [[ ${#APPS[@]} -eq 0 ]]; then
        log_error "No .app bundles found to process."
        exit 1
    fi

    log_info "Found ${#APPS[@]} application(s) to process [Target SDK: ${SDK_VER}]"
    if [[ "$DRY_RUN" == true ]]; then
        print -P "${C_YELLOW}${BOLD}*** DRY RUN MODE ENABLED - No changes will be written ***${RESET}\n"
    fi

    local failures=0
    for app in "${APPS[@]}"; do
        if ! patch_bundle "$app"; then
            ((failures += 1))
        fi
    done

    if [[ $failures -eq 0 ]]; then
        print -P "${C_GREEN}${BOLD}✔ All ${#APPS[@]} application(s) processed successfully!${RESET}"
        exit 0
    else
        print -P "${C_RED}${BOLD}✘ Processed with $failures failure(s).${RESET}" >&2
        exit 1
    fi
}

main "$@"
