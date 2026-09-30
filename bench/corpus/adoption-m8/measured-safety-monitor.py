import subprocess,time,pathlib,json,os,signal
base=pathlib.Path('/private/tmp/spec-lint-adoption-m8/evidence')
while True:
 rows=subprocess.check_output(['ps','-Ao','pid,ppid,rss,etime,command'],text=True).splitlines()
 driver=any('/private/tmp/spec-lint-adoption-m8/campaign.py' in x and 'Python ' in x for x in rows)
 if not driver: break
 parents = {line.strip().split(None, 1)[0] for line in rows if '/usr/bin/time -l -o /private/tmp/spec-lint-adoption-m8/evidence/' in line}
 for line in rows:
  if 'beam.smp' not in line or line.strip().split(None,2)[1] not in parents: continue
  pid,ppid,rss,elapsed,cmd=line.strip().split(None,4)
  days=0
  if '-' in elapsed: day,elapsed=elapsed.split('-');days=int(day)
  parts=list(map(int,elapsed.split(':')));sec=days*86400+sum(v*60**i for i,v in enumerate(reversed(parts)))
  if int(rss)>8*1024*1024 or sec>=600:
   note={'pid':int(pid),'rss_kib':int(rss),'elapsed_seconds':sec,'reason':'rss_safety' if int(rss)>8*1024*1024 else 'wall_safety'}
   with (base/'safety-interventions.jsonl').open('a') as f:f.write(json.dumps(note)+'\n')
   os.kill(int(pid),signal.SIGTERM)
 time.sleep(5)
