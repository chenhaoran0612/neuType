#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

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
codesign --force --sign - ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

# Build the app
echo "Building NeuType..."
BUILD_OUTPUT=$(xcodebuild -scheme NeuType -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'generic/platform=macOS' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO OTHER_CODE_SIGN_FLAGS="--entitlements NeuType/NeuType.entitlements" build 2>&1)

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

# Check if build output contains BUILD FAILED or if the command failed
if [[ $? -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
    APP_RESOURCES_DIR="./build/Build/Products/Debug/NeuType.app/Contents/Resources"
    mkdir -p "${APP_RESOURCES_DIR}/Scripts"
    cp ./Scripts/vibevoice_asr_runner.py "${APP_RESOURCES_DIR}/Scripts/vibevoice_asr_runner.py"
    echo "Building successful!"
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine ./build/Build/Products/Debug/NeuType.app 2>/dev/null || true
    # Run the app and show logs
    ./build/Build/Products/Debug/NeuType.app/Contents/MacOS/NeuType
else
    echo "Build failed!"
    exit 1
fi 
