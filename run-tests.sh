#!/bin/bash
# Runs the test suite.
#
# The extra flags exist because swift-testing ships inside the Command Line
# Tools rather than the toolchain's default search paths, so a machine without
# full Xcode cannot find the framework or its interop dylib on its own.
set -euo pipefail
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIBS=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [ -d "$FRAMEWORKS/Testing.framework" ] && ! xcode-select -p | grep -q "Xcode.app"; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$LIBS" \
    "$@"
fi
exec swift test "$@"
