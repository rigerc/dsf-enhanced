#!/usr/bin/env bash
# Runs the DSF menu's offline tests (dsfmenu_mock.lua): stock Lua 5.1 with stand-ins for the game,
# DriverNGHook's ImGui binding (sol_ImGui, 2023 build) and the game's file system, in a temporary
# folder. The fixtures: the repository's src/dsf_enhanced.ini with CRLF line ends, as released, and
# a Felony Rework style config (fixtures/). LUA picks the interpreter (default lua5.1).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
lua="${LUA:-lua5.1}"
command -v "$lua" >/dev/null || { echo "$lua is missing: install Lua 5.1" >&2; exit 1; }

# The game's Lua numbers are 4-byte floats: its compiler rejects number literals over 8388606, and
# then the whole file fails to load. Stock Lua accepts them, so look for them first.
python3 -I - "$here/../lua/dsfmenu.lua" "$here/../lua/dsfmenu_trainer.lua" <<'PY'
import re, sys
bad = []
for p in sys.argv[1:]:
    code = re.sub(r'--\[\[.*?\]\]', '', open(p, encoding="utf-8").read(), flags=re.S)
    code = re.sub(r'"(\\.|[^"\\])*"', '""', re.sub(r'--[^\n]*', '', code))
    for m in re.finditer(r'(?<![\w.])(0x[0-9a-fA-F]+|\d+(\.\d+)?([eE][+-]?\d+)?)', code):
        t = m.group(0)
        if (int(t, 16) if t.startswith("0x") else float(t)) > 8388606:
            bad.append(p.rsplit("/", 1)[1] + ": " + t)
if bad:
    sys.exit("number literals the game's Lua rejects (over 8388606): " + ", ".join(bad))
PY

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/game" "$work/user/felonyrework" "$work/hdd/DSFMenu"
sed 's/\r$//; s/$/\r/' "$root/src/dsf_enhanced.ini" > "$work/game/dsf_enhanced.ini"
cp "$here/../lua/dsfmenu.lua" "$here/../lua/dsfmenu_trainer.lua" "$work/user/"
cp "$here/fixtures/felonyreworkconfig.txt" "$work/user/felonyrework/"
# HDD:DSFMenu holds links to the files the menu saves, as install.sh sets up under Proton
ln -s "$work/game/dsf_enhanced.ini" "$work/hdd/DSFMenu/dsf_enhanced.ini"
ln -s "$work/user/felonyrework/felonyreworkconfig.txt" "$work/hdd/DSFMenu/felonyreworkconfig.txt"
cd "$work/game"
"$lua" "$here/dsfmenu_mock.lua" "$work/user/dsfmenu.lua" "$work/user" "$work/hdd"
