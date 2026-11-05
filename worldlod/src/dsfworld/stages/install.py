"""install / uninstall: give the game the packed world archive beside its own, or take it back out.

The game's san_francisco.dngc is never written. install puts the build in <game>/worldlod-map/ and
lists it in DSF Enhanced's redirect table (<game>/dsf_enhanced/redirect/worldlod.txt): the plugin
opens it in place of the game's file, and only while the [Limits] fixes it needs are in, so without
the plugin (or with a fix off) the game loads its own map. The table goes in last and comes out
first, so the game never sees a table without its map. With the default work folder, install then
deletes the build files (about 1 GB).

Before building, install checks that DSF Enhanced can be had (in the game, or from --plugin, the
release ZIP's plugin folder); it puts it in (see plugin.py) only once the build has passed its check.
uninstall takes the plugin back out if install put it there.

Versions up to 0.1 swapped the build into the game's file and kept the original in
<game>/worldlod-backup/; install and uninstall move that original back first.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path, PureWindowsPath

from dsfworld import ui
from dsfworld.config import BACKUP_DIR, MAP_DIR, REDIRECT_TABLE, Config, remember_game
from dsfworld.stages import plugin
from dsfworld.stages.pack import check, sha256

MANIFEST = "manifest.json"
# The [Limits] the map needs (plugin.LIMITS): DSF Enhanced opens it only while all are in.
NEEDS = ",".join(plugin.LIMITS)


def _manifest(cfg: Config) -> tuple[Path, dict]:
    path = cfg.game_dir / MAP_DIR / MANIFEST
    return path, (json.loads(path.read_text()) if path.exists() else {})


def _save(path: Path, manifest: dict) -> None:
    """Write the manifest whole or not at all."""
    path.parent.mkdir(exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=2))
    tmp.replace(path)


def ready(cfg: Config, plugin_dir: Path | None = None) -> None:
    """Stop before any work if install couldn't finish: no world archive, the game running, or DSF Enhanced
    missing from the game with none to put in (plugin_dir) or turned off by the player's ini."""
    if not cfg.game_archive.exists():
        raise SystemExit(f"No {cfg.game_archive.name} in {cfg.game_archive.parent}: is {cfg.game_dir} the game folder?")
    if _game_running():
        raise SystemExit("Driver.exe is running: close the game first")
    if plugin.needed(cfg.game_dir):
        plugin.check_source(plugin_dir)
        return
    off = plugin.limits_off(cfg.game_dir)  # the player's own ini: their call
    if off:
        raise SystemExit(off)


def _game_running() -> bool:
    if sys.platform != "win32":
        return False
    out = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq Driver.exe"], capture_output=True, text=True, check=False
    ).stdout
    return "Driver.exe" in out


def _write(target: Path, data: bytes) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".worldlod-tmp")
    tmp.write_bytes(data)
    tmp.replace(target)


def _table_line(cfg: Config) -> str:
    """The redirect line: the game's archive, the map, the [Limits] it needs (paths relative to the game)."""
    game = PureWindowsPath(cfg.data["game"]["archive"])
    return f"{game}|{PureWindowsPath(MAP_DIR, game.name)}|{NEEDS}\n"


def _paths(cfg: Config) -> tuple[Path, Path]:
    """The map in the game folder, and the redirect table that names it."""
    return cfg.game_dir / MAP_DIR / cfg.game_archive.name, cfg.game_dir / REDIRECT_TABLE


def _restore_swapped(cfg: Config, manifest: dict) -> None:
    """Undo a version 0.1 install, which swapped the build into the game's file: the original goes back from
    worldlod-backup/ (moved, after checking both hashes), and what that install recorded of DSF Enhanced
    moves into manifest. Nothing to do when there is no such install."""
    old_dir = cfg.game_dir / BACKUP_DIR
    old_path = old_dir / MANIFEST
    if not old_path.exists():
        return
    old = json.loads(old_path.read_text())
    target, backup = cfg.game_archive, old_dir / cfg.game_archive.name
    if old.get("installed") and backup.exists():
        if sha256(backup) != old.get("original"):
            raise SystemExit(f"{backup} doesn't match its recorded hash; not touching anything")
        if target.exists() and sha256(target) not in (old["installed"], old["original"]):
            raise SystemExit(f"{target} isn't the build worldlod installed (another mod?); not overwriting it")
        with ui.status(f"Putting the original {target.name} back (worldlod 0.1 replaced it)"):
            backup.replace(target)  # a move: the game's file is the original again, and no copy is left
        ui.done("Put the game's original map back", str(target))
    elif old.get("installed") and target.exists() and sha256(target) == old["installed"]:
        raise SystemExit(
            f"{target} is a build an earlier worldlod installed, and its backup ({backup}) is missing: restore the "
            "game's original file first (verify the game files in its launcher)"
        )
    elif backup.exists():
        ui.note(f"{backup} is a copy of the game's map an earlier worldlod kept; delete it if you don't need it")
    if "plugin" in old:  # what that install put in of DSF Enhanced, and the files it replaced
        manifest["plugin"] = old["plugin"]
        saved = old_dir / "plugin"
        if saved.exists():
            (cfg.game_dir / MAP_DIR).mkdir(exist_ok=True)
            shutil.move(saved, cfg.game_dir / MAP_DIR / "plugin")
    _save(_manifest(cfg)[0], manifest)
    old_path.unlink()
    if not any(old_dir.iterdir()):
        old_dir.rmdir()


