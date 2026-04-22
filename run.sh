#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

NO_CODESIGN=false
if [[ "$NO_CODESIGN" == "1" ]]; then
    NO_CODESIGN=true
fi

APP_BUNDLE_ID="ai.neuxnet.neutype.test"
APP_DEBUG_APP="./build/Build/Products/Debug/NeuType-Test.app"
APP_DEBUG_BINARY="${APP_DEBUG_APP}/Contents/MacOS/NeuType-Test"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/${APP_BUNDLE_ID}"
APP_CACHE_DIR="${HOME}/Library/Caches/${APP_BUNDLE_ID}"
APP_SAVED_STATE_DIR="${HOME}/Library/Saved Application State/${APP_BUNDLE_ID}.savedState"
BUILD_DESTINATION="platform=macOS,name=My Mac"
LOCAL_MEETING_SUMMARY_BASE_URL="${LOCAL_MEETING_SUMMARY_BASE_URL:-http://127.0.0.1:8000}"
LOCAL_MEETING_SUMMARY_API_KEY="${LOCAL_MEETING_SUMMARY_API_KEY:-ntm_local}"
EXPECTED_TEAM_ID="4URL8287A7"
EXPECTED_APP_IDENTIFIER="${APP_BUNDLE_ID}"
APP_NAME="NeuType-Test.app"
LSREGISTER_BIN="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

remove_duplicate_test_apps() {
    local canonical_app
    canonical_app="$(python3 - <<'PY' "${APP_DEBUG_APP}"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"

    local candidate
    while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        local resolved
        resolved="$(python3 - <<'PY' "${candidate}"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
        if [[ "${resolved}" == "${canonical_app}" ]]; then
            continue
        fi
        echo "Removing duplicate test app: ${candidate}"
        rm -rf "${candidate}"
    done < <(
        {
            find "${HOME}/Library/Developer/Xcode/DerivedData" -path "*${APP_NAME}" -print 2>/dev/null || true
            find "${PWD}/.local-debug-dd" -path "*${APP_NAME}" -print 2>/dev/null || true
        } | sort -u
    )
}

reset_launchservices_test_app_mappings() {
    local canonical_app
    canonical_app="$(python3 - <<'PY' "${APP_DEBUG_APP}"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"

    if [[ ! -x "${LSREGISTER_BIN}" ]]; then
        echo "LaunchServices registry tool missing: ${LSREGISTER_BIN}"
        exit 1
    fi

    local stale_paths=()
    while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        local resolved
        resolved="$(python3 - <<'PY' "${candidate}"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
        if [[ "${resolved}" == "${canonical_app}" ]]; then
            continue
        fi
        stale_paths+=("${candidate}")
    done < <(
        {
            mdfind "kMDItemCFBundleIdentifier == '${APP_BUNDLE_ID}'" 2>/dev/null || true
            find "${HOME}/Library/Developer/Xcode/DerivedData" -path "*${APP_NAME}" -print 2>/dev/null || true
            find "${PWD}/.local-debug-dd" -path "*${APP_NAME}" -print 2>/dev/null || true
        } | sort -u
    )

    local stale
    for stale in "${stale_paths[@]}"; do
        echo "Unregistering stale LaunchServices test app: ${stale}"
        "${LSREGISTER_BIN}" -u "${stale}" || true
    done

    echo "Registering canonical LaunchServices test app: ${APP_DEBUG_APP}"
    "${LSREGISTER_BIN}" -f "${APP_DEBUG_APP}"
}

validate_signed_app() {
    local app_path="$1"
    local app_identifier
    local app_team_id
    local app_signature
    local embedded_dylib="${app_path}/Contents/Frameworks/libautocorrect_swift.dylib"

    app_identifier="$(codesign -dv "${app_path}" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
    app_team_id="$(codesign -dv "${app_path}" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    app_signature="$(codesign -dv "${app_path}" 2>&1 | awk -F= '/^Signature=/{print $2; exit}')"

    if [[ "${app_identifier}" != "${EXPECTED_APP_IDENTIFIER}" ]]; then
        echo "Invalid app identifier: expected ${EXPECTED_APP_IDENTIFIER}, got ${app_identifier:-<empty>}"
        exit 1
    fi

    if [[ "${app_team_id}" != "${EXPECTED_TEAM_ID}" ]]; then
        echo "Invalid app team id: expected ${EXPECTED_TEAM_ID}, got ${app_team_id:-<empty>}"
        exit 1
    fi

    if [[ "${app_signature}" == "adhoc" ]]; then
        echo "Invalid app signature: ad-hoc signed build cannot be used for permission validation"
        exit 1
    fi

    if [[ ! -f "${embedded_dylib}" ]]; then
        echo "Missing embedded libautocorrect dylib: ${embedded_dylib}"
        exit 1
    fi

    local dylib_team_id
    dylib_team_id="$(codesign -dv "${embedded_dylib}" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    if [[ "${dylib_team_id}" != "${EXPECTED_TEAM_ID}" ]]; then
        echo "Invalid embedded dylib team id: expected ${EXPECTED_TEAM_ID}, got ${dylib_team_id:-<empty>}"
        exit 1
    fi
}

