"""DSF Enhanced, which gives the game the new map and the [Limits] fixes it needs: the built archive
is bigger than three fixed-size engine pools allow, and the stock game crashes while loading it.
Its [Files] Redirect opens worldlod's map in place of the game's (install.py writes the table), and
only while those three fixes are in; without the plugin the game reads its own map.

When the game lacks the plugin (or has one without the fixes, or no ASI loader),
install puts the DSF Enhanced that comes with worldlod (the release ZIP's plugin
folder, given as --plugin) into the game folder: dsf_enhanced.asi where an older
one is (the game folder, scripts\\ or plugins\\: Ultimate ASI Loader loads all
three) or in the game folder, its ini beside it unless the player already has
one, and the ASI loader (winmm.dll) unless an Ultimate ASI Loader is already
there. Files it replaces are kept in the backup folder; the manifest records
what it placed (paths relative to the game folder), and uninstall takes exactly
that back. The loader stays while other ASI mods are there to use it.
"""

from __future__ import annotations

import configparser
import hashlib
import shutil
from pathlib import Path

from dsfworld import ui

ASI, INI, LOADER = "dsf_enhanced.asi", "dsf_enhanced.ini", "winmm.dll"
ASI_FOLDERS = ("", "scripts", "plugins")  # where Ultimate ASI Loader loads .asi files from
# In every DSF Enhanced that has all three [Limits] fixes and [Files] Redirect: a setting only those
# fixes know, and the folder of the redirect tables
FIXES = (b"SubmodelTableExtraNodes", rb"dsf_enhanced\redirect" + b"\\")
# [Limits] keys the build needs, and the value at or below which each is off
LIMITS = {"ResourceArenaExtraNodes": 0, "PendingResourceReferences": 16384, "SubmodelTableExtraNodes": 0}
ASI_LOADER = b"ultimate-asi-loader"  # in every Ultimate ASI Loader DLL (its build path)
# The Forza car mod's plugin patches the call the world archive is opened from (for its own GUI
# files); from the version with this capability on it passes every other file on to DSF Enhanced.
FORZA_ASI, FORZA_CHAIN = "dsfforza.asi", b"archive.redirect_chain"


def _has_fixes(data: bytes) -> bool:
    return all(marker in data for marker in FIXES)


def find_asi(game: Path) -> Path | None:
    """The DSF Enhanced the game loads, if any."""
    return next((game / d / ASI for d in ASI_FOLDERS if (game / d / ASI).exists()), None)


def has_fixes(game: Path) -> bool:
    """Whether the game folder has a DSF Enhanced with the [Limits] fixes."""
    asi = find_asi(game)
    return asi is not None and _has_fixes(asi.read_bytes())


def has_loader(game: Path) -> bool:
    """Whether an Ultimate ASI Loader (under any of its DLL names) is in the game folder."""
    return any(ASI_LOADER in f.read_bytes().lower() for f in game.glob("*.dll"))


def needed(game: Path) -> bool:
    """Whether install has to put DSF Enhanced (or the loader for it) into the game."""
    return not (has_fixes(game) and has_loader(game))


def problem(game: Path) -> str | None:
    """Why the game in this folder can't load the build (DSF Enhanced missing, too old, no loader, limits off),
    or None."""
    if find_asi(game) is None:
        return f"DSF Enhanced isn't installed ({ASI} not in {game})"
    if not has_fixes(game):
        return "the installed DSF Enhanced is too old: it lacks the [Limits] fixes or [Files] Redirect"
    if not has_loader(game):
        return "there is no ASI loader to load DSF Enhanced"
    return limits_off(game)


def _int(section, key: str) -> int | None:
    value = section.get(key) if section is not None else None
    return int(value) if value is not None and value.strip().lstrip("-").isdigit() else None


