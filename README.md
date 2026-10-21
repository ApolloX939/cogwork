# Cogwork

Block-programmable robots for Luanti, with **functions** and **packages**.
A new mod in the spirit of LWScratch (loosewheel): same idea, rewritten from
scratch, with new code, new textures and a different file format.

Works in Minetest Game style games, **Mineclonia**, **VoxeLibre**,
**Hades Revisited** and **Skyblock: Zero** (the recipe and the `@name` item
aliases adapt to the game).

## Using a robot

Craft a robot, place it (it looks the way you look), right-click it.

- **Program tab**: the program is a sheet of lines made of blocks. Pick a
  command from the palette on the right (flow, move, world, items,
  variables, values, functions), click a block to select it, change it with the
  options row or by typing into the value field (`Set` replaces the selected
  block, `Add after` inserts), or click an item to use it as a block. The
  toolbar under the sheet inserts, deletes, duplicates, indents and moves
  lines and blocks. The power button runs it; the second button keeps the
  area loaded while it works.
- **Text tab**: the same program as plain text (two spaces per indent level).
  Edit it there and press Apply.
- **Storage tab**: the robot's 32 slots.
- **Packages tab**: browse packages, copy one (or your own functions) to a
  disk, install a disk in the robot.
- **Settings tab**: name, public/private.
- Sneak + punch a running robot to stop it.
- **Cassette**: punch a robot with it to copy its program; sneak + right-click
  a robot to load it; right-click in the air for label and read-only.

Robots belong to whoever placed them (or are public). Digging respects
protection. A robot can be dug by hand in every supported game (by its owner, or anyone
if public); its program and name stay in the item and whatever was in its
storage comes out with it.

## The language

One command per line; lines indented further belong to the line above.

```
use mining
set rows = 3
repeat rows
  call tunnel 5
  turn right
if detect front @stone and contains @torch
  place up @torch
```

### Actions

| command | meaning |
|---|---|
| `move forward\|back\|up\|down` | move one block (`ok` tells if it worked) |
| `turn left\|right\|around` | turn |
| `dig <dir>` | dig; drops go to storage (or the world when full) |
| `place <dir> [item]` | place an item from storage (first node item if none) |
| `interact <dir>` | right-click the block (doors, buttons, ...) |
| `pull [item]` / `pull_stack [item]` | from the container in front into the robot |
| `put [item]` / `put_stack [item]` | from the robot into the container in front |
| `drop`, `drop_stack`, `trash`, `trash_stack` | into the world / destroy |
| `punch <dir> [item]` | with no item: pick up dropped items there, else hit the entity there bare-handed; with an item from storage: hit with that tool (it wears). Players are never hit |
| `craft <item>` | craft from the robot's storage |
| `wait n` | wait n tenths of a second |
| `chat text` | message to the owner, no limits |
| `say text` | public chat message (limited per player, see Events) |
| `whisper player text` | private chat message to a player (limited per player) |
| `tell_bot name text`, `tell_bots text` | message to other robots (see Events) |
| `stop` | end the program |

`<dir>` is `front front_up front_down back back_up back_down up down`.
Without an item, `pull/put/drop/trash` take everything; with one, a single
item (`_stack`: a whole stack). Items can be `group:name`.

### Values and conditions

`entity <dir>` (name of the entity in that block, `""` if none), `counter` (loop turn, from 0), `ok` (did the last action work), `detect <dir>
[item]`, `node <dir>`, `contains [item]`, `fits [item]`, `count item`,
`pos_x pos_y pos_z`, `facing`, `even n`, `odd n`, `floor n`, `length text`,
`random n`, numbers, `"text"`, items (`default:stone`, or `@stone`), `true`,
`false`, variables. Operators: `+ - * / %` (`+` joins text), `= != < > <= >=
matches`, `and or not`, brackets.

### Flow

`if cond` / `else` / `else if cond`, `loop cond`, `repeat n`, `forever`,
`break`, `continue`, `wait`, `stop`.

### Variables

`set x = expr`, `add x n`, `sub`, `mul`, `div`, `mod`, `join x text`. Names
cannot be command words.

### Functions

```
fn row n item
  repeat n
    place down item
    move forward

call row 5 @cobble
set s = call double 4      # in an expression
```

`call` takes its arguments as single blocks (use brackets for sums:
`call row (n + 1) item`; the last one may be a whole expression on a
statement line). `return value` gives a value back. Parameters and new
variables in a function are local; existing variables are still reachable.
Recursion works, 48 levels deep.

### Packages

A package is a library of functions. `use mining` makes its functions
available; `call mining.tunnel 5` works without `use`. Built in:

| package | functions |
|---|---|
| `movement` | `walk n`, `retreat n`, `rise n`, `sink n`, `bore n`, `patrol side` |
| `mining` | `tunnel n`, `shaft n`, `climb n`, `layer w d`, `quarry w d h` |
| `building` | `line n item`, `pave w d item`, `wall n h item` |
| `farming` | `plant_row n seed`, `harvest_row n`, `plant_field w d seed` |
| `storage` | `unload`, `load`, `take item n`, `give item n` |
| `math` | `abs min max sign clamp power` |
| `pathfind` | `goto x y z`, `goto_entity name`, `start`, `start_entity`, `step`, `left`, `cancel` |
| `events` | `register_nodes`, `register_entities r`, `register_items r`, `register_chat`, `register_whisper`, `register_bot`, `register kind r handler`, `process`, `leave` |

`/cogwork packages`, `/cogwork package <name>`, `/cogwork items` list them.

Players make their own: write functions in a program, open the Packages tab,
name it, put a blank Package Disk in the robot's disk slot and press *Write my
functions to the disk* (it writes onto the disk in the slot and uses no extra
disk). Put the disk in another robot's slot and *Install it*. A package may only contain `fn` and `use` lines.

