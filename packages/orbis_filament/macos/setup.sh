#!/bin/bash
# Moved to darwin/setup.sh, because it now serves both Apple platforms.
#
# This shim stays only until the editor and the examples repositories point at
# the new path — their CI calls this one, and their workflows live in
# repositories this commit cannot change. Removing it before then would turn
# their builds red for a move that has nothing to do with them.
exec bash "$(dirname "$0")/../darwin/setup.sh" "$@"
