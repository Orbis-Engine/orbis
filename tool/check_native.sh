#!/bin/bash
# Compiles and runs the core's own C++ checks, without Dart in the way.
set -euo pipefail
cd "$(dirname "$0")/../packages/orbis_core"
clang++ -std=c++17 -O2 -Wall -Wextra -Iinclude -Isrc \
  src/world.cpp src/orbis_core.cpp src/orbis_native_test.cpp -o /tmp/orbis_core_check
/tmp/orbis_core_check
