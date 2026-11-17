#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation Tests/ProtocolTests.m Sources/VOTProtocol.m -Wl,-export_dynamic -o build/protocol-tests
./build/protocol-tests
xcrun clang -Wall -Wextra -Werror Tests/SyncTests.c Sources/VOTSync.c -Wl,-export_dynamic -o build/sync-tests
./build/sync-tests
xcrun clang -Wall -Wextra -Werror Tests/SmoothSyncTests.c Sources/VOTSync.c -Wl,-export_dynamic -o build/smooth-sync-tests
./build/smooth-sync-tests
xcrun clang -Wall -Wextra -Werror Tests/PlaybackStateTests.c Sources/VOTPlaybackState.c -Wl,-export_dynamic -o build/playback-state-tests
./build/playback-state-tests
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-nonnull -Wno-arc-performSelector-leaks -framework Foundation Tests/StartupGuardTests.m Sources/VOTStartupGuard.m -Wl,-export_dynamic -o build/startup-tests
./build/startup-tests
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -ISources Tests/ClientTests.m Sources/VOTClient.m Sources/VOTProtocol.m Sources/VOTSubtitles.m -o build/client-tests
./build/client-tests
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -ISources Tests/SubtitleTests.m Sources/VOTSubtitles.m Sources/VOTProtocol.m -Wl,-export_dynamic -o build/subtitle-tests
./build/subtitle-tests
python3 -m unittest discover -s Tests -p 'test_*.py'
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0 -dynamiclib \
  -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework AVFoundation -framework QuartzCore -framework CoreGraphics -framework CoreMedia -framework WebKit \
  -install_name @rpath/YouTubeVOT.dylib Sources/VOTProtocol.m Sources/VOTClient.m Sources/VOTSubtitles.m Sources/VOTSettingsController.m Sources/VOTStartupGuard.m Sources/VOTTweak.m Sources/VOTSync.c Sources/VOTPlaybackState.c \
  -o build/YouTubeVOT.dylib
codesign --force --sign - build/YouTubeVOT.dylib
