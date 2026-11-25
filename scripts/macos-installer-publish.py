"""Publish the macOS installer artifacts in both local and release builds."""

import argparse
import ctypes
import fcntl
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


APP_NAME = "Mimi Remote Mac.app"
DMG_NAMES = {
    "dmg": "Mimi-Remote-Mac.dmg",
    "development-dmg": "Mimi-Remote-Mac-Development.dmg",
}
DMG_JOURNAL_MARKER = b"mimi-macos-dmg-publication-v1\n"


def exists_as(path, predicate, description):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(info.st_mode):
        raise ValueError(f"输出或暂存路径（{path}）是符号链接，拒绝覆盖。")
    if not predicate(info.st_mode):
        raise ValueError(f"路径（{path}）已被占用，必须是{description}。")
    return True


def exists_as_file(path):
    return exists_as(path, stat.S_ISREG, "普通文件")


def exists_as_dir(path):
    return exists_as(path, stat.S_ISDIR, "真实目录")


def exists_as_app(path):
    if not exists_as_dir(path):
        return False
    # 固定 App 名称可能被普通目录占用。只交换具备真实包结构的目录。
    contents = path / "Contents"
    if not exists_as_dir(contents) or not exists_as_file(contents / "Info.plist"):
        raise ValueError(f"路径（{path}）已被普通目录占用，缺少 App 的 Contents/Info.plist。")
    return True


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def copy_file(source, target):
    with source.open("rb") as src, target.open("xb") as dst:
        shutil.copyfileobj(src, dst, length=1024 * 1024)
        dst.flush()
        shutil.copystat(source, target)
        os.fsync(dst.fileno())


def link_or_copy(source, target):
    try:
        os.link(source, target)
    except OSError:
        copy_file(source, target)


class DmgPublication:
    def __init__(self, output, name):
        self.dmg = output / name
        self.sha = output / f"{name}.sha256"
        self.journal = output / f".{name}.transaction"
        self.new_dmg = self.journal / "new.dmg"
        self.new_sha = self.journal / "new.sha256"
        self.old_dmg = self.journal / "old.dmg"
        self.restore_dmg = self.journal / "restore.dmg"
        self.ready = self.journal / "ready"

    def check_targets(self):
        exists_as_file(self.dmg)
        exists_as_file(self.sha)

    def recover(self):
        if not exists_as_dir(self.journal):
            return
        info = self.journal.lstat()
        entries = {self.new_dmg, self.new_sha, self.old_dmg, self.restore_dmg, self.ready}
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError(f"恢复目录必须是当前用户的私有目录：{self.journal}。")
        for entry in self.journal.iterdir():
            if entry not in entries:
                raise ValueError(f"恢复目录包含未知文件：{entry}。")
            exists_as_file(entry)

        if not self.ready.exists():
            raise ValueError(f"同名目录缺少发布事务标记，保留目录：{self.journal}。")
        with self.ready.open("rb") as marker:
            if marker.read(len(DMG_JOURNAL_MARKER) + 1) != DMG_JOURNAL_MARKER:
                raise ValueError(f"同名目录的发布事务标记无效，保留目录：{self.journal}。")

        # 同卷 rename 同时移走暂存 SHA 与提交正式 SHA。暂存 SHA 仍在时只需补偿 DMG。
        if self.new_sha.exists() and not self.new_dmg.exists():
            self.check_targets()
            if self.old_dmg.exists():
                # 保留备份，补偿本身被中断时仍可重试。
                self.restore_dmg.unlink(missing_ok=True)
                link_or_copy(self.old_dmg, self.restore_dmg)
                os.replace(self.restore_dmg, self.dmg)
            else:
                self.dmg.unlink(missing_ok=True)
            sync_dir(self.dmg.parent)

        # 原子移走已处理的事务，避免逐文件清理途中被中断时误读事务状态。
        with tempfile.TemporaryDirectory(prefix=".mimi-dmg-cleanup.", dir=self.dmg.parent) as cleanup:
            os.rename(self.journal, Path(cleanup) / "transaction")
            sync_dir(self.dmg.parent)

    def prepare(self, source_dmg, source_sha):
        with tempfile.TemporaryDirectory(prefix=".mimi-dmg-staging.", dir=self.dmg.parent) as staging:
            ready_dir = Path(staging) / "transaction"
            ready_dir.mkdir(mode=0o700)
            copy_file(source_dmg, ready_dir / self.new_dmg.name)
            copy_file(source_sha, ready_dir / self.new_sha.name)
            if exists_as_file(self.dmg):
                link_or_copy(self.dmg, ready_dir / self.old_dmg.name)
            with (ready_dir / self.ready.name).open("xb") as marker:
                marker.write(DMG_JOURNAL_MARKER)
                marker.flush()
                os.fsync(marker.fileno())
            sync_dir(ready_dir)
            os.rename(ready_dir, self.journal)
            sync_dir(self.dmg.parent)

    def publish(self, source):
        source_dmg = source / self.dmg.name
        source_sha = source / self.sha.name
        if not exists_as_file(source_dmg) or not exists_as_file(source_sha):
            raise ValueError(f"暂存目录缺少 DMG 或 SHA：{source}。")

        try:
            self.prepare(source_dmg, source_sha)
            os.replace(self.new_dmg, self.dmg)
            sync_dir(self.dmg.parent)
            sync_dir(self.journal)
            # 两个固定文件名各自原子替换。SHA 替换是提交边界，读者必须核对摘要并在不匹配时重试。
            os.replace(self.new_sha, self.sha)
            sync_dir(self.dmg.parent)
            sync_dir(self.journal)
        except BaseException:
            try:
                # 二次 INT/TERM 留到补偿之后处理。强制终止则由下一次持锁发布恢复。
                blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
                try:
                    self.recover()
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            except (OSError, ValueError) as exc:
                print(f"DMG 恢复失败（{exc}），恢复目录：{self.journal}。", file=sys.stderr)
            raise

        try:
            self.recover()
        except (OSError, ValueError) as exc:
            print(f"警告：DMG 和 SHA 已提交，清理恢复目录 {self.journal} 失败：{exc}。", file=sys.stderr)


