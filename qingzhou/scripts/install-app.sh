#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import tempfile,subprocess,plistlib,shutil
installed=Path('/Applications/清舟.app')
if subprocess.run(['pgrep','-x','Qingzhou'],stdout=subprocess.DEVNULL).returncode == 0:
    raise SystemExit('请先退出清舟，再安装更新。')
with tempfile.TemporaryDirectory(prefix='qingzhou-install-') as folder:
    staging=Path(folder)
    subprocess.run(['ditto','-x','-k','dist/清舟.zip',str(staging)],check=True)
    source=staging/'清舟.app'
    info=plistlib.loads((source/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier']=='cn.local.qingzhou'
    subprocess.run(['codesign','--verify','--deep','--strict',str(source)],check=True)
    backup=staging/'previous.app'
    if installed.exists():
        assert plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']=='cn.local.qingzhou'
        shutil.move(str(installed),str(backup))
    try:
        subprocess.run(['ditto','--noextattr','--norsrc',str(source),str(installed)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(installed)],check=True)
    except:
        if installed.exists():shutil.rmtree(installed)
        if backup.exists():shutil.move(str(backup),str(installed))
        raise
print('清舟 '+info['CFBundleShortVersionString']+' 已安装到 '+str(installed))
PY
