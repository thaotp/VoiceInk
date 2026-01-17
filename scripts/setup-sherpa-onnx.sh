#!/bin/bash
# Sherpa-Onnx Setup Script for VoiceInk
# This script copies dynamic libraries to the correct location for runtime linking

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHERPA_DIR="$PROJECT_DIR/VoiceInk/ThirdParty/sherpa-onnx-v1.12.23-onnxruntime-1.12.1-osx-universal2-shared"
FRAMEWORKS_DIR="$PROJECT_DIR/VoiceInk/Frameworks"

echo "Setting up Sherpa-Onnx for VoiceInk..."
echo "Project directory: $PROJECT_DIR"

# Create Frameworks directory
mkdir -p "$FRAMEWORKS_DIR"

# Copy dylibs to Frameworks directory
echo "Copying dynamic libraries..."
cp "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS_DIR/"
cp "$SHERPA_DIR/lib/libonnxruntime.1.12.1.dylib" "$FRAMEWORKS_DIR/"
ln -sf "libonnxruntime.1.12.1.dylib" "$FRAMEWORKS_DIR/libonnxruntime.dylib"

# Fix library paths using install_name_tool
echo "Fixing library paths..."
install_name_tool -change "@rpath/libonnxruntime.1.12.1.dylib" "@executable_path/../Frameworks/libonnxruntime.1.12.1.dylib" "$FRAMEWORKS_DIR/libsherpa-onnx-c-api.dylib"
install_name_tool -id "@executable_path/../Frameworks/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS_DIR/libsherpa-onnx-c-api.dylib"
install_name_tool -id "@executable_path/../Frameworks/libonnxruntime.1.12.1.dylib" "$FRAMEWORKS_DIR/libonnxruntime.1.12.1.dylib"

echo ""
echo "✅ Dynamic libraries prepared!"
echo ""
echo "Next steps in Xcode:"
echo ""
echo "1. Add Frameworks to Xcode:"
echo "   - Drag VoiceInk/Frameworks folder into Xcode project"
echo "   - Add both .dylib files to 'Embed & Sign' in General → Frameworks"
echo ""
echo "2. Add Models to Bundle:"
echo "   - Drag VoiceInk/Resources/SherpaOnnxModels into Xcode Resources"
echo "   - Check 'Copy items if needed' and add to VoiceInk target"
echo ""
echo "3. Configure Bridging Header:"
echo "   - Build Settings → Swift Compiler → Objective-C Bridging Header"
echo "   - Set to: VoiceInk/SherpaOnnx-Bridging-Header.h"
echo ""
echo "4. Configure Header Search Paths:"
echo "   - Build Settings → Header Search Paths"
echo "   - Add: \$(PROJECT_DIR)/VoiceInk/ThirdParty/sherpa-onnx-v1.12.23-onnxruntime-1.12.1-osx-universal2-shared/include"
echo ""
echo "5. Build and Run!"
