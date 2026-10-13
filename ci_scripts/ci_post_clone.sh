#!/bin/sh
set -u

# Xcode Cloud images may not include the separately installed Metal compiler.
if xcrun --sdk iphoneos metal --version >/dev/null 2>&1; then
    echo "Metal toolchain already available"
else
    xcodebuild -downloadComponent MetalToolchain || echo "warning: MetalToolchain download failed (exit $?)"
fi
xcrun --sdk iphoneos metal --version || echo "warning: metal compiler still unavailable"
exit 0
