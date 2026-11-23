#!/usr/bin/env bash
#
# Build and install LoudFlow on a Mac that has the Command Line Tools but no Xcode.
#
# dev-build.sh needs xcodebuild. This calls swiftc directly instead: it compiles FluidAudio
# once (cached in build/noxcode), compiles the app, and puts the new binary into a copy of
# the app that is already in /Applications. The asset catalog can't be compiled without
# Xcode, so icons and fonts come from that installed copy. Change an asset and you need
# dev-build.sh.
#
#   scripts/build-without-xcode.sh            build, sign, install, relaunch
#   scripts/build-without-xcode.sh --no-install   stop after signing build/noxcode/LoudFlow.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

FLUID_VERSION="0.15.6"
NEMO_URL="https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.0/NemoTextProcessing.xcframework.zip"
NEMO_SHA="76d0ee9a32b1ee2193231299180ca9bc4fc7e98794e771b3d55d66498352d85f"

# SwiftUI in the macOS 27 SDK needs a macro plugin that only ships with Xcode.
SDK="${LOUDFLOW_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
TARGET="arm64-apple-macos14.2"
TEMPLATE="${LOUDFLOW_TEMPLATE:-/Applications/LoudFlow.app}"
OUT="build/noxcode"
FLUID="$OUT/FluidAudio-$FLUID_VERSION"
NEMO="$OUT/NemoTextProcessing.xcframework/macos-arm64_x86_64"
APP="$OUT/LoudFlow.app"

IDENTITY="${LOUDFLOW_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" && -s build/signing-identity ]]; then
  IFS= read -r IDENTITY < build/signing-identity
fi
IDENTITY="${IDENTITY:-LoudFlow Self-Signed}"

[[ -d "$SDK" ]] || { echo "No SDK at $SDK. Set LOUDFLOW_SDK." >&2; exit 1; }
[[ -d "$TEMPLATE" ]] || { echo "No app at $TEMPLATE to take icons and fonts from. Set LOUDFLOW_TEMPLATE." >&2; exit 1; }
mkdir -p "$OUT"

if [[ ! -d "$FLUID" ]]; then
  echo "==> Fetching FluidAudio ${FLUID_VERSION}…"
  git clone -q --depth 1 --branch "v$FLUID_VERSION" https://github.com/FluidInference/FluidAudio "$FLUID"
fi
if [[ ! -f "$NEMO/libtext_processing_rs.a" ]]; then
  echo "==> Fetching NemoTextProcessing…"
  curl -fsSL "$NEMO_URL" -o "$OUT/nemo.zip"
  echo "$NEMO_SHA  $OUT/nemo.zip" | shasum -a 256 -c - >/dev/null
  ditto -x -k "$OUT/nemo.zip" "$OUT"
  rm "$OUT/nemo.zip"
fi

INCLUDES=(-I "$FLUID/Sources/FastClusterWrapper/include" -I "$FLUID/Sources/MachTaskSelfWrapper/include" -I "$NEMO/Headers")

if [[ ! -f "$OUT/FluidAudio.o" || ! -f "$OUT/FluidAudio.swiftmodule" ]]; then
  echo "==> Compiling FluidAudio (once, a few minutes)…"
  clang++ -std=c++17 -O2 -target "$TARGET" -isysroot "$SDK" -I "$FLUID/Sources/FastClusterWrapper/include" \
    -c "$FLUID/Sources/FastClusterWrapper/FastClusterWrapper.cpp" -o "$OUT/FastClusterWrapper.o"
  clang -O2 -target "$TARGET" -isysroot "$SDK" -I "$FLUID/Sources/MachTaskSelfWrapper/include" \
    -c "$FLUID/Sources/MachTaskSelfWrapper/MachTaskSelf.c" -o "$OUT/MachTaskSelfWrapper.o"
  # What SwiftPM would generate for the package's resources.
  cat > "$OUT/FluidAudioBundle.swift" <<'EOF'
import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let name = "FluidAudio_FluidAudio.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
            if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        fatalError("FluidAudio resources are missing from the app")
    }()
}
EOF
  find "$FLUID/Sources/FluidAudio" -name '*.swift' | sort > "$OUT/fluid-sources.txt"
  echo "$OUT/FluidAudioBundle.swift" >> "$OUT/fluid-sources.txt"
  rm -f "$OUT/FluidAudio.o"
  swiftc -O -wmo -parse-as-library -module-name FluidAudio -swift-version 6 \
    -target "$TARGET" -sdk "$SDK" "${INCLUDES[@]}" -suppress-warnings \
    -emit-module -emit-module-path "$OUT/FluidAudio.swiftmodule" \
    -emit-object -o "$OUT/FluidAudio.o" @"$OUT/fluid-sources.txt"
fi

echo "==> Compiling LoudFlow…"
find Sources/LoudFlow -name '*.swift' | sort > "$OUT/app-sources.txt"
swiftc -O -wmo -parse-as-library -module-name LoudFlow -swift-version 5 \
  -target "$TARGET" -sdk "$SDK" -I "$OUT" "${INCLUDES[@]}" \
  @"$OUT/app-sources.txt" \
  "$OUT/FluidAudio.o" "$OUT/FastClusterWrapper.o" "$OUT/MachTaskSelfWrapper.o" "$NEMO/libtext_processing_rs.a" \
  -lc++ -o "$OUT/LoudFlow" 2> "$OUT/app-build.log" \
  || { echo "BUILD FAILED:"; grep -A6 "error:" "$OUT/app-build.log" | head -60; exit 1; }

echo "==> Assembling the app…"
VER=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)
rm -rf "$APP"
ditto "$TEMPLATE" "$APP"
rm -rf "$APP/Contents/_CodeSignature"
cp "$OUT/LoudFlow" "$APP/Contents/MacOS/LoudFlow"
# Debug entries carry this Mac's folder paths. The app doesn't need them.
strip -S "$APP/Contents/MacOS/LoudFlow" 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Keep one code identity across builds so macOS can keep the Accessibility grant.
echo "==> Signing…"
if ! codesign --force --deep --sign "$IDENTITY" "$APP"; then
  echo "Signing failed. Set LOUDFLOW_SIGNING_IDENTITY to a certificate fingerprint or run scripts/dev-signing-setup.sh, then retry." >&2
  exit 1
fi

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Done: LoudFlow $VER ($BUILD) at $APP (not installed)"
  exit 0
fi

AUDIO="$HOME/Library/Application Support/LoudFlow/audio"
if ls "$AUDIO"/*.mic.caf >/dev/null 2>&1 && pgrep -f "/Applications/LoudFlow.app/Contents/MacOS/LoudFlow" >/dev/null; then
  echo "LoudFlow is recording. Stop the recording, then run this again. The new build is at $APP." >&2
  exit 1
fi

echo "==> Installing to /Applications…"
pkill -f "/Applications/LoudFlow.app/Contents/MacOS/LoudFlow" 2>/dev/null || true
sleep 1
rm -rf /Applications/LoudFlow.app
ditto "$APP" /Applications/LoudFlow.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/LoudFlow.app || true
open /Applications/LoudFlow.app

echo ""
echo "Done: LoudFlow $VER ($BUILD) installed and relaunched"
codesign -dv --verbose=2 /Applications/LoudFlow.app 2>&1 | grep -E "Authority|Signature=" | head -2
