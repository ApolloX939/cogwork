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
  command from the palette on the right: the category row scrolls sideways
  (flow, chat, move, world, items and parts, variables and values, conditions,
  machines and structure, functions), click a block to select it, change it with the
  options row or by typing into the value field (`Set` replaces the selected
  block, `Add after` inserts), or click an item to use it as a block. The
  toolbar under the sheet inserts, deletes, duplicates, indents and moves
  lines and blocks. The power button runs it; the second button keeps the
  area loaded while it works.
- **Text tab**: the same program as plain text (two spaces per indent level).
  Edit it there and press Apply.
- **Storage tab**: the robot's storage, 8 x 2 slots, 4 more for every Storage Upgrade (up to 40).
- **Structure tab**: armor, armor modification, power cells, power augmentation and
  the six upgrade slots (see below).
- **Packages tab**: browse packages, copy one (or your own functions) to a
  disk, install a disk in the robot.
- **Settings tab**: name, public/private.
- You point at a robot's model: its hitbox is the shape of the robot, hover pad or drone. Right-click opens it. To pick one up, punch it with a tool that can dig it (a few punches in a row, like digging a block).
- Sneak + right-click a robot to go into it (see Inside a robot); sneak + punch a running one to stop it.
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
name it, put a blank Package Disk in the robot's disk slot and press *My
functions to disk* (it writes onto the disk in the slot and uses no extra
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
| `events.register_nodes h` | `dir block change detail`: something changed in one of the six blocks next to the robot (`front back left right up down`), see below |
| `events.register_entities r h` | `name distance`: a non-item entity or a player came within `r` blocks |
| `events.register_items r h` | `item count distance`: a dropped item came within `r` blocks |
| `events.register_chat h` | `player message`: a public chat message |
| `events.register_whisper h` | `player message`: a private message, sent with `/bot <robot name> <message>` (quote names with spaces) |
| `events.register_bot h` | `from message`: another robot's message, `from` is `Owner/RobotName` |

**What a `nodes` handler hears** (`change`, `detail`; `block` is the node name):

| change | when | detail |
|---|---|---|
| `node` | the block was replaced | the name it had |
| `inventory` | a list in its inventory changed (chest, furnace, another robot) | the list's name |
| `timer` | its node timer started, stopped, or ran out and restarted | `started` `stopped` `restarted` |
| `state` | its machine switched | `on`, `off`, or the machine's own word |
| `power` | the charge of its battery, or of the batteries of its network, changed | percent |

The first scan after registering only learns what is there. Machines are read
through `sbz_power` (batteries, machines, network supply/demand), `technic`
(`<TIER>_EU_*` fields; a battery box's charge is known in eighths) and
`techage` (`state`, `delivered` and `load` of its node number), whichever of
them is installed. At most 8 changes are handled per scan.

To read a neighbour yourself (all give `-1` when unknown, `""` for
`machine_state` when the block is not a machine): `machine_state`,
`machine_power`, `machine_capacity`, `machine_level` (percent),
`machine_supply`, `machine_demand`, `network_level` (percent of the network's
batteries), `node_timer` (seconds left), `node_stock dir [item]` (items in its
inventory), each with a direction. `machine_switch front "off"` turns the
machine on or off (it respects protection). A robot that watches a battery can
tell another one:

```
use events
fn on_block dir block change detail
  if change = "power"
    if detail < 20
      tell_bot "Switcher" "off"
```

The other robot's `register_bot` handler then does `machine_switch front message`.

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

### Upgrades

Every robot has six upgrade slots (Structure tab). Without upgrades a robot can
be 1 block above the floor, the nearest block that is not free below it (`move`
refuses to go higher, and so does the pathfinder, which plans within the same
limit). A **Hover Upgrade** adds a block each (up to 7 with six), a **Flight
Upgrade** removes the limit. `height_limit` is the allowed number of blocks, `-1`
when flying. Robots placed before upgrades existed get their slots when the
Structure tab is opened, and fall under the limit like any other.

A robot with a **Flight Upgrade** looks like a drone (its own model; it changes
as the upgrade goes in or out). The limit never keeps a robot from going down,
and next to a block it may hold on: it can go along a wall, and up from a cell
that has a block beside it, so a robot that dug a shaft with `mining.shaft`
climbs back out with `mining.climb`. The pathfinder plans with the same moves.

| upgrade | recipe |
|---|---|
| Hover | Skyblock: Zero: matter plates, a Simple Processor, an Emitter and circuits. Other games: glass, steel and coal |
| Flight | Skyblock: Zero: four Hover Upgrades around two antimatter plates, two retaining circuits and an emittrium circuit. Other games: four Hover Upgrades, gold, diamonds and steel |

### Structure: armor, power and parts

Open the **Structure** tab: one **armor** slot, one **armor modification**
slot, two **power cell** slots and one **power augmentation** slot.

- **A robot only runs with armor and a power cell that has charge.** Without
  them it stays off (the power button and a program's start refuse, with the
  reason), and a running robot stops when the armor is taken out or the cells
  run dry. A robot item that was never placed (crafted, `/give`, creative) comes
  with a Basic Armor and one full Small cell the first time it is placed, and
  from then on the robot (and the item it is dug into) carries `no_emc` so the
  free parts cannot be turned into EMC; placing it again gives nothing more.
  Robots placed before this existed get the same starter parts, once.
- **Power cells** (tools, so the wear bar is the charge): Small 450, Medium 950,
  Large 1400, Huge 2200, Colossal 3200 operations. Every action costs power: a
  move 1, turn 0.5, dig 2, place 1, punch 2, craft 3, pull/put/drop 0.5, chat 0.2,
  a pathfinding step 1, waiting for events a trickle; queries are free. A new
  cell is full; the charge stays with the item.
- **Armor** (Basic 24, Reinforced 31, Heavy 38 durability) takes damage
  from other players' weapons (the weapon's damage, a sword hit of 6 costs 6; the
  owner's punches and cassettes do none) and **never breaks**: at no durability it protects nothing
  and the damage goes to the power cells. Liquids never hurt a robot.
- **Self-Repair Module** (armor modification) mends 1 durability every 5 seconds
  for 1 power (the lightest armor is whole again after two minutes).
- **Power augmentation:** the **Creative Capacitor** (creative only, no recipe)
  fills the cells at once and keeps them full, free power. The **Self-Generator**
  (very, very, very expensive: a Colossal cell wrapped in emittrium and
  antimatter, or six diamonds) charges **one** cell, the first that is not full,
  by `cogwork_generator_amount` (10) every `cogwork_generator_interval` (5, at
  least 5) seconds, also while the robot is off.
- **Combat Upgrade** (an upgrade slot part, somewhat expensive): `punch` may hit
  players, never the owner, only where pvp and damage are on and with the owner
  online (the owner is credited). Every Combat Upgrade after the first makes
  the punch reach one block further in its direction (it stops at a block in
  the way or a protected one), for players and other entities alike.

A program can change parts from its own storage: `install "armor_mod"`,
`install "augment"`, `install "cell"` (into a free cell slot) and the same with
`uninstall`. It can take out **one** cell only while another stays in, and never
the armor. `battery_level` and `armor_level` are percent (`armor_level` is -1
without armor), `cell_count`, `structure_item "armor"` (also `armor_mod`,
`augment`, `cell1`, `cell2`) the name in a slot.

### Chargers

A **Charger** is a block: a robot standing on top gets its power cells
charged, whether it runs or not. Every cell that is not full takes 25 units a
second, and a charger draws that for each cell it charges, so two cells draw
twice as much. A Creative Capacitor already keeps its cells full.

| charger | power comes from |
|---|---|
| **Charger** (`cogwork:charger`) | its source slot: a spare Power Cell (a tenth is lost moving the charge), or, with Technic, a **battery or energy crystal item** (1 EU is 0.1 units). No network needed |
| **LV Charger** | Technic LV network, 150 EU a second per cell: the network's batteries feed it |
| **MV Charger** | Technic MV network, 100 EU a second per cell: less for the same charge |
| **TA Charger** | Techage electric cable, 4 units per 2 second cycle per cell, from the network's pool |
| **Power Charger** | Skyblock: Zero power network, 12 a second per cell; with little power to spare it charges fewer cells |

Techage's batteries (Akkus) have no way to charge an item directly: they only
feed the network's pool through its cables, which is what the TA Charger takes
from. Every other charger is crafted from the plain Charger and a part of that
power system (Technic cable and casing, Techage cables, a processor in
Skyblock: Zero). The Technic and Techage chargers exist only when those mods
are installed.

### Inside a robot

**Sneak + right-click** a robot to go into it (you need access to it, as for the editor;
with `cogwork_rooms` off it opens the editor like a plain right-click). Every
robot you enter gets a room of its own: a lit steel chamber (16 x 10 x 16) far
away in the map, that goes with the robot (its id is in the robot and in its item
when dug) while the robot itself moves. The door leaves, next to the robot
(`/leave_robot` too). Whoever is inside keeps the robot's block loaded, and
comes out where the robot stood if it is dug.

- **Viewscreen**, on the far wall (8 x 5 blocks): what the robot sees, drawn as a
  picture. One ray per pixel from the robot's eye: every block exactly for the
  first 36, then coarser steps (2, 4, 8 blocks) out to `cogwork_view_range`
  (96), so far terrain shows. A hit takes the real average colour of the node's
  texture (the mods' texture files are read once, with a small PNG reader in
  `src/png.lua`), shaded by face, light and distance; sky above, haze where
  nothing is loaded. Blocks nobody is near are loaded from disk (never generated)
  as needed, and what was seen is kept for half a minute so the picture does not
  flicker as the engine unloads blocks. Players (blue) and other entities
  (orange) in range are drawn as boxes of their size, the 24 nearest, in front
  of the terrain behind them; dropped items and robots' own bodies are not. The picture is drawn in slices of 4 ms
  per server step, only while somebody is inside, every `cogwork_view_interval`
  seconds (2), `cogwork_view_width` x `cogwork_view_height` (64 x 40) pixels, and
  put on a screen entity as a `[png:` texture, the way ggraffiti draws its
  canvases. It works next to ggraffiti: its screen is its own entity, and the
  room is protected, so nobody sprays on the walls.
- **Chest**: the robot's storage. **Structure bay**: armor, cells, augmentation and
  upgrades. **Terminal**: the program, to program a robot in peace. **Settings
  panel**: name, public, the allow list and the entrance lock. (All four are the
  editor, at its Storage, Structure, Program and Settings tab.)
- **Entrance lock** (Settings tab): who may go in with sneak + right-click. *Anyone who
  can use the robot* (the default, as before), *Owner and the players allowed
  here* (the players of the allow list: `Player` and `Player/Robot` both let
  `Player` in) or *Owner only*. Admins with `protection_bypass` always pass.
  Locking the room puts out whoever it no longer lets in. The lock goes with the
  robot when it is dug.
- **Controller**: forward, back, up, down, turn left, right and around, and run or
  stop the program. It drives like a program does: power cost, cooldown, height
  limit, protection; it will not drive a running robot. **Drive with the keys**
  closes the window and lets you drive with W S (forward, back), A D (turn), Space
  (up) and Shift (down); hold Space and Shift together for a moment to let go
  (so does the door, `/leave_robot` and leaving the game). While you do, you stand
  still and a line at the bottom shows the robot's place and power. **Fly mode**
  (a checkbox on the controller) keeps the robot from falling while it is being
  controlled (until 20 s after the last move); it falls again after that.
- **Camera controller**: turns and tilts the viewscreen's camera, by buttons or by
  the keys (A D turn, W S tilt, Space back to the front, hold Space + Shift to let
  go). The camera is saved with the robot (`view_yaw`, `view_pitch`) and looks up
  to 85 degrees up or down; the robot's own front, digging and moving do not change.

Rooms are out of the way of the room container mods. `area_containers` keeps its
rooms at the top of the map and Skyblock: Zero's room containers between y -28000
and -15000; Cogwork's are at the bottom (about y -29500), and each slot is checked
against Skyblock: Zero's room list. The two never run together; Cogwork runs
beside either of them. Rooms are protected from digging, building and painting.

### Storage

A robot holds 16 stacks (8 x 2). A **Storage Upgrade** (upgrade slot, six at
most) adds 4 stacks each: up to 40. It cannot be taken out while the slots it
gives hold items (empty them first); robots from before, which had 32 slots,
keep the slots up to their last item and shrink once those are empty.
Recipe: a chest between steel, copper and steel (matter plates, circuits and a
processor in Skyblock: Zero).

### The robot is an entity

What you see is an entity standing on the robot's block (`src/visual.lua`); the
block itself is invisible and is the robot's body for the game (its storage,
program, forceload, protection and your hand). The entity shows the robot,
hover or drone model with its face lit while it runs, turned the way the robot
faces, and glides when the robot moves or falls. A **drone's four rotors are
entities of their own and spin while it runs**, and stop when it stops. A robot
that flies or hovers (a free block under it) gives off a few **thruster
particles** (`cogwork_particles`). Entities are not saved: they are made again
when the block loads, and one whose robot is gone removes itself. Robots are not
entities to each other: `entity`, `punch` and the entity event skip them.

### Hover model, gravity and water

A robot that is not a drone and has a free block under it is drawn with the
**hover model** (no treads, thrusters under it); it goes back to the rolling
model as soon as there is a block under it again. The model follows moves, a
dug or placed floor, start and stop.

**Gravity.** A robot that is not running falls to the floor, a block at a time.
It only falls when there is a floor (or water to float in) within
`cogwork_fall_range` blocks (128) below it: robots over the void stay where they
are. Turn it off with `cogwork_gravity`. A running robot stays where its program
puts it.

**Liquids.** A robot may be in any liquid (water, lava, oil, the chemicals of Skyblock: Zero;
liquids never hurt it); it is then *flooded*, like a waterlogged block (the
robot's infotext says so). It remembers the water of its block, puts
it back when it moves on and when it is dug, and an empty bucket right-clicked
on a flooded robot fills with that liquid instead of opening the robot (Minetest
Game's `bucket`, Mineclonia's and VoxeLibre's `mcl_buckets`, Skyblock: Zero's
empty Fluid Cell, for every liquid those know; another bucket mod
can call `cogwork.register_bucket({ empty = "mod:empty", filled = function
(source) return "mod:full" end })`). 

`robots_can_float` (`cogwork_robots_can_float`, on by default): a stopped robot
drops into the liquid and floats in it, not above it. Off, it sinks to the
bottom. In the height limit, water holds a robot up only when robots can float.

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
