"""Embed the measured local source identity consumed by the running app."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
ASSET='entry/src/main/resources/rawfile/pangolin-build.json'
def generate():
    names=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=ROOT).decode().split('\0')
    rows=[]
    for name in sorted(set(names)):
        if not name or name==ASSET or name.endswith('.md'):continue
        p=ROOT/name
        if p.is_file() and not p.is_symlink():rows.append([name,hashlib.sha256(p.read_bytes()).hexdigest()])
    identity=hashlib.sha256(json.dumps(rows,separators=(',',':')).encode()).hexdigest()
    app=json.loads((ROOT/'AppScope/app.json5').read_text())['app']
    receipt={'schema':1,'sourceIdentity':identity,'versionName':app['versionName'],'versionCode':app['versionCode'],'faultInjection':False}
    dest=ROOT/ASSET;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(json.dumps(receipt,sort_keys=True)+'\n')
    print('Embedded source identity:',identity)
    return identity
if __name__=='__main__':generate()
