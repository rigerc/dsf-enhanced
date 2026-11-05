import hashlib
import json

import pytest

from dsfworld.config import BACKUP_DIR, MAP_DIR, Config
from dsfworld.stages import install, plugin

FIXED = b"".join(plugin.FIXES)  # what a DSF Enhanced with the fixes and the redirect holds

RELEASE = {
    plugin.ASI: b"new plugin " + FIXED,
    plugin.INI: b"[Limits]\nSubmodelTableExtraNodes=60000\n",
    plugin.LOADER: b"loader built at C:/projects/ultimate-asi-loader/",
}


@pytest.fixture
def bundled(tmp_path):
    """The plugin folder of a release ZIP holding RELEASE."""
    d = tmp_path / "plugin"
    d.mkdir()
    for name, data in RELEASE.items():
        (d / name).write_bytes(data)
    return d


@pytest.fixture
def game(tmp_path, monkeypatch):
    """A game folder without DSF Enhanced, and a build that passes its check."""
    monkeypatch.setattr(install, "_game_running", lambda: False)
    cfg = Config(
        {"game": {"dir": str(tmp_path / "game"), "archive": "Install/w.dngc"}, "run": {"work_dir": ""}}, tmp_path
    )
    cfg.game_archive.parent.mkdir(parents=True)
    cfg.game_archive.write_bytes(b"original")
    monkeypatch.setattr(install, "check", lambda _path: [])
    cfg.packed_archive.parent.mkdir(parents=True)
    cfg.packed_archive.write_bytes(b"build")
    return cfg


def manifest(cfg):
    return json.loads((cfg.game_dir / MAP_DIR / install.MANIFEST).read_text())


def test_checks(tmp_path):
    assert "isn't installed" in plugin.problem(tmp_path)
    (tmp_path / plugin.ASI).write_bytes(b"old plugin")
    assert "too old" in plugin.problem(tmp_path)
    (tmp_path / plugin.ASI).write_bytes(b"..." + FIXED)
    assert "no ASI loader" in plugin.problem(tmp_path)
    (tmp_path / "dinput8.dll").write_bytes(RELEASE[plugin.LOADER])
    assert plugin.problem(tmp_path) is None
    (tmp_path / plugin.INI).write_text("[Limits]\nSubmodelTableExtraNodes=0 ; off\n")
    assert "SubmodelTableExtraNodes" in plugin.problem(tmp_path)
    (tmp_path / plugin.INI).write_text("[Limits]\nPendingResourceReferences=131072\n")
    assert plugin.problem(tmp_path) is None
    (tmp_path / plugin.INI).write_text("[Files]\nRedirect=0\n")
    assert "Redirect" in plugin.problem(tmp_path)
    (tmp_path / plugin.ASI).write_bytes(b"limits only " + plugin.FIXES[0])
    assert "too old" in plugin.problem(tmp_path)


def test_a_plugin_in_scripts_counts(tmp_path):
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / plugin.ASI).write_bytes(b"..." + FIXED)
    (tmp_path / "winmm.dll").write_bytes(RELEASE[plugin.LOADER])
    assert plugin.find_asi(tmp_path) == tmp_path / "scripts" / plugin.ASI
    assert not plugin.needed(tmp_path)


def test_ready_checks_but_places_nothing(game, bundled):
    install.ready(game, bundled)
    assert not (game.game_dir / plugin.ASI).exists()
    with pytest.raises(SystemExit, match=r"install\.cmd"):
        install.ready(game)


def test_install_puts_the_plugin_in_with_the_map(game, bundled):
    install.install(game, bundled)
    d = game.game_dir
    for name, data in RELEASE.items():
        assert (d / name).read_bytes() == data
    assert (d / MAP_DIR / "w.dngc").read_bytes() == b"build"
    assert game.game_archive.read_bytes() == b"original"
    assert set(manifest(game)["plugin"]["placed"]) == set(RELEASE)


def test_install_replaces_an_old_plugin_where_it_is_and_keeps_the_players_ini_and_loader(game, bundled):
    d = game.game_dir
    (d / "scripts").mkdir()
    (d / "scripts" / plugin.ASI).write_bytes(b"old plugin")
    (d / "scripts" / plugin.INI).write_text("[General]\nLog=0\n")
    (d / "dinput8.dll").write_bytes(b"my ultimate-asi-loader")
    install.install(game, bundled)
    assert (d / "scripts" / plugin.ASI).read_bytes() == RELEASE[plugin.ASI]
    assert not (d / plugin.ASI).exists()  # no second copy for the loader to load
    assert (d / "scripts" / plugin.INI).read_text() == "[General]\nLog=0\n"
    assert not (d / plugin.LOADER).exists()
    assert (d / MAP_DIR / "plugin" / "scripts" / plugin.ASI).read_bytes() == b"old plugin"
    install.uninstall(game)
    assert (d / "scripts" / plugin.ASI).read_bytes() == b"old plugin"
    assert game.game_archive.read_bytes() == b"original"