def swap_dirs(source, target):
    # Darwin 与 Linux 都用单次系统调用交换目录，旧 App 在提交前始终可用。
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        result = libc.renamex_np(os.fsencode(source), os.fsencode(target), ctypes.c_uint(2))
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        at_fdcwd = -100
        result = libc.renameat2(at_fdcwd, os.fsencode(source), at_fdcwd, os.fsencode(target), ctypes.c_uint(2))
    else:
        raise OSError("当前平台不支持原子交换 App 目录。")
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(target))


def publish_app(source, output):
    source_app = source / APP_NAME
    app = output / APP_NAME
    if not exists_as_app(source_app):
        raise ValueError(f"暂存目录缺少 App：{source_app}。")
    stage_parent = Path(tempfile.mkdtemp(prefix=".Mimi-Remote-Mac.app.staging.", dir=output))
    # 让复制操作创建 App 根目录以继承源权限，暂存父目录仍保持 0700。
    stage = stage_parent / APP_NAME
    committed = False
    try:
        if sys.platform == "darwin":
            subprocess.run(["ditto", source_app, stage], check=True)
        else:
            shutil.copytree(source_app, stage, symlinks=True)

        had_app = exists_as_app(app)
        # 在记录交换结果前不交付信号，避免将已提交的 App 误判为暂存内容。
        blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            if had_app:
                swap_dirs(stage, app)
            else:
                os.rename(stage, app)
            committed = True
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
        shutil.rmtree(stage_parent)
    except BaseException as exc:
        if not committed:
            shutil.rmtree(stage_parent, ignore_errors=True)
            raise
        if not isinstance(exc, (OSError, KeyboardInterrupt)):
            raise
        residue = f"，遗留路径 {stage_parent}" if stage_parent.exists() else ""
        reason = "App 暂存清理被中断" if isinstance(exc, KeyboardInterrupt) else f"App 暂存清理失败：{exc}"
        print(f"警告：新 App 已提交到 {app}，{reason}{residue}。", file=sys.stderr)


class PublishInterrupted(KeyboardInterrupt):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    raise PublishInterrupted(signum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("app-only", *DMG_NAMES))
    parser.add_argument("output", type=Path)
    parser.add_argument("source", type=Path, nargs="?", help="不指定时仅恢复并检查目标")
    args = parser.parse_args()
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)

    output = args.output.resolve()
    try:
        output.mkdir(parents=True, exist_ok=True)
        # 直接锁住输出目录的 inode。物理别名和不同 TMPDIR 都共享同一锁，且不遗留锁文件。
        lock_fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            for name in DMG_NAMES.values():
                DmgPublication(output, name).recover()
            if args.mode == "app-only":
                exists_as_app(output / APP_NAME)
                if args.source is not None:
                    publish_app(args.source, output)
            else:
                publication = DmgPublication(output, DMG_NAMES[args.mode])
                publication.check_targets()
                if args.source is not None:
                    publication.publish(args.source)
        finally:
            os.close(lock_fd)
    except KeyboardInterrupt as exc:
        signum = getattr(exc, "signum", signal.SIGINT)
        print(f"Mac 产物发布被信号 {signum} 中断。", file=sys.stderr)
        return 128 + signum
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"Mac 产物发布失败：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
