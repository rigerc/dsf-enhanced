#!/usr/bin/env bash
# Installs the DSF menu (dsfmenu/lua) into Driver: San Francisco, or takes it out again.
#
#   dsfmenu/install.sh [GAME_DIR]               install, or update an installed copy
#   dsfmenu/install.sh --uninstall [GAME_DIR]   take it out
#
# GAME_DIR defaults to Steam's ~/.local/share/Steam/steamapps/common/Driver San Francisco.
# Needs DriverNGHook in the game (plugins/DriverNGHook, and Common/UserLuaScripts/bootstrap.lua);
# Felony Rework installs one. Run it with the game closed. Needs python3.
#
# What it does:
#  - copies dsfmenu.lua and dsfmenu_trainer.lua into Common/UserLuaScripts;
#  - adds one line to bootstrap.lua (loads the menu) and the menu's hooks to DriverNGHook's
#    driverNGHookMenu.lua (its F2 menus call the DSF menu, and a Trainer menu). Both files are
#    edited in place, after a backup in _dsfmenu_backup/, and only once;
#  - under Proton, makes Documents/Ubisoft/Driver San Francisco/DSFMenu in the game's prefix with
#    links to dsf_enhanced.ini and Felony Rework's config: the game's Lua can write only there,
#    and the menu saves settings through those links.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
uninstall=0
if [ "${1:-}" = "--uninstall" ]; then
  uninstall=1
  shift
