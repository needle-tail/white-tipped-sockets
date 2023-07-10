#!/bin/sh

rm -rf build

echo 'building archive'

mkdir -p build

xcodebuild archive \
-project WhiteTippedSockets.xcodeproj \
-scheme WhiteTippedSockets \
-archivePath build/ios.xcarchive \
-destination "generic/platform=iOS"

xcodebuild archive \
-project WhiteTippedSockets.xcodeproj \
-scheme WhiteTippedSockets \
-archivePath build/simulator.xcarchive \
-destination "generic/platform=iOS Simulator"

xcodebuild archive \
-project WhiteTippedSockets.xcodeproj \
-scheme WhiteTippedSockets \
-archivePath build/macos.xcarchive \
-destination "generic/platform=macOS"

xcodebuild -create-xcframework \
-framework build/ios.xcarchive/Products/Library/Frameworks/WhiteTippedSockets.framework \
-framework build/simulator.xcarchive/Products/Library/Frameworks/WhiteTippedSockets.framework \
-framework build/macos.xcarchive/Products/Library/Frameworks/WhiteTippedSockets.framework \
-output build/WhiteTippedSockets.xcframework

echo 'archiving'
cd build
OUTPUT_NAME="WhiteTippedSockets.xcframework.zip"
zip --symlinks -r $OUTPUT_NAME WhiteTippedSockets.xcframework