### Events

A robot reacts to things instead of running a fixed route: register a handler
function by name for each kind of event, then call `events.process`, which
sits and handles events one at a time until a handler calls `events.leave`.

```
use events
fn on_item item count distance
  chat "dropped: " + item
fn on_chat player message
  if message matches "stop"
    call events.leave
call events.register_items 4 "on_item"
call events.register_chat "on_chat"
call events.process
```

| register | handler is called with |
|---|---|
| `events.register_nodes h` | `dir node`: one of the six blocks next to the robot (`front back left right up down`) changed |
| `events.register_entities r h` | `name distance`: a non-item entity or a player came within `r` blocks |
| `events.register_items r h` | `item count distance`: a dropped item came within `r` blocks |
| `events.register_chat h` | `player message`: a public chat message |
| `events.register_whisper h` | `player message`: a private message, sent with `/bot <robot name> <message>` (quote names with spaces) |
| `events.register_bot h` | `from message`: another robot's message, `from` is `Owner/RobotName` |

A handler may declare fewer parameters than shown. Registering a kind again
replaces its handler. `entities` and `items` take a radius from 1 up to
`cogwork_event_max_radius` (6); the nearer to the limit, the longer between
scans (`radius / max * cogwork_event_max_interval`, 3 s at the limit, never
under 0.5 s), so a wide watch reacts slower. Events pile up to 32 per robot.

**Chat limits.** `chat` (to the owner) and robot-to-robot messages have none.
`say` (public) is limited per owner and `whisper` per target player, and the
`chat` and `whisper` events accept so many messages per sending player and
robot: `cogwork_chat_limit` (5) within `cogwork_chat_window` (10) seconds.
Over the limit, messages are dropped (`ok` is false for `say` and `whisper`).
A robot only hears private messages from its owner, or from anyone if it is
public.

**Robot to robot.** `tell_bot "Name" text` reaches the running robots of that
name which called `events.register_bot` *and* allow the sender; `tell_bots
text` reaches all of them. A robot always hears robots of its own owner; for
others the owner lists them in the Settings tab: `Player` allows all of that
player's robots, `Player/RobotName` one. Also in the Settings tab: who is
listening to this robot right now. In a program, `listeners` is how many and
`listener n` the name of the nth.

### Punching

`punch front` picks up the dropped items in the block in front, or hits the
entity there. `punch front default:sword_steel` takes that tool from the
robot's storage and hits with it (`group:sword` works too); the tool wears and
the punch waits the tool's full punch interval. A robot never hits players and
respects protection. With the owner online the owner is credited as the
puncher. `entity front` tells which entity is there, so an event handler can
check it is the one to attack:

```
use events
use pathfind
fn on_entity name distance
  if name = "mobs_animal:rat"
    call pathfind.goto_entity name
    punch front default:sword_steel
```

### Pathfinding

`use pathfind` and `call pathfind.goto x y z` (or `goto_entity "name"`, which
stops next to the nearest entity or player of that name, searching
`cogwork_path_entity_radius` blocks) plans a route and walks it. The robot
moves in the six axis directions and needs no floor. The result is `0` when it
arrived and `-1` when there is no way: a sealed target, terrain nobody has
loaded, a route longer than `cogwork_path_max_nodes` cells of search, or a
target that disappeared.

The route is planned again every `cogwork_path_replan` seconds and whenever a
move is blocked, because the world (and the entity) change.

To do things on the way, plan and step yourself: `pathfind.start x y z` (or
`start_entity`) returns the steps to go (`-1`: no way) and `pathfind.step`
moves once and returns the steps left (`0` there, `-1` failed); `left` is the
steps left and `cancel` forgets the route.

Unloaded terrain counts as a wall, **unless the robot has Forceload on**: then
it is assumed to be open and the robot goes anyway. As it walks the forceload
moves with it, and blocks it walks into are loaded from disk or generated
(waiting up to 10 seconds for that). If the server's forceload limit is
reached on the way, the robot keeps going but is no longer forceloaded.

### Item aliases

`@stone @cobble @dirt @sand @gravel @glass @planks @log @sapling @torch @chest
@coal @stick @steel @copper @tin @gold @diamond @clay @paper @book` resolve
to the item of the game being played, so a program written in one game runs in
another. (`/cogwork items` shows what they are here.) Skyblock: Zero has no
stone or wood, so those fall back to its matter blob.

## For modders

```lua
cogwork.register_package({
    name = "tree_farm", title = "Tree farm", description = "...",
    source = "fn plant\n  place down @sapling\n",
})

cogwork.register_command({
    name = "scan", kind = "query", category = "check",
    args = { { type = "dir8" } },          -- dir8 dir4 turn val name; val may be optional = true
    run = function (ctx, dir) return ctx.bot:node(dir) end,
})
```

Actions return `ok, delay_seconds`. `ctx.bot` is the robot (`pos`, `owner`,
`inv()`, `target(dir)`, ...). Programs can only call registered commands.

## Settings

See `settingtypes.txt`: scheduler interval, action and move delays, public
chat, event radius and scan speed, chat limits, item `on_place` handlers, path search limit, re-plan interval and entity search radius, resume on start (off by default: robots
stop when the server restarts), statements per tick.

## Tests

- `luajit test/run.lua` - the language (needs LuaJIT or Lua 5.1; no engine).
- `test/ingame/run.sh <game>` - the robot, packages, forms and recipes on a
  throwaway world in the `luanti` docker image (`minetest_game`, `mineclonia`,
  `mineclone2`, `hades_revisited`, `skyblock_zero`).
- `python3 tools/gen_textures.py` redraws every texture and `src/icons.lua`.
