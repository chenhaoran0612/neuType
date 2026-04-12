#!/bin/bash
set -eo pipefail

# === Configuration Variables ===
APP_NAME="NeuType"                                   
APP_PATH="./build/Build/Products/Release/NeuType.app"                        
ZIP_PATH="./build/NeuType.zip"                        
BUNDLE_ID="ai.neuxnet.neutype"                       
KEYCHAIN_PROFILE="Slava"
CODE_SIGN_IDENTITY="${1}"
DEFAULT_TEAM_ID="8LLDD7HWZK"
DEVELOPMENT_TEAM=$(printf '%s' "${CODE_SIGN_IDENTITY}" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')
if [[ -z "${DEVELOPMENT_TEAM}" ]]; then
  DEVELOPMENT_TEAM="${DEFAULT_TEAM_ID}"
fi

rm -rf libwhisper/build
cmake -G Xcode -B libwhisper/build -S libwhisper

rm -rf build
mkdir -p build

echo "Building autocorrect-swift..."
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
chmod +w ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp ./build/libautocorrect_swift.dylib

xcodebuild \
  -scheme "NeuType" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -derivedDataPath build \
  build | xcpretty --simple --color

mkdir -p "${APP_PATH}/Contents/Resources/Scripts"
cp ./Scripts/vibevoice_asr_runner.py "${APP_PATH}/Contents/Resources/Scripts/vibevoice_asr_runner.py"

rm -f "${ZIP_PATH}"

current_dir=$(pwd)
cd $(dirname "${APP_PATH}") && zip -r -y "${current_dir}/${ZIP_PATH}" $(basename "${APP_PATH}")
cd "${current_dir}"

xcrun notarytool submit "${ZIP_PATH}" --wait --keychain-profile "${KEYCHAIN_PROFILE}"

xcrun stapler staple "${APP_PATH}"

rm -rf build/dmg-root
mkdir -p build/dmg-root
cp -R "${APP_PATH}" "build/dmg-root/${APP_NAME}.app"
ln -sfn /Applications "build/dmg-root/Applications"
hdiutil create -volname "${APP_NAME}Installer-$(date +%s)" -srcfolder "build/dmg-root" -ov -format UDZO "${APP_NAME}.dmg"

codesign --sign "${CODE_SIGN_IDENTITY}" "${APP_NAME}.dmg"
xcrun notarytool submit "${APP_NAME}.dmg" --wait --keychain-profile "${KEYCHAIN_PROFILE}"
xcrun stapler staple "${APP_NAME}.dmg"  

echo "Successfully notarized ${APP_NAME}"
