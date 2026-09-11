#!/bin/bash
# Regenerates the renderer's C++ core from an OrbisRenderer.mm in the old,
# Objective-C shape.
#
#   port.sh <an OrbisRenderer.mm from before the move>
#
# For a branch cut before the renderer moved into C++ that changed
# OrbisRenderer.mm: merge it, resolve OrbisRenderer.mm by keeping the wrapper
# (`git checkout --ours`), then run this on the branch's own copy of the old
# file (`git show <branch>:<path>/OrbisRenderer.mm > /tmp/old.mm`). It writes
# OrbisRendererCore.h and OrbisRendererCore.cpp with the branch's changes in
# the functions they were made in. This is how god rays, distortion and
# motion blur came across.
#
# It is the same conversion that made the core, run again: convert.py turns
# methods into member functions and message sends into calls, header.py turns
# the ivar block into members, and fix.py applies the hand conversions — the
# Apple calls replaced by the platform layer — which it finds by their exact
# text. So it only works while that text is still the text: a branch that
# edited one of those lines is told so (EXPECTED ... FOUND 0) and that hunk is
# ported by hand. Three things it cannot see, and which need doing by hand:
#
#   - a new #include among the generated material includes goes into
#     OrbisRendererCore.h.in, beside the ScreenEffects and motion blur ones;
#   - a new method in include/OrbisRenderer.h goes into the public section of
#     OrbisRendererCore.h.in and API in header.py, and gets a one-line
#     forwarder in OrbisRenderer.mm;
#   - anything Apple-only in the branch's new code (NSLog, NSString, NSData)
#     is a compile error to replace with orbis::log, std::string and
#     orbis::readFile.
#
# Once the branches cut before the move have landed, the core should be
# edited directly and this directory deleted: regenerating would throw away
# any change made to the C++ since.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
native="$here/../../darwin/orbis_filament/Sources/orbis_filament_native"
old="${1:?usage: port.sh <an OrbisRenderer.mm from before the move>}"
work="$(mktemp -d)"

python3 "$here/convert.py" "$old" "$work/methods.cpp" "$work/decls.txt" \
  "$work/prelude.h"
cp "$here/OrbisRendererCore.h.in" "$work/OrbisRendererCore.h.in"
python3 "$here/header.py" "$old" "$work/prelude.h" "$work/decls.txt" \
  "$work/OrbisRendererCore.h"
{
  cat "$here/core_prologue.cpp" "$work/methods.cpp"
  printf '\n}  // namespace orbis\n'
} > "$work/OrbisRendererCore.cpp"
python3 "$here/fix.py" "$work/OrbisRendererCore.cpp" "$here/replacements.cpp"

cp "$work/OrbisRendererCore.h" "$work/OrbisRendererCore.cpp" "$native/"
echo "wrote OrbisRendererCore.h and OrbisRendererCore.cpp; diff them before"
echo "committing — only the branch's own changes should show."
