#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
import os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='mimi-tray-install-') as temporary:
    base=pathlib.Path(temporary)
    task_home=base/'home with spaces %'
    task_home.mkdir()
    env=dict(os.environ, HOME=str(task_home), MIMI_TRAY_NO_START='1')
    env.pop('XDG_CONFIG_HOME',None)
    tools_dir=base/'bin';tools_dir.mkdir()
    # Keep the self-test useful in root-owned CI containers without installing
    # into the real user's home or touching a real desktop bus.
    for name,text in [('id','echo 1000'),('uname','echo Linux')]:
        f=tools_dir/name;f.write_text('#!/bin/sh\n'+text+'\n');f.chmod(0o755)
    env['PATH']=str(tools_dir)+os.pathsep+env['PATH']
    def release(version):
        folder=base/version
        (folder/'scripts').mkdir(parents=True)
        (folder/'packaging/linux').mkdir(parents=True)
        (folder/'cmd/mimi-remote-tray/assets').mkdir(parents=True)
        for relative in ['scripts/install-linux-tray.sh','packaging/linux/mimi-remote.desktop','cmd/mimi-remote-tray/assets/mimi.png']:
            shutil.copy2(root/relative,folder/relative)
        for name in ['agentd','mimi-remote-tray']:
            f=folder/name
            f.write_text('#!/bin/sh\ncase "$1" in\nversion) echo '+version+';;\n--quit) exit 0;;\n*) exit 2;;\nesac\n')
            f.chmod(0o755)
        return folder
    one,two=release('1.0.0'),release('1.1.0')
    def run(folder,mode,ok=True):
        result=subprocess.run(['bash',str(folder/'scripts/install-linux-tray.sh'),mode],env=env,capture_output=True,text=True)
        assert (result.returncode==0)==ok,(mode,result.stdout,result.stderr)
    binary=task_home/'.local/bin/mimi-remote-tray'
    desktop=task_home/'.local/share/applications/mimi-remote.desktop'
    autostart=task_home/'.config/autostart/mimi-remote.desktop'
    def version():return subprocess.check_output([str(binary),'version'],text=True).strip()
    run(one,'install');assert version()=='1.0.0'
    assert ' --show' in desktop.read_text() and ' --show' not in autostart.read_text()
    assert '%%' in desktop.read_text() and 'Exec="' in desktop.read_text()
    assert binary.stat().st_mode&0o777==0o755
    autostart.write_text(autostart.read_text()+'Hidden=true\n')
    run(two,'upgrade');assert version()=='1.1.0'
    assert 'Hidden=true' in autostart.read_text(),'upgrade re-enabled disabled autostart'
    run(two,'rollback');assert version()=='1.0.0'
    run(two,'rollback');assert version()=='1.1.0'
    (one/'mimi-remote-tray').write_text('#!/bin/sh\necho incompatible\n')
    run(one,'upgrade',False);assert version()=='1.1.0'
    # Simulate a partially installed candidate: fail one atomic rename, then
    # allow rollback to restore every previous file.
    marker=base/'failed'
    mv=tools_dir/'mv'
    real_mv=shutil.which('mv')
    mv.write_text('#!/bin/bash\nif [[ "$*" == *mimi.png.new.* && ! -f "'+str(marker)+'" ]]; then touch "'+str(marker)+'"; exit 7; fi\nexec '+real_mv+' "$@"\n')
    mv.chmod(0o755)
    run(two,'upgrade',False);assert version()=='1.1.0' and desktop.exists() and autostart.exists()
    mv.unlink()
    config=task_home/'.config/mimi-remote/config.json';config.parent.mkdir();config.write_text('private-config')
    run(two,'uninstall');run(two,'uninstall')
    assert not binary.exists() and not desktop.exists() and not autostart.exists()
    assert config.read_text()=='private-config'
    print('Linux 托盘安装回归通过：安装、空格/百分号路径、禁用自启动保留、升级、回滚、失败恢复、重复卸载。')
PY
