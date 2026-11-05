import hashlib
import json

import pytest

from dsfworld.config import BACKUP_DIR, MAP_DIR, REDIRECT_TABLE, Config
from dsfworld.stages import install, plugin

FIXED = b"".join(plugin.FIXES)  # what a DSF Enhanced with the fixes and the redirect holds
LINE = (
    "Install\\w.dngc|worldlod-map\\w.dngc|ResourceArenaExtraNodes,PendingResourceReferences,SubmodelTableExtraNodes\n"
)


@pytest.fixture
def game(tmp_path, monkeypatch):
    """A game folder with its world archive and DSF Enhanced, and a packed build; the game isn't running and
    the build passes its check."""
    monkeypatch.setattr(install, "_game_running", lambda: False)
    monkeypatch.setattr(install, "check", lambda _path: [])
    cfg = Config(
        {"game": {"dir": str(tmp_path / "game"), "archive": "Install/w.dngc"}, "run": {"work_dir": "out"}}, tmp_path
    )
    cfg.game_archive.parent.mkdir(parents=True)
    (cfg.game_dir / plugin.ASI).write_bytes(b"DSF Enhanced with " + FIXED)
    (cfg.game_dir / "winmm.dll").write_bytes(b"built at ultimate-asi-loader")
    cfg.game_archive.write_bytes(b"original")
    cfg.packed_archive.parent.mkdir(parents=True)
    cfg.packed_archive.write_bytes(b"build")
    return cfg


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def map_file(cfg):
    return cfg.game_dir / MAP_DIR / "w.dngc"


def table(cfg):
    return cfg.game_dir / REDIRECT_TABLE


def manifest(cfg):
    return json.loads((cfg.game_dir / MAP_DIR / install.MANIFEST).read_text())


def swapped_in(cfg, plugin_record=None):
    """The game as a version 0.1 install left it: the build in the game's file, the original in the backup."""
    old = cfg.game_dir / BACKUP_DIR
    old.mkdir()
    (old / "w.dngc").write_bytes(b"original")
    cfg.game_archive.write_bytes(b"old build")
    record = {"original": sha(b"original"), "installed": sha(b"old build")}
    if plugin_record:
        record["plugin"] = plugin_record
    (old / install.MANIFEST).write_text(json.dumps(record))
    return old


def test_install_puts_the_map_beside_the_games_and_lists_it(game):
    install.install(game)
    assert game.game_archive.read_bytes() == b"original"  # never written
    assert map_file(game).read_bytes() == b"build"
    assert table(game).read_text() == LINE
    assert manifest(game) == {"map": sha(b"build"), "table": sha(LINE.encode())}
    assert not (game.game_dir / BACKUP_DIR).exists()


def test_install_again_replaces_the_map(game):
    install.install(game)
    game.packed_archive.write_bytes(b"newer build")
    install.install(game)
    assert map_file(game).read_bytes() == b"newer build"
    assert manifest(game)["map"] == sha(b"newer build")


def test_install_refuses_a_failing_build(game, monkeypatch):
    monkeypatch.setattr(install, "check", lambda _path: ["MDID lacks 1 resource UIDs"])
    with pytest.raises(SystemExit, match="fails its check"):
        install.install(game)
    assert not (game.game_dir / MAP_DIR).exists()
    assert not table(game).exists()


def test_an_install_stopped_before_the_table_leaves_the_game_its_own_map(game, monkeypatch):
    def stop(_target, _data):
        raise KeyboardInterrupt

    write = install._write
    monkeypatch.setattr(install, "_write", stop)
    with pytest.raises(KeyboardInterrupt):
        install.install(game)
    assert not table(game).exists()
    monkeypatch.setattr(install, "_write", write)
    install.install(game)
    assert table(game).read_text() == LINE


def test_install_remembers_the_game_folder(game):
    from dsfworld import config

    install.install(game)
    assert config.remembered_game(game.work_dir) == str(game.game_dir)


def test_install_deletes_the_build_files_from_the_default_work_folder(game):
    game.data["run"]["work_dir"] = ""  # the default: the data folder
    game.packed_archive.parent.mkdir(parents=True)
    game.packed_archive.write_bytes(b"build")
    (game.work_dir / "bake").mkdir()
    install.install(game)
    assert map_file(game).read_bytes() == b"build"
    assert not game.packed_archive.parent.exists()
    assert not (game.work_dir / "bake").exists()


def test_uninstall_takes_everything_out(game):
    (game.game_dir / "dsf_enhanced").mkdir()
    (game.game_dir / "dsf_enhanced" / "mine.txt").write_text("another mod's")
    install.install(game)
    install.uninstall(game)
    assert game.game_archive.read_bytes() == b"original"
    assert not (game.game_dir / MAP_DIR).exists()
    assert not table(game).parent.exists()  # the redirect folder, left empty
    assert (game.game_dir / "dsf_enhanced" / "mine.txt").exists()
    with pytest.raises(SystemExit, match="Nothing to undo"):
        install.uninstall(game)


def test_uninstall_keeps_a_table_someone_changed(game):
    install.install(game)
    table(game).write_text(LINE + "Install\\x.sp|mine\\x.sp\n")
    install.uninstall(game)
    assert table(game).exists()
    assert not map_file(game).exists()


def test_install_over_a_swapped_install_puts_the_original_back(game):
    old = swapped_in(game)
    assert game.archive == old / "w.dngc"  # the pipeline reads the original, not the old build
    install.install(game)
    assert game.game_archive.read_bytes() == b"original"
    assert not old.exists()  # moved back: no copy left
    assert map_file(game).read_bytes() == b"build"
    assert game.archive == game.game_archive


def test_a_swapped_install_whose_backup_changed_is_left_alone(game):
    old = swapped_in(game)
    (old / "w.dngc").write_bytes(b"not the original")
    with pytest.raises(SystemExit, match="recorded hash"):
        install.install(game)
    assert game.game_archive.read_bytes() == b"old build"
    assert not map_file(game).exists()


def test_a_swapped_install_without_its_backup_is_refused(game):
    old = swapped_in(game)
    (old / "w.dngc").unlink()
    with pytest.raises(SystemExit, match=r"backup .* is missing"):
        install.install(game)
    assert (old / install.MANIFEST).exists()


def test_a_kept_backup_after_a_swapped_uninstall_stays(game):
    old = swapped_in(game)
    game.game_archive.write_bytes(b"original")  # 0.1's uninstall put it back and kept the backup
    record = json.loads((old / install.MANIFEST).read_text())
    (old / install.MANIFEST).write_text(json.dumps({**record, "installed": None}))
    assert game.archive == game.game_archive
    install.install(game)
    assert (old / "w.dngc").read_bytes() == b"original"
    assert not (old / install.MANIFEST).exists()


def test_uninstall_of_a_swapped_install_puts_the_original_back(game):
    old = swapped_in(game)
    install.uninstall(game)
    assert game.game_archive.read_bytes() == b"original"
    assert not old.exists()
    assert not (game.game_dir / MAP_DIR).exists()
