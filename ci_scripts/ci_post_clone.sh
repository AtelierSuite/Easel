#!/bin/sh
set -eu

# Xcode Cloud images may not include the separately installed Metal compiler.
xcodebuild -downloadComponent MetalToolchain
xcrun --sdk iphoneos metal --version
