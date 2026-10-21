#!/bin/sh
# Starts a throwaway server of one game with Cogwork and a demo that walks
# through the robot's form, for use with tools/client-test (screenshots):
#   test/ingame/demo.sh minetest_game        # leaves it running on port 30010
#   PORT=30010 tools/client-test/run.sh demoplayer demo-pw
#   tools/client-test/ui.sh shot.png         # now and every ~9 s
#   docker rm -f cogwork_demo luanti_client_test
set -e
HERE=$(dirname "$(readlink -f "$0")")
MOD=$(readlink -f "$HERE/../..")
SERVER=${LUANTI_SERVER:-$HOME/dev/docker/luanti/luanti_server}
GAME=${1:-minetest_game}
WORK=/tmp/cogwork-demo-$GAME
rm -rf "$WORK"; mkdir -p "$WORK/world" "$WORK/mod_data"; touch "$WORK/debug.txt"
if [ "$GAME" = skyblock_zero ]; then GAMEDIR=$SERVER/data/games/skyblock_zero; else GAMEDIR=$HOME/.minetest/games/$GAME; fi
printf 'gameid = %s\nbackend = sqlite3\nmod_storage_backend = sqlite3\nauth_backend = sqlite3\nplayer_backend = sqlite3\nload_mod_cogwork = true\nload_mod_cogwork_demo = true\n' "$GAME" > "$WORK/world/world.mt"
printf 'server_announce = false\nport = 30010\nmg_name = singlenode\nenable_damage = false\nserver_unload_unused_data_timeout = 3600\n' > "$WORK/minetest.conf"
docker rm -f cogwork_demo >/dev/null 2>&1 || true
docker run -d --name cogwork_demo --user 1000:1000 -p 30010:30010/udp \
    -v "$WORK/minetest.conf:/minetest/minetest.conf:ro" -v "$WORK/world:/minetest/worlds/world" \
    -v "$WORK/debug.txt:/minetest/debug.txt" -v "$WORK/mod_data:/minetest/mod_data" \
    -v "$GAMEDIR:/minetest/games/$GAME:ro" -v "$MOD:/minetest/mods/cogwork:ro" \
    -v "$MOD/test/ingame/cogwork_demo:/minetest/mods/cogwork_demo:ro" \
    luanti ./bin/server --world /minetest/worlds/world --config /minetest/minetest.conf >/dev/null
echo "server up on 30010 (docker logs cogwork_demo)"
