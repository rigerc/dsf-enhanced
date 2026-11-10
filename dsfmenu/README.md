# DSF menu

An in-game menu and trainer for Driver: San Francisco, in Lua, on DriverNGHook. Settings for DSF Enhanced and Felony Rework are in it too.

- **F2** opens DriverNGHook's menu bar. The DSF menu fills its menus:
  - File, View, World, Game and Utilities;
  - a Trainer menu;
  - settings windows for DSF Enhanced (`dsf_enhanced.ini`) and Felony Rework (its config).
- **Hold D-pad up** while driving or in Shift: the controller menu. It is drawn in the game's own HUD by default, like Snoopii's Mod Menu. The menu's Menu style setting switches to three rows or an overlay window.

It needs DriverNGHook in the game: Felony Rework 2.3 installs one, the 2023 build with the sol2 ImGui binding.

## Install

On Linux, with the game closed:

```sh
dsfmenu/install.sh                                   # Steam's default game folder
dsfmenu/install.sh "/path/to/Driver San Francisco"
dsfmenu/install.sh --uninstall
```

The script does three things:

- copies `lua/dsfmenu.lua` and `lua/dsfmenu_trainer.lua` into `Common/UserLuaScripts`;
- adds one line to `bootstrap.lua`, and the menu's hooks to DriverNGHook's `plugins/DriverNGHook/scripts/driverNGHookMenu.lua`. It backs both up first, into `_dsfmenu_backup/`;
- makes `DSFMenu` in the game's Proton prefix (`Documents/Ubisoft/Driver San Francisco`), with links to `dsf_enhanced.ini` and Felony Rework's `felonyreworkconfig.txt`. The game's Lua can write only to that Documents folder (its `HDD:` device), so the menu saves settings through those links.

Running it again updates the Lua files and changes nothing else. `--uninstall` takes the hooks and the links out again.

On Windows, copy the two Lua files and make the same two edits by hand (see `install.sh`). For saving, make hard links in `Documents\Ubisoft\Driver San Francisco\DSFMenu`:

```bat
mklink /H dsf_enhanced.ini "<game>\dsf_enhanced.ini"
mklink /H felonyreworkconfig.txt "<game>\Common\UserLuaScripts\felonyrework\felonyreworkconfig.txt"
```

## Controller menu

| Button | |
|---|---|
| D-pad up/down | move |
| D-pad left/right | change a value |
| A | select |
| B | back; closes on the first page |
| X | save, on a settings page |
| LB/RB | a page up or down; on long lists (cars) 10 entries |
| Start | close |

The game is held while the menu is open. Actions that move or change your car run once it has closed.

## Trainer

- **Cheats:** horn boost, explosive horn, infinite Shift ability, no damage, no collision, infinite mass, add or take Willpower.
- **Vehicle:** repair (as the garage does), put back on its wheels, stop, siren, lights, dirt, open or remove panels, remove wheels, explode.
- **Cars:** pick from the game's own car list.
  - Swap into the car: it is loaded into the player-car slot.
  - Spawn it at the Shift cursor.
- **Traffic and people:**
  - traffic: no traffic, stopped or abandoned traffic, traffic events, suspicious vehicles, interesting vehicles, police patrols, special trailers, traffic sets;
  - pedestrians: no pedestrians, random sizes, convicts, civilian sets.
- **Teleport:** garages, places, the mission checkpoint.
- **Mission and wanted level:** clear the wanted level, stop a chase, complete, fail or quit the mission.
- **World:** game speed (and keeping it), weather, city unlock, building draw distance, reset props, Jericho's alleyway.
- **HUD:** hide the minimap or the UI.

Toggles that stay on are applied again every half second, because the game turns some of them back. The car toggles move to a new car after a Shift.

## Tests

```sh
dsfmenu/tests/run.sh
```

`tests/dsfmenu_mock.lua` runs both Lua files under stock Lua 5.1, with stand-ins for:

- DriverNGHook's ImGui binding, strict about argument types and counts as the real one is;
- the controller;
- the game's file system;
- the game systems the trainer calls.

It drives the menus and checks what they draw and call. The fixtures are this repository's `src/dsf_enhanced.ini` and a config in the form of Felony Rework's (`tests/fixtures`). The run also rejects number literals the game's Lua can't take: its numbers are 4-byte floats, and a literal over 8388606 stops the whole file from loading.

Things only the game shows aren't covered: what the HUD looks like, and whether a game call does what its name says. Those were checked in game: F2 menus, settings windows, saving, controller menu, HUD style, repair, car swap.

## Credits

The trainer's options follow Snoopii's Mod Menu, which credits FireBoyd78, Olanov, McNally, KekAnTing and VortexLeBelge. So does the HUD style: the helicopter text panel and the secondary prompt line. This is a separate implementation on the game's Lua API. DriverNGHook is by Soapy (ReHamster).