def limits_off(game: Path) -> str | None:
    """Which of the needed [Limits] (or [Files] Redirect) the game's dsf_enhanced.ini turns off, or None."""
    asi = find_asi(game)
    path = (asi.parent if asi else game) / INI
    ini = configparser.ConfigParser(inline_comment_prefixes=(";",), strict=False)
    if path.exists():
        ini.read_string(path.read_text(encoding="utf-8", errors="replace"))
    limits = ini["Limits"] if ini.has_section("Limits") else None
    for key, off in LIMITS.items():
        value = _int(limits, key)
        if value is not None and value <= off:
            return (
                f"{INI} turns off [Limits] {key}, which the new map needs (without it the game shows its own "
                "map): remove that line or raise it"
            )
    if _int(ini["Files"] if ini.has_section("Files") else None, "Redirect") == 0:
        return f"{INI} turns off [Files] Redirect, which gives the game the new map: remove that line or set it to 1"
    return None


def forza_too_old(game: Path) -> Path | None:
    """The Forza car mod's plugin, if the game has one that keeps the world archive from DSF Enhanced."""
    found = next((game / d / FORZA_ASI for d in ASI_FOLDERS if (game / d / FORZA_ASI).exists()), None)
    return found if found is not None and FORZA_CHAIN not in found.read_bytes() else None


def check_source(source: Path | None) -> None:
    """Stop unless source (a folder) holds a DSF Enhanced with the fixes."""
    if source is None or not (source / ASI).exists():
        raise SystemExit(
            "The new map needs DSF Enhanced's [Limits] fixes, or the game crashes while loading: run worldlod "
            "through install.cmd from its release ZIP (it brings DSF Enhanced), or install DSF Enhanced first"
        )
    if not _has_fixes((source / ASI).read_bytes()):
        raise SystemExit(
            f"The DSF Enhanced in {source} doesn't have the [Limits] fixes and [Files] Redirect the new map needs"
        )


def install(game: Path, backup_dir: Path, manifest: dict, source: Path) -> None:
    """Put what the game lacks of the DSF Enhanced in source into game; record it in manifest (the caller
    saves it)."""
    check_source(source)
    asi = find_asi(game) or game / ASI
    wanted = {game / LOADER: source / LOADER}
    if not has_fixes(game):  # the plugin itself, and its ini unless the player has one
        wanted |= {asi: source / ASI, asi.parent / INI: source / INI}
    record = manifest.setdefault("plugin", {"placed": {}, "replaced": []})
    for target, origin in wanted.items():
        if not origin.exists():
            continue
        if target.name == INI and target.exists():
            continue  # the player's own settings
        if target.name == LOADER and has_loader(game):
            continue  # the loader they have
        rel = target.relative_to(game).as_posix()
        if target.exists() and not (backup_dir / "plugin" / rel).exists():
            (backup_dir / "plugin" / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(target, backup_dir / "plugin" / rel)
            record["replaced"].append(rel)
        data = origin.read_bytes()
        target.write_bytes(data)
        record["placed"][rel] = hashlib.sha256(data).hexdigest()
    ui.done("Installed DSF Enhanced", ", ".join(record["placed"]))


def _other_asi(game: Path) -> list[Path]:
    return [f for d in ASI_FOLDERS for f in (game / d).glob("*.asi") if f.name != ASI]


def uninstall(game: Path, backup_dir: Path, manifest: dict) -> None:
    """Take back what install put into game: its files go (the player's changed ones and a loader other
    ASI mods use stay), the ones they replaced come back."""
    record = manifest.pop("plugin", None)
    if not record:
        return
    kept = []
    for rel, digest in record["placed"].items():
        target = game / rel
        if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            continue
        if target.name == LOADER and _other_asi(game):
            kept.append(rel)
            continue
        target.unlink()
    for rel in record["replaced"]:
        saved = backup_dir / "plugin" / rel
        if saved.exists() and not (game / rel).exists():
            shutil.move(saved, game / rel)
    saved_dir = backup_dir / "plugin"
    if saved_dir.exists() and not any(f.is_file() for f in saved_dir.rglob("*")):
        shutil.rmtree(saved_dir)  # all put back; a backup that couldn't be stays
    ui.done("Removed DSF Enhanced", f"put back: {', '.join(record['replaced'])}" if record["replaced"] else "")
    if kept:
        ui.note(f"Kept {', '.join(kept)}: other ASI mods in the game use it")