def test_a_plugin_with_the_fixes_but_no_loader_gets_only_the_loader(game, bundled):
    d = game.game_dir
    (d / plugin.ASI).write_bytes(b"mine " + FIXED)
    install.install(game, bundled)
    assert (d / plugin.ASI).read_bytes() == b"mine " + FIXED
    assert (d / plugin.LOADER).read_bytes() == RELEASE[plugin.LOADER]
    assert set(manifest(game)["plugin"]["placed"]) == {plugin.LOADER}


def test_uninstall_removes_only_what_install_put_there(game, bundled):
    install.install(game, bundled)
    d = game.game_dir
    (d / plugin.INI).write_text("edited by the player")
    install.uninstall(game)
    assert not (d / plugin.ASI).exists()
    assert not (d / plugin.LOADER).exists()
    assert (d / plugin.INI).read_text() == "edited by the player"


def test_uninstall_keeps_the_loader_other_mods_use(game, bundled):
    install.install(game, bundled)
    d = game.game_dir
    (d / "scripts").mkdir()
    (d / "scripts" / "another.asi").write_bytes(b"another mod")
    install.uninstall(game)
    assert not (d / plugin.ASI).exists()
    assert (d / plugin.LOADER).exists()


def test_a_bundled_plugin_without_the_fixes_is_refused(game, bundled):
    (bundled / plugin.ASI).write_bytes(b"old plugin")
    with pytest.raises(SystemExit, match="doesn't have the"):
        install.install(game, bundled)
    assert not (game.game_dir / plugin.ASI).exists()
    assert game.game_archive.read_bytes() == b"original"


def test_ini_turning_a_fix_off_is_the_players_call(game):
    d = game.game_dir
    (d / plugin.ASI).write_bytes(b"..." + FIXED)
    (d / plugin.LOADER).write_bytes(RELEASE[plugin.LOADER])
    (d / plugin.INI).write_text("[Limits]\nResourceArenaExtraNodes=0\n")
    with pytest.raises(SystemExit, match="ResourceArenaExtraNodes"):
        install.ready(game)


def test_uninstall_after_only_the_plugin_went_in_cleans_up(game, bundled):
    path, m = install._manifest(game)
    plugin.install(game.game_dir, path.parent, m, bundled)
    install._save(path, m)
    install.uninstall(game)
    assert not (game.game_dir / plugin.ASI).exists()
    assert not (game.game_dir / MAP_DIR).exists()
    with pytest.raises(SystemExit, match="Nothing to undo"):
        install.uninstall(game)


def test_a_forza_plugin_that_doesnt_pass_files_on_is_found(tmp_path):
    assert plugin.forza_too_old(tmp_path) is None
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / plugin.FORZA_ASI).write_bytes(b"DSFFORZA-CAPABILITIES: archive.packages archive.ids")
    assert plugin.forza_too_old(tmp_path) == tmp_path / "plugins" / plugin.FORZA_ASI
    (tmp_path / "plugins" / plugin.FORZA_ASI).write_bytes(b"DSFFORZA-CAPABILITIES: archive.ids " + plugin.FORZA_CHAIN)
    assert plugin.forza_too_old(tmp_path) is None


def test_the_plugin_a_swapped_install_put_in_comes_out_with_the_new_one(game, bundled):
    """A version 0.1 install put DSF Enhanced in over an old one: the record and the old one's backup move
    to the new folder, and uninstall still puts the old one back."""
    d = game.game_dir
    old = d / BACKUP_DIR
    (old / "plugin").mkdir(parents=True)
    (old / "plugin" / plugin.ASI).write_bytes(b"old plugin")
    (old / "w.dngc").write_bytes(b"original")
    game.game_archive.write_bytes(b"old build")
    (d / plugin.ASI).write_bytes(RELEASE[plugin.ASI])
    (d / plugin.LOADER).write_bytes(RELEASE[plugin.LOADER])
    placed = {name: hashlib.sha256(RELEASE[name]).hexdigest() for name in (plugin.ASI, plugin.LOADER)}
    (old / install.MANIFEST).write_text(
        json.dumps(
            {
                "original": hashlib.sha256(b"original").hexdigest(),
                "installed": hashlib.sha256(b"old build").hexdigest(),
                "plugin": {"placed": placed, "replaced": [plugin.ASI]},
            }
        )
    )
    install.install(game, bundled)
    assert not old.exists()
    assert game.game_archive.read_bytes() == b"original"
    assert manifest(game)["plugin"]["replaced"] == [plugin.ASI]
    install.uninstall(game)
    assert (d / plugin.ASI).read_bytes() == b"old plugin"
    assert not (d / plugin.LOADER).exists()
    assert not (d / MAP_DIR).exists()