def install(cfg: Config, plugin_dir: Path | None = None) -> None:
    """Put the map beside the game's, DSF Enhanced in if the game needs it, then the redirect table. The
    manifest is written before each change, so an interrupted install can be run again or undone."""
    map_file, table = _paths(cfg)
    packed = cfg.packed_archive
    if not packed.exists():
        raise SystemExit(f"no built archive at {packed}: run `worldlod build` first")
    ready(cfg, plugin_dir)
    problems = check(packed)
    if problems:
        raise SystemExit(f"{packed} fails its check ({problems[0]}); not installing")
    manifest_path, manifest = _manifest(cfg)
    _restore_swapped(cfg, manifest)
    table.unlink(missing_ok=True)  # the game reads its own map until the new one is in place
    with ui.status(f"Installing the new map into {map_file.parent}"):
        manifest["map"] = sha256(packed)
        _save(manifest_path, manifest)
        map_file.parent.mkdir(exist_ok=True)
        tmp = map_file.with_name(map_file.name + ".worldlod-tmp")
        shutil.copyfile(packed, tmp)
        tmp.replace(map_file)
    if plugin.needed(cfg.game_dir):
        try:
            plugin.install(cfg.game_dir, manifest_path.parent, manifest, plugin_dir)
        finally:
            _save(manifest_path, manifest)
    line = _table_line(cfg)
    manifest["table"] = hashlib.sha256(line.encode()).hexdigest()
    _save(manifest_path, manifest)
    _write(table, line.encode())
    remember_game(cfg.work_dir, cfg.game_dir)
    if not cfg.data["run"]["work_dir"]:  # the default work folder: a one-time run leaves nothing behind
        shutil.rmtree(cfg.work_dir / "bake", ignore_errors=True)
        shutil.rmtree(packed.parent, ignore_errors=True)
    undo = "install.cmd --uninstall" if os.environ.get("WORLDLOD_LAUNCHER") else "worldlod uninstall"
    ui.done(f"Installed the new map into {cfg.game_dir}", "the game's own map stays as it is")
    forza = plugin.forza_too_old(cfg.game_dir)
    if forza:
        ui.note(
            f"{forza.relative_to(cfg.game_dir)} (the Forza car mod) is a version that keeps the new map from "
            "DSF Enhanced: the game shows its own map until you update the car mod"
        )
    ui.note(f"To take it out again: {undo}")


def uninstall(cfg: Config) -> None:
    """Take the map, its redirect table and the DSF Enhanced install added back out (a version 0.1 install:
    put the original map back)."""
    map_file, table = _paths(cfg)
    manifest_path, manifest = _manifest(cfg)
    swapped = (cfg.game_dir / BACKUP_DIR / MANIFEST).exists()
    if not manifest_path.exists() and not swapped:
        raise SystemExit(f"Nothing to undo: worldlod hasn't installed anything into {cfg.game_dir}")
    if _game_running():
        raise SystemExit("Driver.exe is running: close the game first")
    _restore_swapped(cfg, manifest)
    if table.exists():
        if hashlib.sha256(table.read_bytes()).hexdigest() == manifest.get("table"):
            table.unlink()
        else:
            ui.note(f"Kept {table}: it isn't the table worldlod wrote")
    for d in (table.parent, table.parent.parent):  # dsf_enhanced\redirect, dsf_enhanced: if left empty
        if d.exists() and not any(d.iterdir()):
            d.rmdir()
    manifest.pop("table", None)
    if map_file.exists():
        map_file.unlink()  # worldlod's own folder: nothing else writes it
        ui.done("Took the new map out", "the game loads its own map again")
    manifest.pop("map", None)
    _save(manifest_path, manifest)
    plugin.uninstall(cfg.game_dir, manifest_path.parent, manifest)
    if manifest:  # something couldn't be undone: keep the record
        _save(manifest_path, manifest)
        return
    manifest_path.unlink(missing_ok=True)
    if manifest_path.parent.exists() and not any(manifest_path.parent.iterdir()):
        manifest_path.parent.rmdir()