fi
game="${1:-$HOME/.local/share/Steam/steamapps/common/Driver San Francisco}"
[ -f "$game/Driver.exe" ] || { echo "No Driver.exe in $game; pass the game folder." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is missing" >&2; exit 1; }

user="$game/Common/UserLuaScripts"
bootstrap="$user/bootstrap.lua"
hookmenu="$game/plugins/DriverNGHook/scripts/driverNGHookMenu.lua"
backup="$game/_dsfmenu_backup"
# The prefix's Documents folder (Steam app 33440): the game's HDD: device
prefix_docs="$(cd "$game/../.." && pwd)/compatdata/33440/pfx/drive_c/users/steamuser/Documents/Ubisoft/Driver San Francisco"
links="$prefix_docs/DSFMenu"

# Adds (install) or removes (uninstall) the DSF menu's lines in bootstrap.lua and
# driverNGHookMenu.lua. Keeps each file's line ends. Prints what it did.
edit() {
  python3 -I - "$1" "$bootstrap" "$hookmenu" <<'PY'
import os, re, sys

mode, bootstrap, hookmenu = sys.argv[1], sys.argv[2], sys.argv[3]
MENUS = ["File", "View", "World", "Game", "Utilities"]
HELPER = [
    "-- DSF menu (Common\\UserLuaScripts\\dsfmenu.lua) fills these menus; an error shows as a line",
    "local function dsfMenu(name)",
    "    if DSFMenu and DSFMenu.menu then",
    "        local ok, err = pcall(DSFMenu.menu, name)",
    "        if not ok then",
    "            ImGui.TextColored(1, 0.4, 0.4, 1, ((\"DSF menu error: \" .. tostring(err)):gsub(\"%%\", \"%%%%\")))",
    "        end",
    "    end",
    "end",
    "",
]
LOADER = ["", "\t-- DSF menu: fills the F2 menu (Common\\UserLuaScripts\\dsfmenu.lua)", "\tuser_open(\"dsfmenu.lua\")"]

def read(path):
    raw = open(path, "rb").read().decode("utf-8")
    eol = "\r\n" if "\r\n" in raw else "\n"
    return raw.replace("\r\n", "\n").split("\n"), eol

def write(path, lines, eol):
    open(path, "wb").write(eol.join(lines).encode("utf-8"))

def indent_of(line):
    return line[:len(line) - len(line.lstrip())]

# bootstrap.lua: the loader at the start of UserBootstrapper.Init (after its print, if any)
if os.path.isfile(bootstrap):
    lines, eol = read(bootstrap)
    has = any('user_open("dsfmenu.lua")' in l for l in lines)
    if mode == "install" and not has:
        at = next((i for i, l in enumerate(lines) if l.strip().startswith("function UserBootstrapper.Init")), None)
        if at is None:
            sys.exit("bootstrap.lua has no UserBootstrapper.Init; add user_open(\"dsfmenu.lua\") to it yourself")
        if at + 1 < len(lines) and "print(" in lines[at + 1]:
            at += 1
        lines[at + 1:at + 1] = LOADER
        write(bootstrap, lines, eol)
        print("bootstrap.lua: loads the DSF menu")
    elif mode == "uninstall" and has:
        out = [l for l in lines if 'user_open("dsfmenu.lua")' not in l and "-- DSF menu: fills the F2 menu" not in l]
        # the blank line the loader came with
        for i in range(len(out) - 1):
            if out[i].strip().startswith("print(") and out[i + 1] == "" and i + 2 < len(out) and out[i + 2].strip() == "end":
                del out[i + 1]
                break
        write(bootstrap, out, eol)
        print("bootstrap.lua: DSF menu loader removed")
else:
    print("no bootstrap.lua: is DriverNGHook installed?")

# driverNGHookMenu.lua: the helper, a call in each F2 menu, a Trainer menu before Help
if os.path.isfile(hookmenu):
    lines, eol = read(hookmenu)
    has = any(l.startswith("local function dsfMenu(") for l in lines)
    if mode == "install" and not has:
        at = next((i for i, l in enumerate(lines) if l.strip() == "local menuShown = false"), None)
        if at is None:
            sys.exit("driverNGHookMenu.lua isn't the one this was written for (no 'local menuShown = false')")
        lines[at + 1:at + 1] = [""] + HELPER[:-1]
        for name in MENUS:
            i = next((i for i, l in enumerate(lines) if 'ImGui.BeginMenu("%s")' % name in l), None)
            if i is None:
                sys.exit('driverNGHookMenu.lua has no "%s" menu' % name)
            call = indent_of(lines[i]) + "\t" + 'dsfMenu("%s")' % name
            if i + 1 < len(lines) and lines[i + 1].strip() == "":
                lines[i + 1] = call   # DriverNGHook leaves an empty line there
            else:
                lines.insert(i + 1, call)
        h = next((i for i, l in enumerate(lines) if 'ImGui.BeginMenu("Help")' in l), None)
        if h is None:
            sys.exit('driverNGHookMenu.lua has no "Help" menu')
        ind = indent_of(lines[h])
        lines[h:h] = [ind + 'if ImGui.BeginMenu("Trainer") then', ind + '\tdsfMenu("Trainer")', ind + "\tImGui.EndMenu()",
                      ind + "end", ""]
        write(hookmenu, lines, eol)
        print("driverNGHookMenu.lua: F2 menus call the DSF menu; Trainer menu added")
    elif mode == "uninstall" and has:
        out, skip = [], 0
        i = 0
        while i < len(lines):
            l = lines[i]
            if l.startswith("-- DSF menu (Common") and i + len(HELPER) - 1 <= len(lines):
                i += len(HELPER) - 1   # the helper block
                if i < len(lines) and lines[i] == "" and out and out[-1] == "":
                    i += 1
                continue
            if 'ImGui.BeginMenu("Trainer")' in l:
                i += 4                 # Trainer: if, dsfMenu, EndMenu, end
                if i < len(lines) and lines[i] == "":
                    i += 1
                continue
            m = re.match(r'^\s*dsfMenu\("(\w+)"\)\s*$', l)
            if m:
                out.append("")         # back to DriverNGHook's empty line
                i += 1
                continue
            out.append(l)
            i += 1
        write(hookmenu, out, eol)
        print("driverNGHookMenu.lua: DSF menu hooks removed")
else:
    print("no plugins/DriverNGHook/scripts/driverNGHookMenu.lua: is DriverNGHook installed?")
PY
}

if [ "$uninstall" = 1 ]; then
  rm -f "$user/dsfmenu.lua" "$user/dsfmenu_trainer.lua"
  edit uninstall
  if [ -d "$links" ]; then
    for f in dsf_enhanced.ini felonyreworkconfig.txt; do [ -L "$links/$f" ] && rm -f "$links/$f"; done
    rm -f "$links/menu_style.txt"
    rmdir "$links" 2>/dev/null || true
  fi
  echo "DSF menu removed. Backups of the edited files stay in $backup."
  exit 0
fi

[ -d "$game/plugins/DriverNGHook" ] || { echo "DriverNGHook isn't installed (no plugins/DriverNGHook)." >&2; exit 1; }
mkdir -p "$user" "$backup"
# back up the two files before their first edit
for f in "$bootstrap" "$hookmenu"; do
  if [ -f "$f" ] && ! grep -q 'dsfMenu\|user_open("dsfmenu.lua")' "$f" && [ ! -f "$backup/$(basename "$f")" ]; then
    cp -p "$f" "$backup/"
  fi
done
cp "$here/lua/dsfmenu.lua" "$here/lua/dsfmenu_trainer.lua" "$user/"
echo "copied dsfmenu.lua and dsfmenu_trainer.lua"
edit install

if [ -d "$prefix_docs" ] || [ -d "$(dirname "$prefix_docs")" ]; then
  mkdir -p "$links"
  [ -f "$game/dsf_enhanced.ini" ] && ln -sfn "$game/dsf_enhanced.ini" "$links/dsf_enhanced.ini"
  felony="$user/felonyrework/felonyreworkconfig.txt"
  [ -f "$felony" ] && ln -sfn "$felony" "$links/felonyreworkconfig.txt"
  echo "save links in $links"
else
  echo "No Proton prefix at $(dirname "$prefix_docs") (start the game once first): saving settings from"
  echo "the menu needs links there to dsf_enhanced.ini and felonyreworkconfig.txt."
fi
echo "Installed. F2 in game; hold D-pad up for the controller menu. The F2 changes apply after a restart."
