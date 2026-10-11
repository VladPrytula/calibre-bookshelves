#!/bin/sh
# Runs the Lua checks in a disposable Lua 5.1 container (no network, read-only mounts).
# The koreader/kosync image is used only because it ships Lua 5.1, lua-cjson and luafilesystem.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${LUA_TEST_IMAGE:-koreader/kosync@sha256:bb3f13615365703315a43b9059f65e71e876440f867e23a42bf27f2fa18264e1}
docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  -v "$ROOT/calibre-bookshelf.koplugin:/plugin:ro" \
  -v "$ROOT/tests:/tests:ro" \
  -v "$ROOT/docs:/docs:ro" \
  --entrypoint sh "$IMAGE" -eu -c '
    lua /tests/test_core.lua
    lua /tests/test_categories.lua
    lua /tests/test_book_grid.lua
    lua /tests/test_integration.lua
    lua /tests/test_sample_catalogue.lua
  '