reset_app_permissions() {
    local services=("Microphone" "Accessibility" "ScreenCapture" "AppleEvents")
    for service in "${services[@]}"; do
        tccutil reset "${service}" "${APP_BUNDLE_ID}" 2>/dev/null || true
    done
}

reset_app_state() {
    defaults delete "${APP_BUNDLE_ID}" 2>/dev/null || true
    rm -rf "${APP_SUPPORT_DIR}" "${APP_CACHE_DIR}" "${APP_SAVED_STATE_DIR}"
}

seed_local_preferences() {
    defaults write "${APP_BUNDLE_ID}" meetingVibeVoiceBaseURL -string "${LOCAL_MEETING_SUMMARY_BASE_URL}"
    defaults write "${APP_BUNDLE_ID}" meetingVibeVoiceAPIPrefix -string ""
    defaults write "${APP_BUNDLE_ID}" meetingVibeVoiceAPIKey -string "${LOCAL_MEETING_SUMMARY_API_KEY}"
    defaults write "${APP_BUNDLE_ID}" meetingSummaryBaseURL -string "${LOCAL_MEETING_SUMMARY_BASE_URL}"
    defaults write "${APP_BUNDLE_ID}" meetingSummaryAPIKey -string "${LOCAL_MEETING_SUMMARY_API_KEY}"
    defaults write "${APP_BUNDLE_ID}" whisperLanguage -string "auto"
    defaults write "${APP_BUNDLE_ID}" useAsianAutocorrect -bool true
    defaults write "${APP_BUNDLE_ID}" hasCompletedOnboarding -bool true
    defaults write "${APP_BUNDLE_ID}" didPromptForScreenRecordingPermission -bool false
    defaults write "${APP_BUNDLE_ID}" screenRecordingPermissionPendingRelaunch -bool false
}

# Configure libwhisper
echo "Configuring libwhisper..."
cmake -G Xcode -B libwhisper/build -S libwhisper
if [[ $? -ne 0 ]]; then
    echo "CMake configuration failed!"
    exit 1
fi

echo "Building autocorrect-swift..."
mkdir -p build
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
AUTOCORRECT_CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development: haoran chen \(2VWH5RVKX2\)/ {print $2; exit}')
if [[ -n "${AUTOCORRECT_CODESIGN_IDENTITY}" ]]; then
    codesign --force --sign "${AUTOCORRECT_CODESIGN_IDENTITY}" ./build/libautocorrect_swift.dylib
else
    codesign --force --sign - ./build/libautocorrect_swift.dylib
fi
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

# Build the app
echo "Building NeuType..."
if $NO_CODESIGN; then
    echo "Using unsigned Debug build (NO_CODESIGN=1)..."
    BUILD_OUTPUT=$(xcodebuild -scheme NeuType -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'generic/platform=macOS' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements NeuType/NeuType.entitlements" build 2>&1)
else
    echo "Using project code signing settings for Debug build on ${BUILD_DESTINATION}..."
    BUILD_OUTPUT=$(xcodebuild -scheme NeuType -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination "${BUILD_DESTINATION}" -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions build 2>&1)
fi

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

# Check if build output contains BUILD FAILED or if the command failed
if [[ $? -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
    echo "Building successful!"
    if ! $NO_CODESIGN; then
        echo "Code signing summary:"
        codesign -dv --verbose=4 "${APP_DEBUG_APP}" 2>&1 | egrep 'Identifier=|Authority=|TeamIdentifier=|CDHash=|Signature=' || true
        validate_signed_app "${APP_DEBUG_APP}"
    fi
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Resetting local app state for ${APP_BUNDLE_ID}..."
    pkill -x "NeuType-Test" 2>/dev/null || true
    remove_duplicate_test_apps
    reset_launchservices_test_app_mappings
    reset_app_state
    seed_local_preferences
    echo "Resetting macOS permissions for ${APP_BUNDLE_ID}..."
    reset_app_permissions
    echo "Starting the app..."
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine "${APP_DEBUG_APP}" 2>/dev/null || true
    open -n "${APP_DEBUG_APP}"
else
    echo "Build failed!"
    exit 1
fi 
