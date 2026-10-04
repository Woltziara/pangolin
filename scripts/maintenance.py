#!/usr/bin/env python3
"""Read-only maintenance collection through an explicitly selected HDC device."""
import argparse,json,os,subprocess,time
from pathlib import Path
FILES=['dataplane-status.json','native-stats.json','runtime-journal.jsonl','runtime-journal.1.jsonl','runtime-journal.2.jsonl','runtime-journal.3.jsonl','error-journal.jsonl','error-journal.1.jsonl','error-journal.2.jsonl','error-journal.3.jsonl','system-exit-events.json','ui-feedback.json']
BUNDLE='com.oscarwoltz.tongdao'
def main():
    p=argparse.ArgumentParser();p.add_argument('--target',required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--hdc',default='/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc');a=p.parse_args()
    a.output.mkdir(mode=0o700,parents=True,exist_ok=True)
    os.chmod(a.output,0o700)
    def run(*args):return subprocess.run([a.hdc,'-t',a.target,*args],capture_output=True,text=True,timeout=40)
    text=run('shell','bm','dump','-n',BUNDLE).stdout
    if '{' not in text:raise SystemExit('Device/bundle unavailable')
    info=json.loads(text[text.index('{'):]);summary={'collectedAt':int(time.time()*1000),'versionName':info.get('versionName'),'versionCode':info.get('versionCode'),'files':[],'missing':[]}
    # The sandbox prefix is the existing user's debug app; credentials/config are never requested.
    prefix='/data/app/el2/100/base/'+BUNDLE+'/haps/entry/files/'
    for name in FILES:
        dest=a.output/name;r=run('file','recv',prefix+name,str(dest))
        if r.returncode==0 and '[Fail]' not in r.stdout and dest.is_file():os.chmod(dest,0o600);summary['files'].append(name)
        else:summary['missing'].append(name)
    listing=run('shell','ls','-1',prefix).stdout.splitlines()
    incidents=sorted(n for n in listing if n.startswith('incident-report-') and n.endswith('.json'))[-5:]
    for name in incidents:
        dest=a.output/name;r=run('file','recv',prefix+name,str(dest))
        if r.returncode==0 and '[Fail]' not in r.stdout and dest.exists():os.chmod(dest,0o600);summary['files'].append(name)
    (a.output/'collection.json').write_text(json.dumps(summary,indent=2)+'\n');os.chmod(a.output/'collection.json',0o600);print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
