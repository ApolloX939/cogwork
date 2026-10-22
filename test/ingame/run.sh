#!/bin/sh
# Runs Cogwork's in-game checks on a throwaway world of one game.
# Usage: test/ingame/run.sh <game>   game: skyblock_zero (the test server's copy
#        in the docker/luanti server dir) or any game in ~/.minetest/games
# Prints the "SBT ..." lines; exit status 1 on any FAIL or when it did not finish.
set -e
HERE=$(dirname "$(readlink -f "$0")")
MOD=$(readlink -f "$HERE/../..")
SERVER=${LUANTI_SERVER:-$HOME/dev/docker/luanti/luanti_server}
GAME=$1
[ -n "$GAME" ] || { echo "usage: $0 <game>"; exit 1; }
WORK=${SBT_WORK:-/tmp/cogwork-test-$GAME}
rm -rf "$WORK"; mkdir -p "$WORK/world" "$WORK/mod_data"; touch "$WORK/debug.txt"

if [ "$GAME" = skyblock_zero ]; then
    GAMEDIR=$SERVER/data/games/skyblock_zero
else
    GAMEDIR=$HOME/.minetest/games/$GAME
fi
[ -d "$GAMEDIR" ] || { echo "no game $GAMEDIR"; exit 1; }

# EXTRA_MODS="ggraffiti flow": other mods from ~/.minetest/mods to load next to Cogwork
EXTRA_ARGS=""
EXTRA_LOAD=""
for m in $EXTRA_MODS; do
    EXTRA_ARGS="$EXTRA_ARGS -v $HOME/.minetest/mods/$m:/minetest/mods/$m:ro"
    EXTRA_LOAD="${EXTRA_LOAD}load_mod_$m = true\n"
done
printf 'gameid = %s\nbackend = sqlite3\nmod_storage_backend = sqlite3\nauth_backend = sqlite3\nplayer_backend = sqlite3\nload_mod_cogwork = true\nload_mod_cogwork_test = true\n'"$EXTRA_LOAD" "$GAME" > "$WORK/world/world.mt"
printf 'server_announce = false\nmg_name = singlenode\nenable_damage = false\nmax_forceloaded_blocks = 200\ncogwork_move_delay = 0.1\ncogwork_action_delay = 0.1\n' > "$WORK/minetest.conf"
[ "$GAME" = skyblock_zero ] && cat "$SERVER/data/minetest.conf" | grep -v '^mg_\|^server_announce\|^map-dir' >> "$WORK/minetest.conf" || true

docker run --rm --user 1000:1000 ${SBT_TRACE:+-e SBT_TRACE=1} \
    -v "$WORK/minetest.conf:/minetest/minetest.conf:ro" \
    -v "$WORK/world:/minetest/worlds/world" \
    -v "$WORK/debug.txt:/minetest/debug.txt" \
    -v "$WORK/mod_data:/minetest/mod_data" \
    -v "$GAMEDIR:/minetest/games/$GAME:ro" \
    $EXTRA_ARGS \
    -v "$MOD:/minetest/mods/cogwork:ro" \
    -v "$MOD/test/ingame/cogwork_test:/minetest/mods/cogwork_test:ro" \
    luanti ./bin/server --world /minetest/worlds/world --config /minetest/minetest.conf \
    > "$WORK/server.log" 2>&1 || true

grep -h "^SBT\|ERROR\|WARNING.*cogwork\|cogwork\]" "$WORK/server.log" | grep -v "^SBT PASS" | head -60
echo "passed: $(grep -c '^SBT PASS' "$WORK/server.log")"
grep -q "^SBT DONE" "$WORK/server.log" || { echo "DID NOT FINISH (see $WORK/server.log)"; exit 1; }
! grep -q "^SBT FAIL" "$WORK/server.log"
