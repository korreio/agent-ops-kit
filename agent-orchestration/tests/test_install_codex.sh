#!/usr/bin/env bash
# Hermetic native Codex installer regression matrix. No real provider process or HOME.
set -euo pipefail
unset CODEX_HOME CLAUDE_CONFIG_DIR   # a provider home of the caller's would refuse the wrapper cases below
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || TMP_ROOT=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-orch-codex.XXXXXX" 2>/dev/null)" || TMP=""
{ [ -n "$TMP_ROOT" ] && [ -n "$TMP" ] && [ -d "$TMP" ] && TMP="$(cd "$TMP" && pwd -P)" && case "$TMP" in "$TMP_ROOT"/?*) true;; *) false;; esac; } \
  || { echo 'cannot create sandbox; aborting, nothing removed' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
python3 -I -B - "$PKG" "$TMP" <<'PY'
import contextlib,errno,hashlib,importlib.util,io,itertools,json,os,pathlib,shutil,subprocess,sys,tomllib
pkg,tmp=map(pathlib.Path,sys.argv[1:]); copied=tmp/'package';shutil.copytree(pkg,copied)
helper=copied/'codex/install.py'
spec=importlib.util.spec_from_file_location('native_install',helper);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
passed=0
def check(name,condition):
    global passed
    assert condition,name
    passed+=1;print('  ok '+name)
def home(name):
    p=tmp/name/'.codex';p.mkdir(parents=True);return p
def run(h,*targets,apply=False,env=None):
    args=[sys.executable,'-I','-B',str(helper),'--home',str(h),'--mode','apply' if apply else 'check',*targets]
    e=dict(os.environ,HOME=str(h.parent));e.update(env or {})
    return subprocess.run(args,env=e,capture_output=True,text=True)
def tree(p):
    return [(str(x.relative_to(p)),x.lstat().st_ino,x.lstat().st_mtime_ns,os.readlink(x) if x.is_symlink() else x.read_bytes() if x.is_file() else None) for x in sorted(p.rglob('*'))]
# Use a minimal synthetic config fragment; source artifact/schema checks belong to parent suite.
fragment=copied/'codex/config-fragment.toml'
fragment.write_text('default_permissions = "development"\napproval_policy = "on-request"\nproject_doc_max_bytes = 65536\n[features]\nhooks = true\nmulti_agent = true\n[permissions.development]\nnetwork = true\n[permissions.orchestration-review]\nnetwork = false\n')
h=home('dry');(h/'config.toml').write_text('# private keep\nnotify = ["private-fixture"]\n')
before=tree(h);r=run(h,'config','agents','skills','hooks')
check('explicit dry-run writes nothing and prints no existing values',r.returncode==0 and before==tree(h) and 'private-fixture' not in r.stdout)
role_plans=[line for line in r.stdout.splitlines() if 'PLAN '+str(h/'agents')+'/' in line]
check('role dry-run describes regular managed copies rather than a config merge',len(role_plans)==11 and all(line.endswith(': install managed role copy') for line in role_plans))
r=run(h,'config',apply=True);data=(h/'config.toml').read_bytes()
check('config apply preserves unrelated original bytes',r.returncode==0 and data.startswith(b'# private keep\nnotify = ["private-fixture"]\n'))
check('replacement backed up beside config',len(list(h.glob('config.toml.bak-*')))==1)
h=home('mode-word');preview=run(h,'config','agents');applied=run(h,'config','agents',apply=True)
check('a preview reports PLAN and never APPLY',preview.returncode==0 and '  PLAN ' in preview.stdout and '  APPLY ' not in preview.stdout)
check('an apply reports APPLY and never PLAN, for roles and for each configuration key',applied.returncode==0 and '  PLAN ' not in applied.stdout and 'APPLY '+str(h/'config.toml')+': set ' in applied.stdout and 'APPLY '+str(h/'agents')+'/' in applied.stdout)
before=tree(h);r=run(h,'config',apply=True)
check('repeat config apply is byte/inode idempotent',r.returncode==0 and tree(h)==before)
h=home('legacy');(h/'config.toml').write_text('sandbox_mode = "workspace-write"\n# keep legacy context\n[ sandbox_workspace_write ]\nnetwork_access = true\n[features]\nhooks = false # keep selected comment\nother = false\n[projects.fixture]\ntrust_level = "untrusted"\n')
before=tree(h);dry=run(h,'coordinator')
check('legacy dry-run names removed keys without exposing their values',dry.returncode==0 and tree(h)==before and 'remove legacy sandbox_mode' in dry.stdout and 'remove legacy sandbox_workspace_write' in dry.stdout and 'workspace-write' not in dry.stdout and 'network_access' not in dry.stdout)
r=run(h,'coordinator',apply=True);text=(h/'config.toml').read_text();parsed=tomllib.loads(text)
check('only legacy sandbox settings removed, unrelated section/comment preserved',r.returncode==0 and 'sandbox_mode' not in parsed and 'sandbox_workspace_write' not in parsed and parsed['features']['other'] is False and '# keep selected comment' in text and '# keep legacy context' in text)
h=home('conflict');(h/'config.toml').write_text('[permissions.orchestration-review]\nnetwork = true\n');before=tree(h);r=run(h,'config',apply=True)
check('conflicting named profile refused without writes',r.returncode!=0 and tree(h)==before)
h=home('lane-boundary');cfg=h/'config.toml';original='model = "owner-private"\ndefault_permissions = "owner"\napproval_policy = "never"\nsandbox_mode = "workspace-write"\n[features]\nhooks = false\nmulti_agent = false\n[permissions.development]\nnetwork = false\n';cfg.write_text(original)
r=run(h,'config',apply=True);parsed=tomllib.loads(cfg.read_text())
check('lane config preserves global defaults, features, legacy settings and coordinator profile byte for byte',r.returncode==0 and cfg.read_text().startswith(original) and parsed['features']=={'hooks':False,'multi_agent':False} and parsed['permissions']['development']=={'network':False})
check('lane apply names each changed key with the package value and no existing value', 'APPLY '+str(cfg)+': set permissions.orchestration-review.network = false' in r.stdout and 'owner-private' not in r.stdout and 'set default_permissions' not in r.stdout)
h=home('coordinator-boundary');cfg=h/'config.toml';cfg.write_text('default_permissions = "owner-private"\n[features]\nhooks = false\nother = true\n[permissions.orchestration-local]\nnetwork = false\n')
r=run(h,'coordinator',apply=True);parsed=tomllib.loads(cfg.read_text())
check('coordinator explicit opt-in names defaults and features and preserves unselected lane profiles',r.returncode==0 and parsed['default_permissions']=='development' and parsed['features']['other'] is True and parsed['permissions']['orchestration-local']=={'network':False} and 'set default_permissions = "development"' in r.stdout and 'set features.hooks = true' in r.stdout and 'owner-private' not in r.stdout)
# The preview is what the owner inspects before changing their security posture: it names the
# package's public values, and an existing value, here a stricter one, stays withheld.
h=home('coordinator-preview');cfg=h/'config.toml';cfg.write_text('approval_policy = "owner-secret"\n');before=tree(h);r=run(h,'coordinator')
check('coordinator preview names each package value it would set and withholds the existing one',r.returncode==0 and tree(h)==before and 'PLAN '+str(cfg)+': set approval_policy = "on-request"' in r.stdout and 'PLAN '+str(cfg)+': set permissions.development.network = true' in r.stdout and 'set project_doc_max_bytes = 65536' in r.stdout and 'owner-secret' not in r.stdout and 'withheld' not in r.stdout)
h=home('bad-dir');(h/'agents').write_text('sentinel');before=tree(h);r=run(h,'agents',apply=True)
check('non-directory target refused without writes',r.returncode!=0 and tree(h)==before)
h=home('symlink-dir');other=tmp/'outside';other.mkdir();(h/'skills').symlink_to(other);r=run(h,'skills',apply=True)
check('symlink parent refused without writes',r.returncode!=0 and not list(other.iterdir()))
h=home('links');agent=next((copied/'codex/agents').glob('*.toml'));(h/'agents').mkdir();dst=h/'agents'/agent.name;dst.write_text('local-copy\n');before=tree(h);r=run(h,'agents',apply=True)
check('differing role file refused and preserved',r.returncode!=0 and tree(h)==before)
shutil.copyfile(agent,dst);original=dst.read_bytes();r=run(h,'agents',apply=True)
check('identical unmarked role becomes a managed regular copy with adjacent backup',r.returncode==0 and dst.is_file() and not dst.is_symlink() and dst.read_bytes()==b'# agent-ops-kit managed role sha256: '+hashlib.sha256(original).hexdigest().encode()+b'\n'+original and any(x.read_bytes()==original for x in dst.parent.glob(dst.name+'.bak-*')))
before=tree(h);r=run(h,'agents',apply=True);check('repeat managed role installation is byte/inode idempotent',r.returncode==0 and before==tree(h))
mapping={'reviewer':'reviewer-wide','reviewer-deep':'reviewer-deep','reviewer-wide':'reviewer-wide','escalation':'reviewer-deep','writer-bounded':'writer','writer-takeover':'writer','explorer-locate':'explorer-locate','explorer-trace':'explorer-trace','designer':'designer','verifier':'verifier','relay':'relay'}
check('every fresh installed role is regular and fits its Claude counterpart byte/line budget',all((h/'agents'/f'{role}.toml').is_file() and not (h/'agents'/f'{role}.toml').is_symlink() and len((h/'agents'/f'{role}.toml').read_bytes())<=len((copied/'claude/agents'/f'{counterpart}.md').read_bytes()) and len((h/'agents'/f'{role}.toml').read_bytes().splitlines())<=len((copied/'claude/agents'/f'{counterpart}.md').read_bytes().splitlines()) for role,counterpart in mapping.items()))
installed=dst.read_bytes();agent.write_bytes(original+b'\n# fixture package upgrade\n');r=run(h,'agents',apply=True)
check('unmodified marked role upgrades with exact prior copy backed up',r.returncode==0 and dst.read_bytes().split(b'\n',1)[1]==agent.read_bytes() and any(x.read_bytes()==installed for x in dst.parent.glob(dst.name+'.bak-*')))
before=tree(h);r=run(h,'agents',apply=True);check('upgraded role settles without writes',r.returncode==0 and before==tree(h));agent.write_bytes(original)
dst.write_bytes(dst.read_bytes()+b'# owner edit\n');before=tree(h);r=run(h,'agents',apply=True)
check('tampered generated role refused and preserved with no writes',r.returncode!=0 and tree(h)==before)
h=home('owned-role-symlinks');(h/'agents').mkdir();roles=sorted((copied/'codex/agents').glob('*.toml'))
for role in roles:(h/'agents'/role.name).symlink_to(role)
def dispatch_standin(path):
    # Match the observed native open boundary; no provider process is involved.
    if path.is_symlink():raise OSError(errno.ELOOP,'role open refuses symlinks')
    return tomllib.loads(path.read_text())['developer_instructions']
try:dispatch_standin(h/'agents'/agent.name)
except OSError as error:rejected=error.errno==errno.ELOOP
else:rejected=False
before=tree(h);r=run(h,'agents');check('owned role symlink migration dry-run writes nothing',r.returncode==0 and tree(h)==before)
r=run(h,'agents',apply=True)
check('installed owned symlinks migrate to dispatchable regular roles with adjacent symlink backups',rejected and r.returncode==0 and all(not (h/'agents'/role.name).is_symlink() and dispatch_standin(h/'agents'/role.name) and any(x.is_symlink() and os.readlink(x)==str(role) for x in (h/'agents').glob(role.name+'.bak-*')) for role in roles))
before=tree(h);r=run(h,'agents',apply=True);check('migrated owned role copies settle byte/inode unchanged',r.returncode==0 and before==tree(h))
h=home('role-preflight');(h/'agents').mkdir();last=h/'agents'/roles[-1].name;last.write_bytes(b'# agent-ops-kit managed role sha256: '+b'0'*64+b'\n'+roles[-1].read_bytes());before=tree(h);r=run(h,'agents',apply=True)
check('all roles preflight before any write when the last generated role is tampered',r.returncode!=0 and tree(h)==before)
h=home('role-cas');(h/'agents').mkdir();inst=m.Installer(h,True);replace=inst.replace;first=h/'agents'/roles[0].name;owner_bytes=b'# appeared after role preflight\n';refused=False
def owner_before_role_replace(path,*args,**kwargs):
    if path==first:path.write_bytes(owner_bytes)
    return replace(path,*args,**kwargs)
inst.replace=owner_before_role_replace
with contextlib.redirect_stdout(io.StringIO()):
    try:inst.links('agents')
    except m.Refusal:refused=True
check('managed role copies compare-and-swap the preflight snapshot and preserve concurrent creation',refused and first.read_bytes()==owner_bytes and list((h/'agents').iterdir())==[first])
h=home('different-link');(h/'agents').mkdir();different=tmp/'different-role';different.write_text('unique local role\n');dst=h/'agents'/agent.name;dst.symlink_to(different);before=tree(h);r=run(h,'agents',apply=True)
check('differing role symlink preserved',r.returncode!=0 and tree(h)==before and different.read_text()=='unique local role\n')
different.write_bytes(agent.read_bytes());before=tree(h);r=run(h,'agents',apply=True)
check('foreign role link refused even when target bytes equal package source',r.returncode!=0 and tree(h)==before)
h=home('different-hook');(h/'hooks').mkdir();script=next((copied/'codex/hooks').glob('*.sh'));(h/'hooks'/script.name).write_text('unique local hook\n');before=tree(h);r=run(h,'hooks',apply=True)
check('differing hook script refused before any link/config change',r.returncode!=0 and tree(h)==before)
h=home('concurrent');cfg=h/'config.toml';cfg.write_text('# initial\n');inst=m.Installer(h,True);old=m.snapshot(cfg);cfg.write_text('# concurrent\n')
try: inst.replace(cfg,data=b'# replacement\n',expected=old)
except m.Refusal: pass
else: raise AssertionError('concurrent snapshot must refuse')
check('compare-and-swap refuses concurrent update',cfg.read_text()=='# concurrent\n' and not list(h.glob('*.bak-*')))
h=home('concurrent-absent');inst=m.Installer(h,True);cfg=h/'config.toml';cfg.write_text('# appeared\n')
try: inst.replace(cfg,data=b'# replacement\n',expected=None)
except m.Refusal: pass
else: raise AssertionError('concurrent creation must refuse')
check('compare-and-swap protects concurrent creation',cfg.read_text()=='# appeared\n')
h=home('concurrent-backup');cfg=h/'config.toml';cfg.write_text('# initial\n');inst=m.Installer(h,True);real_backup=m.backup
m.backup=lambda p:p.write_text('# changed during backup\n')
try:
    try: inst.replace(cfg,data=b'# replacement\n')
    except m.Refusal: pass
    else: raise AssertionError('backup race must refuse')
finally:m.backup=real_backup
check('concurrent update during backup is kept, temporary removed',cfg.read_text()=='# changed during backup\n' and not list(h.glob('*.tmp-*')))
# Ordinary valid TOML arrays and EOF statements must keep their exact source bytes.
array_text='[[skills.config]]\npath = "first"\nenabled = false\n[[skills.config]]\npath = "second"\nenabled = true\n'
result=m.merge_toml(array_text,{():{'project_doc_max_bytes':65536},('features',):{'hooks':True}})
check('repeated unrelated skill array tables preserved',array_text in result and tomllib.loads(result)['skills']['config']==tomllib.loads(array_text)['skills']['config'])
for label,text,updates in [
 ('root EOF','notify = ["keep"]',{():{'project_doc_max_bytes':65536}}),
 ('table EOF','[features]',{('features',):{'hooks':True}}),
 ('comment EOF','# keep comment',{():{'project_doc_max_bytes':65536}}),
 ('value EOF','[features]\nother = false',{('features',):{'hooks':True}}),
]:
 result=m.merge_toml(text,updates)
 check(label+' accepts missing newline and retains original bytes',all(line in result for line in text.splitlines()) and m.merge_toml(result,updates)==result)
# Insertion order at a shared boundary. An empty table that ends the file, or a file with no
# table at all, puts lines for an existing table (root included) and new table blocks at the
# same place: the existing lines must come first whatever order the updates arrive in.
def merge(text,updates):
    try:return m.merge_toml(text,updates)
    except m.Refusal:return None
trust={'k:1':{'enabled':True,'trusted_hash':'sha256:'+'0'*64}}
trust_line='"k:1" = {"enabled" = true, "trusted_hash" = "sha256:'+'0'*64+'"}\n'
settled='model="x"\n[hooks.state]\n'+trust_line+'\n["features"]\n"hooks" = true\n'
for label,text in [('with','model="x"\n[hooks.state]\n'),('without','model="x"\n[hooks.state]')]:
 for first,order in [('new table',[('features',),('hooks','state')]),('existing table',[('hooks','state'),('features',)])]:
  updates={sec:{('features',):{'hooks':True},('hooks','state'):trust}[sec] for sec in order}
  check('empty last table '+label+' final newline, '+first+' update first: existing-table lines precede the new header',merge(text,updates)==settled and merge(settled,updates)==settled)
selected={():{'project_doc_max_bytes':65536},('features',):{'hooks':True},('hooks','state'):trust}
for label,text in [
 ('empty last table','model="x"\n[hooks.state]\n'),
 ('empty last table, no final newline','model="x"\n[hooks.state]'),
 ('populated last table','model="x"\n[hooks.state]\n"old" = { enabled = false }\n'),
 ('populated last table, no final newline','model="x"\n[hooks.state]\n"old" = { enabled = false }'),
 ('no table','model="x"\n'),
 ('no table, no final newline','model="x"'),
 ('empty file',''),
]:
 want=tomllib.loads(text);want['project_doc_max_bytes']=65536;want.setdefault('features',{})['hooks']=True;want.setdefault('hooks',{}).setdefault('state',{}).update(trust)
 failed=[]
 for order in itertools.permutations(selected):
  updates={sec:selected[sec] for sec in order};result=merge(text,updates);kept=iter((result or '').splitlines())
  # Whole-document equality: nothing lands in a wrong table. Original lines survive in order.
  if result is None or tomllib.loads(result)!=want or not all(line in kept for line in text.splitlines()) or merge(result,updates)!=result:
   failed.append(['.'.join(sec) or 'root' for sec in order])
 check(label+': every update order reaches the same settings, keeps the original lines and settles'+(' (failed orders: '+repr(failed)+')' if failed else ''),not failed)
try:m.merge_toml('[[features]]\nhooks = false\n',{('features',):{'hooks':True}})
except m.Refusal:pass
else:raise AssertionError('managed array overlap must refuse')
check('managed array table refused',True)
# Owned mapping replacement is semantic: obsolete descendants disappear even when
# section declarations are interleaved with unselected tables and comments.
mapping_path=('hooks','state');new_state={'enabled':True,'trusted_hash':'sha256:new'}
sibling='[hooks.state.sibling]\nenabled = false # sibling bytes\n'
section_state='[hooks.state."native key"] # selected header\nenabled = false # selected enabled\ntrusted_hash = "sha256:old"\n[hooks.state."native key".obsolete]\nfield = "old" # obsolete field context\n'+sibling+'[hooks.state."native key".obsolete.later]\nfield = "also old"\n'
for label,text in [
 ('section',section_state),
 ('descendant-only','[hooks.state."native key".obsolete]\nfield="old"\n'+sibling),
 ('dotted','hooks.state."native key".enabled = false # keep dotted context\nhooks.state."native key".obsolete = "old"\n'),
 ('inline','[hooks.state]\n"native key" = { enabled = false, obsolete = "old" } # keep inline context\n'),
]:
 for desired in (new_state,{}):
  updates={mapping_path:{'native key':desired}};result=m.merge_toml(text,updates)
  check(label+' owned mapping fully replaced by '+('empty' if not desired else 'new')+' state and settles',tomllib.loads(result)['hooks']['state']['native key']==desired and m.merge_toml(result,updates)==result)
  check(label+' unselected bytes and every comment retained',all(line in result for line in text.splitlines(keepends=True) if line.lstrip().startswith('#') or 'sibling' in line) and all(comment in result for comment in ('# selected header','# selected enabled','# obsolete field context') if comment in text) and (sibling in result if sibling in text else True) and all(comment in result for comment in ('# keep dotted context','# keep inline context') if comment in text))
# A table that dotted keys define cannot be reopened by a header. A state those declarations
# lack joins their declaring section under its relative dotted path, beside a replaced one:
# at the root or under [hooks], whatever follows, with and without a final newline.
added_state={'enabled':True,'trusted_hash':'sha256:added'};old_state={'enabled':False,'obsolete':'old'}
follower='[owner.fixture]\nvalue = "keep exact bytes" # owner context\n'
for label,head,stem in [
 ('root','# owner head\nmodel = "x"\n','hooks.state'),
 ('[hooks] parent','model = "x"\n[hooks] # owner header\n','state'),
]:
 body=head+stem+'."native key".enabled = false # keep dotted context\n'+stem+'."native key".obsolete = "old"\n'
 relative='\n'+'.'.join(json.dumps(part) for part in stem.split('.'))+'."missing key" = '
 for place,tail in [('ending the file',''),('before another table',follower)]:
  for ending,text in [('with',body+tail),('without',(body+tail)[:-1])]:
   failed=[]
   for replaced,missing in itertools.product((new_state,{},old_state),(added_state,{})):
    updates={('features',):{'hooks':True},mapping_path:{'native key':replaced,'missing key':missing}};result=merge(text,updates)
    want=tomllib.loads(text);want['features']={'hooks':True};want['hooks']['state']={'native key':replaced,'missing key':missing}
    # Whole-document equality: nothing lands in a wrong table. No header reopens the table.
    if (result is None or tomllib.loads(result)!=want or merge(result,updates)!=result or relative not in result
        or any(line.startswith('[') and 'state' in line for line in result.splitlines())
        or '# keep dotted context' not in result or not all(line in result.splitlines() for line in (head+tail).splitlines())):
     failed.append((replaced,missing))
   check(label+' dotted states '+place+', '+ending+' final newline: a missing state joins the declaring section beside a replaced one and settles'+(' (failed: '+repr(failed)+')' if failed else ''),not failed)
# Fake app-server supplies only fixture metadata. No authentication or provider invocation.
# Like the native loader it reads CODEX_HOME, else $HOME/.codex; it keys a hook by position and
# hashes its handler with the group attributes, so distinct definitions get distinct hashes. It
# counts its launches beside the home, and FIXTURE_RACE='<launch>|<file>|<text>' appends to a home
# file during that launch.
bindir=tmp/'bin';bindir.mkdir();fake=bindir/'codex'
shared='''import hashlib,json
def digest(group,hook):
 return 'sha256:'+hashlib.sha256(json.dumps([{k:v for k,v in group.items() if k!='hooks'},hook],sort_keys=True).encode()).hexdigest()
def listing(d):
 return [{'key':'fixture:'+event+':'+str(gi)+':'+str(hi),'currentHash':digest(group,hook),'source':'global','eventName':event[0].lower()+event[1:],'command':hook['command']} for event,groups in d.items() for gi,group in enumerate(groups) for hi,hook in enumerate(group['hooks'])]
'''
exec(shared)
fake.write_text('#!'+sys.executable+'\n'+shared+'''import os,pathlib,sys
h=pathlib.Path(os.environ.get('CODEX_HOME') or os.environ['HOME']+'/.codex');items=listing(json.loads((h/'hooks.json').read_text())['hooks'])
calls=h.parent/'calls';turn=int(calls.read_text())+1 if calls.exists() else 1;calls.write_text(str(turn))
race=os.environ.get('FIXTURE_RACE','').split('|',2)
if race[0]==str(turn):
 with open(h/race[1],'a') as f:f.write(race[2])
for line in sys.stdin:
 x=json.loads(line)
 if 'id' in x:
  if x['method']=='hooks/list' and os.environ.get('FIXTURE_FAIL')==str(turn):
   print(json.dumps({'id':x['id'],'error':{'message':'fixture metadata failure'}}),flush=True);continue
  result={'data':[{'hooks':items}]} if x['method']=='hooks/list' else {}
  print(json.dumps({'id':x['id'],'result':result}),flush=True)
''');fake.chmod(0o755)
h=home('hooks');(h/'config.toml').write_text('[hooks.state]\n"unrelated" = { trusted_hash = "keep", enabled = false }\n');r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
parsed=tomllib.loads((h/'config.toml').read_text())
check('exact native definition hashes trusted, unrelated trust preserved',r.returncode==0 and parsed['hooks']['state']['unrelated']['trusted_hash']=='keep' and parsed['features']['hooks'] is True and any(k.startswith('fixture:') for k in parsed['hooks']['state']))
check('hook trust lines withhold their values, which carry stored owner states',[l for l in r.stdout.splitlines() if ': set hooks.state.' in l] and all(l.endswith('(value withheld)') for l in r.stdout.splitlines() if ': set hooks.state.' in l) and 'sha256:' not in r.stdout)
check('new installation reads native metadata once, after the link',(h.parent/'calls').read_text()=='1')
before=tree(h);r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
check('repeat hook/trust apply idempotent',r.returncode==0 and before==tree(h))
# First installation over owner states that dotted keys define, at the root or under [hooks]:
# the package trust joins them where they are declared and the owner's bytes stay as written.
package_trust={x['key']:{'trusted_hash':x['currentHash'],'enabled':True} for x in listing(json.loads((copied/'codex/hooks.json').read_text())['hooks'])}
for name,label,text in [
 ('root','root','hooks.state."unrelated".trusted_hash = "keep" # owner context\nhooks.state."unrelated".enabled = false\n'),
 ('parent','[hooks] parent','[hooks]\nstate."unrelated".trusted_hash = "keep" # owner context\nstate."unrelated".enabled = false\n'),
]:
 h=home('hooks-dotted-'+name);(h/'config.toml').write_text(text);r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
 result=(h/'config.toml').read_text();parsed=tomllib.loads(result)
 check('first installation over '+label+' dotted hook states trusts the package beside them, owner bytes kept',r.returncode==0 and result.startswith(text) and parsed['features']['hooks'] is True and parsed['hooks']['state']==dict(package_trust,unrelated={'trusted_hash':'keep','enabled':False}))
 before=tree(h);r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
 check('first installation over '+label+' dotted hook states settles',r.returncode==0 and before==tree(h))
# The loader must read the home being edited, whichever home this process inherited.
for label,inherited in [('CODEX_HOME',lambda other:{'CODEX_HOME':str(other)}),('HOME',lambda other:{'HOME':str(other.parent)})]:
 h=home('hooks-inherited-'+label);decoy=home('hooks-decoy-'+label);(decoy/'hooks.json').write_text('{"hooks":{}}')
 r=run(h,'hooks',apply=True,env=dict(inherited(decoy),PATH=str(bindir)))
 check('hook metadata comes from the target home under an inherited '+label+' elsewhere',r.returncode==0 and tomllib.loads((h/'config.toml').read_text())['hooks']['state']==package_trust and (h.parent/'calls').read_text()=='1' and not (decoy.parent/'calls').exists())
h=home('hook-upgrade')
package_hooks=json.loads((copied/'codex/hooks.json').read_text())
package_event=next(iter(package_hooks['hooks']))
package_hooks['hooks'][package_event][0]['timeout']=7
(copied/'codex/hooks.json').write_text(json.dumps(package_hooks))
old_group=json.loads(json.dumps(package_hooks['hooks'][package_event][0]))
old_group['timeout']=999
old_group['local_group_attribute']='preserve'
unrelated={'type':'command','command':'local fixture unrelated hook','timeout':27}
old_group['hooks'].append(unrelated)
(h/'hooks.json').write_text(json.dumps({'local_root_attribute':'preserve','hooks':{package_event:[old_group]}}))
r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
upgraded=json.loads((h/'hooks.json').read_text())
handlers=[handler for group in upgraded['hooks'][package_event] for handler in group['hooks']]
package_commands=[handler['command'] for group in package_hooks['hooks'][package_event] for handler in group['hooks']]
check('regular hooks upgrade trusts one definition per command and preserves unrelated mixed handlers',r.returncode==0 and all(sum(handler.get('command')==command for handler in handlers)==1 for command in package_commands) and unrelated in handlers and upgraded['local_root_attribute']=='preserve' and all(group.get('timeout')==7 for group in upgraded['hooks'][package_event] if any(handler.get('command') in package_commands for handler in group['hooks'])) and any(group.get('timeout')==999 and group.get('local_group_attribute')=='preserve' and unrelated in group['hooks'] for group in upgraded['hooks'][package_event]))
before=tree(h);r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
check('regular hook upgrade becomes idempotent',r.returncode==0 and before==tree(h))
h=home('hook-conflict');conflicting=json.loads(json.dumps(old_group));conflicting['matcher']='other';(h/'hooks.json').write_text(json.dumps({'hooks':{package_event:[old_group,conflicting]}}));before=tree(h);r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
check('ambiguous package hook group conflict refused before writes',r.returncode!=0 and before==tree(h))
# Native trust is keyed by position, so a merge that moves the owner's hooks must move their
# stored states with them: verbatim, all from the states read before the write, never minted.
# Old groups: package-only, mixed (trusted T), disabled D, modified M, stateless N. The merge
# drops the first group, so each foreign hook lands on the key another hook held before.
pk=package_hooks['hooks'][package_event][0]['hooks'];prefix='fixture:'+package_event+':';fixture={'PATH':str(bindir)}
own=lambda name:{'type':'command','command':'local fixture '+name}
T,D,M,N=own('trusted'),own('disabled'),own('modified'),own('stateless')
layout=[{'matcher':'Bash','hooks':pk[:2]},{'matcher':'Bash','timeout':999,'hooks':pk[2:]+[T]},{'matcher':'own','hooks':[D]},{'matcher':'own','hooks':[M]},{'matcher':'own','hooks':[N]}]
was={x['command']:x for x in listing({package_event:layout})};stale='sha256:'+'b'*64
stored={'unrelated':{'trusted_hash':'keep','enabled':False},prefix+'0:0':{'trusted_hash':'sha256:'+'c'*64,'enabled':True},
 was[T['command']]['key']:{'trusted_hash':was[T['command']]['currentHash'],'enabled':True},
 was[D['command']]['key']:{'trusted_hash':was[D['command']]['currentHash'],'enabled':False},
 was[M['command']]['key']:{'trusted_hash':stale,'enabled':True}}
frozen_text='[hooks.state]\n'+''.join(json.dumps(k)+' = '+m.value(v)+'\n' for k,v in stored.items())
def moving(name):
    h=home(name);(h/'hooks.json').write_text(json.dumps({'hooks':{package_event:layout}}));(h/'config.toml').write_text(frozen_text);return h
h=moving('hook-carry');r=run(h,'hooks',apply=True,env=fixture)
now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
at=lambda hook:got.get(now[hook['command']]['key'])
check('fixture moves every foreign hook to another key with its definition hash unchanged',r.returncode==0 and all(now[x['command']]['key']!=was[x['command']]['key'] and now[x['command']]['currentHash']==was[x['command']]['currentHash'] for x in (T,D,M,N)))
check('moved trusted foreign hook keeps its own trust state',at(T)==stored[was[T['command']]['key']])
check('moved disabled foreign hook stays disabled',at(D)==stored[was[D['command']]['key']] and at(D)['enabled'] is False)
check('moved modified foreign hook keeps its nonmatching trusted hash, never the current one',at(M)=={'trusted_hash':stale,'enabled':True} and now[M['command']]['currentHash']!=stale)
check('foreign hook without state gets an empty state, not the previous occupant state or a hash',at(N)=={} and now[N['command']]['key'] in stored)
check('package definitions alone receive fresh exact hashes, unrelated state kept',all(got[now[c]['key']]=={'trusted_hash':now[c]['currentHash'],'enabled':True} for c in package_commands) and got['unrelated']==stored['unrelated'])
check('upgrade reads native metadata once before and once after the write',(h.parent/'calls').read_text()=='2')
before=tree(h);r=run(h,'hooks',apply=True,env=fixture)
check('carried trust settles: repeat apply changes nothing and reads metadata once',r.returncode==0 and before==tree(h) and (h.parent/'calls').read_text()=='3')
# Repeat the migration with native states expressed as explicit tables. A destination
# has obsolete nested fields; the stateless hook must erase the preceding occupant.
section_stored=json.loads(json.dumps(stored));section_stored[prefix+'0:0']['obsolete']={'leaf':'remove'}
section_stored[was[M['command']]['key']]['obsolete']={'leaf':'carry only with modified hook'}
section_stored['unrelated']['notes']={'keep':'owner'}
blocks=[]
for key,state_value in section_stored.items():
 heading='[hooks.state.'+json.dumps(key)
 blocks.append(heading+'] # state context\n'+''.join(json.dumps(k)+' = '+m.value(v)+'\n' for k,v in state_value.items() if not isinstance(v,dict)))
 for k,v in state_value.items():
  if isinstance(v,dict):blocks.append(heading+'.'+json.dumps(k)+']\n'+''.join(json.dumps(n)+' = '+m.value(x)+' # descendant context\n' for n,x in v.items()))
unselected='[owner.fixture]\nvalue = "keep exact bytes" # owner context\n'
# Interleave an unrelated section between an owned root and its nested declaration.
blocks.insert(3,unselected)
section_frozen=''.join(blocks);h=home('hook-carry-sections')
(h/'hooks.json').write_text(json.dumps({'hooks':{package_event:layout}}));(h/'config.toml').write_text(section_frozen)
r=run(h,'hooks',apply=True,env=fixture);result=(h/'config.toml').read_text()
now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads(result)['hooks']['state']
check('section-form migration preserves trusted, disabled and modified states verbatim',r.returncode==0 and all(got[now[x['command']]['key']]==section_stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[D['command']]['key']]['enabled'] is False and got[now[M['command']]['key']]['trusted_hash']==stale)
check('section-form destination drops obsolete fields and clears stateless trust',got[now[T['command']]['key']]==stored[was[T['command']]['key']] and got[now[N['command']]['key']]=={})
check('section-form migration preserves interleaved siblings and comments',unselected in result and got['unrelated']==section_stored['unrelated'] and result.count('# state context')==section_frozen.count('# state context') and result.count('# descendant context')==section_frozen.count('# descendant context'))
check('section-form migration mints only package definition hashes',all(got[now[c]['key']]=={'trusted_hash':now[c]['currentHash'],'enabled':True} for c in package_commands))
before=tree(h);r=run(h,'hooks',apply=True,env=fixture)
check('section-form migration second apply is byte/inode idempotent',r.returncode==0 and before==tree(h) and (h.parent/'calls').read_text()=='3')
h=home('hook-ambiguous');twin={'matcher':'own','hooks':[own('twin')]}
(h/'hooks.json').write_text(json.dumps({'hooks':{package_event:[twin,twin]}}));(h/'config.toml').write_text('[hooks.state]\n'+json.dumps(prefix+'0:0')+' = '+m.value({'trusted_hash':digest(twin,twin['hooks'][0]),'enabled':True})+'\n')
before=tree(h);r=run(h,'hooks',apply=True,env=fixture)
check('foreign hooks sharing one identity refused before any write',r.returncode!=0 and before==tree(h) and 'repeat one definition' in r.stdout)
owner_line='"owner:concurrent" = { enabled = false }\n'
h=moving('race-before');original=(h/'hooks.json').read_bytes();r=run(h,'hooks',apply=True,env=dict(fixture,FIXTURE_RACE='1|config.toml|'+owner_line))
check('trust changed while old metadata was read: refused before any write, owner change kept',r.returncode!=0 and (h/'hooks.json').read_bytes()==original and (h/'config.toml').read_text()==frozen_text+owner_line and not (h/'hooks').exists())
h=moving('race-after');r=run(h,'hooks',apply=True,env=dict(fixture,FIXTURE_RACE='2|config.toml|'+owner_line))
check('trust changed while new metadata was read: old positions recovered and owner change kept',r.returncode!=0 and (h/'config.toml').read_text()==frozen_text+owner_line and not list(h.glob('config.toml.bak-*')) and json.loads((h/'hooks.json').read_text())['hooks'][package_event]==layout and 'RECOVERED' in r.stdout)
r=run(h,'hooks',apply=True,env=fixture);now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
check('retry after trust refusal carries original states and retains concurrent config',r.returncode==0 and all(got[now[x['command']]['key']]==stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[N['command']]['key']]=={} and got['owner:concurrent']=={'enabled':False})
h=moving('metadata-after');original=(h/'hooks.json').read_bytes();r=run(h,'hooks',apply=True,env=dict(fixture,FIXTURE_FAIL='2'))
check('post-write native metadata failure recovers exact hook bytes without masking refusal',r.returncode!=0 and (h/'hooks.json').read_bytes()==original and (h/'config.toml').read_text()==frozen_text and 'RECOVERED' in r.stdout and 'rejected hook metadata' in r.stdout)
r=run(h,'hooks',apply=True,env=fixture);now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
check('retry after metadata failure preserves original disabled and modified trust',r.returncode==0 and all(got[now[x['command']]['key']]==stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[N['command']]['key']]=={})
def recovery_names(stdout,path):
    # The BACKUP line names the same file: only the recovery line itself may vouch for it.
    lines=[line for line in stdout.splitlines() if 'RECOVERY INCOMPLETE' in line]
    return len(lines)==1 and lines[0].endswith(' original preserved at '+str(path))
h=moving('race-hooks');original=(h/'hooks.json').read_bytes();r=run(h,'hooks',apply=True,env=dict(fixture,FIXTURE_RACE='2|hooks.json|\n'))
saved=[p for p in h.glob('hooks.json.bak-*') if p.read_bytes()==original]
check('hooks.json changed after it landed: concurrent bytes preserved and exact original backup named on the recovery line',r.returncode!=0 and (h/'config.toml').read_text()==frozen_text and (h/'hooks.json').read_bytes().endswith(b'\n\n') and 'changed concurrently' in r.stdout and len(saved)==1 and recovery_names(r.stdout,saved[0]))
wrong=r.stdout.replace('preserved at '+str(saved[0]),'preserved at '+str(h/'hooks.json'))
check('a recovery line naming another path is caught although the BACKUP line still names the backup',wrong!=r.stdout and 'RECOVERY INCOMPLETE' in wrong and str(saved[0]) in wrong and not recovery_names(wrong,saved[0]))
# The owner's Ctrl-C is not an Exception. While the new metadata is read it must still put the
# original positions back, leave the stored trust alone, re-raise, and stay safe to retry.
real_list=m.list_hooks;native=lambda target:listing(json.loads((target/'hooks.json').read_text())['hooks'])
def cancelled(inst):
    out=io.StringIO()
    try:
        with contextlib.redirect_stdout(out):m.install_hooks(inst)
    except KeyboardInterrupt:return True,out.getvalue()
    finally:m.list_hooks=real_list
    return False,out.getvalue()
# Interrupt inside the real atomic rename, before Installer.replace returns. The
# recorded bytes prove this is a landed write, rather than a cancellation before it.
def cancel_at_rename(name,concurrent=False,without_receipt=False):
    h=moving(name);original=(h/'hooks.json').read_bytes();config_before=m.snapshot(h/'config.toml')
    inst=m.Installer(h,True);replace=inst.replace;rename=m.os.replace;landed=[]
    if without_receipt:
        def lost_receipt(path,*args,**kwargs):
            if path==h/'hooks.json':kwargs.pop('receipt',None)
            return replace(path,*args,**kwargs)
        inst.replace=lost_receipt
    def renamed_then_cancelled(src,dst):
        rename(src,dst)
        if pathlib.Path(dst)==h/'hooks.json' and not landed:
            landed.append((h/'hooks.json').read_bytes())
            if concurrent:(h/'hooks.json').write_bytes(landed[0]+b'\n\n')
            raise KeyboardInterrupt
    m.os.replace=renamed_then_cancelled;m.list_hooks=native
    try:interrupted,printed=cancelled(inst)
    finally:m.os.replace=rename
    return h,original,config_before,landed,interrupted,printed
h,original,config_before,landed,interrupted,printed=cancel_at_rename('cancel-rename')
check('Ctrl-C immediately after actual hooks rename restores exact original bytes and leaves config inode/bytes unchanged',interrupted and len(landed)==1 and landed[0]!=original and (h/'hooks.json').read_bytes()==original and m.snapshot(h/'config.toml')==config_before and not list(h.glob('config.toml.bak-*')) and 'RECOVERED' in printed and 'RECOVERY INCOMPLETE' not in printed)
r=run(h,'hooks',apply=True,env=fixture);now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
check('retry after cancellation inside rename preserves trusted, disabled and modified foreign states',r.returncode==0 and all(got[now[x['command']]['key']]==stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[N['command']]['key']]=={})
h,original,config_before,landed,interrupted,printed=cancel_at_rename('cancel-rename-owner',concurrent=True)
saved=[p for p in h.glob('hooks.json.bak-*') if p.read_bytes()==original]
check('owner edit followed by Ctrl-C inside rename is preserved with exact original backup named',interrupted and len(landed)==1 and landed[0]!=original and (h/'hooks.json').read_bytes()==landed[0]+b'\n\n' and m.snapshot(h/'config.toml')==config_before and len(saved)==1 and recovery_names(printed,saved[0]))
h,original,config_before,landed,interrupted,printed=cancel_at_rename('cancel-rename-mutant',without_receipt=True)
check('negative boundary proof: losing pre-rename receipt fails exact-restoration behavior despite a real landed rename',interrupted and len(landed)==1 and landed[0]!=original and (h/'hooks.json').read_bytes()!=original and m.snapshot(h/'config.toml')==config_before and 'RECOVERY INCOMPLETE' in printed and 'backup receipt unavailable' in printed and 'preserved at None' not in printed)
# A concurrent edit can happen after the original backup was copied but before
# the replacement's last comparison. Recovery must still name that exact copy.
h=moving('owner-after-backup');original=(h/'hooks.json').read_bytes();owner_bytes=original+b'\n\n';config_before=m.snapshot(h/'config.toml');copy_backup=m.backup;out=io.StringIO();refused=False
def backup_then_owner_edit(path):
    saved=copy_backup(path)
    if path==h/'hooks.json':path.write_bytes(owner_bytes)
    return saved
m.backup=backup_then_owner_edit;m.list_hooks=native
try:
    with contextlib.redirect_stdout(out):
        try:m.install_hooks(m.Installer(h,True))
        except m.Refusal:refused=True
finally:m.backup=copy_backup;m.list_hooks=real_list
saved=[p for p in h.glob('hooks.json.bak-*') if p.read_bytes()==original]
check('owner edit after backup is preserved with unchanged config and exact original backup on recovery line',refused and (h/'hooks.json').read_bytes()==owner_bytes and m.snapshot(h/'config.toml')==config_before and len(saved)==1 and recovery_names(out.getvalue(),saved[0]))
h=moving('cancel-before-rename');hook_before=m.snapshot(h/'hooks.json');config_before=m.snapshot(h/'config.toml');rename=m.os.replace
def cancelled_before_rename(src,dst):
    if pathlib.Path(dst)==h/'hooks.json':raise KeyboardInterrupt
    return rename(src,dst)
m.os.replace=cancelled_before_rename;m.list_hooks=native
try:interrupted,printed=cancelled(m.Installer(h,True))
finally:m.os.replace=rename
check('Ctrl-C before atomic rename reports original unchanged without restoring over it',interrupted and m.snapshot(h/'hooks.json')==hook_before and m.snapshot(h/'config.toml')==config_before and 'UNCHANGED' in printed and 'RECOVER' not in printed)
h=moving('cancel-after');original=(h/'hooks.json').read_bytes();reads=[]
def second_read_cancelled(target):
    reads.append(target)
    if len(reads)==2:raise KeyboardInterrupt
    return native(target)
m.list_hooks=second_read_cancelled;interrupted,printed=cancelled(m.Installer(h,True))
check('Ctrl-C during the second metadata read is re-raised after restoring the exact original hook bytes, config unchanged',interrupted and len(reads)==2 and (h/'hooks.json').read_bytes()==original and (h/'config.toml').read_text()==frozen_text and not list(h.glob('config.toml.bak-*')) and 'RECOVERED' in printed and 'RECOVERY INCOMPLETE' not in printed)
r=run(h,'hooks',apply=True,env=fixture);now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
check('retry after cancellation carries the original states',r.returncode==0 and all(got[now[x['command']]['key']]==stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[N['command']]['key']]=={})
# commit has been prepared, but config still holds the old trust. Nonempty old
# states cannot stand in for evidence that the new trust reached disk.
h=moving('cancel-before-store');original=(h/'hooks.json').read_bytes();config_before=m.snapshot(h/'config.toml');inst=m.Installer(h,True)
def cancelled_before_store(*args,**kwargs):raise KeyboardInterrupt
inst.config=cancelled_before_store;m.list_hooks=native;interrupted,printed=cancelled(inst)
check('Ctrl-C before prepared trust is stored restores exact hooks/config and does not claim committed trust',interrupted and (h/'hooks.json').read_bytes()==original and m.snapshot(h/'config.toml')==config_before and not list(h.glob('config.toml.bak-*')) and 'RECOVERED' in printed and 'KEPT' not in printed)
r=run(h,'hooks',apply=True,env=fixture);now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
check('retry after cancellation before trust storage preserves every foreign state',r.returncode==0 and all(got[now[x['command']]['key']]==stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[N['command']]['key']]=={})
# A cancellation that arrives once the trust is stored finds the installation complete:
# putting the old positions back under the new trust would be the mismatch itself.
h=moving('cancel-committed');original=(h/'hooks.json').read_bytes();inst=m.Installer(h,True);store=inst.config
def stored_then_cancelled(*args,**kwargs):
    store(*args,**kwargs);raise KeyboardInterrupt
inst.config=stored_then_cancelled;m.list_hooks=native;interrupted,printed=cancelled(inst)
now={x['command']:x for x in listing(json.loads((h/'hooks.json').read_text())['hooks'])};got=tomllib.loads((h/'config.toml').read_text())['hooks']['state']
check('Ctrl-C after the trust is stored keeps the merged hooks that match it',interrupted and (h/'hooks.json').read_bytes()!=original and 'KEPT' in printed and 'RECOVER' not in printed and all(got[now[x['command']]['key']]==stored[was[x['command']]['key']] for x in (T,D,M)) and got[now[N['command']]['key']]=={} and all(got[now[c]['key']]=={'trusted_hash':now[c]['currentHash'],'enabled':True} for c in package_commands))
before=tree(h);r=run(h,'hooks',apply=True,env=fixture)
check('apply after a cancelled but stored commit changes nothing',r.returncode==0 and before==tree(h))
# macOS links /var to /private/var, so a home under /var/folders has a symlinked ancestor. This
# suite's own TMP is canonical (pwd -P at the top), which hides that: alias it on purpose.
(tmp/'canonical-root').mkdir();alias=tmp/'alias-root';alias.symlink_to(tmp/'canonical-root')
def aliased(name):
    p=alias/name/'.codex';p.mkdir(parents=True);return p
h=aliased('preview');before=tree(h);r=run(h,'config','agents','skills','hooks')
check('home below a symlinked ancestor previews every target without writes',r.returncode==0 and before==tree(h) and 'not a real directory' not in r.stdout)
r=run(h,'config','agents','skills',apply=True)
check('home below a symlinked ancestor applies',r.returncode==0 and (h/'config.toml').is_file() and any((h/'agents').iterdir()) and any((h/'skills').iterdir()))
h=aliased('hooks');r=run(h,'hooks',apply=True,env={'PATH':str(bindir)})
check('hooks install and gain trust in a home below a symlinked ancestor',r.returncode==0 and tomllib.loads((h/'config.toml').read_text())['features']['hooks'] is True and (h/'hooks.json').is_file())
h=aliased('wrapper');r=subprocess.run(['/bin/bash',str(copied/'install.sh'),'--codex-config'],env=dict(os.environ,HOME=str(h.parent)),capture_output=True,text=True)
check('installer wrapper previews a home below a symlinked ancestor',r.returncode==0 and 'not a real directory' not in r.stdout)
# The boundary is the home, inclusive: the home itself and all it holds stay refused.
outside=tmp/'link-target';outside.mkdir();linked=alias/'linked-home'/'.codex';linked.parent.mkdir();linked.symlink_to(outside)
for mode,apply in [('preview',False),('apply',True)]:
 r=run(linked,'config','agents',apply=apply)
 check('symlinked home refused on '+mode+' below a symlinked ancestor',r.returncode!=0 and 'not a real directory' in r.stdout and not list(outside.iterdir()))
h=aliased('inner-link');(h/'skills').symlink_to(outside);(h/'hooks').symlink_to(outside);(h/'agents').symlink_to(outside)
for target in ('skills','agents','hooks'):
 r=run(h,target,apply=True,env={'PATH':str(bindir)})
 check('symlinked '+target+' directory refused inside a home below a symlinked ancestor',r.returncode!=0 and 'not a real directory' in r.stdout and not list(outside.iterdir()))
h=home('broken');agent.unlink()
# Removing a listed artifact is covered by role/roster inventory; malformed surviving copies fail.
remaining=next((copied/'codex/agents').glob('*.toml'));remaining.write_text('broken = [\n');r=run(h,'agents',apply=True)
check('broken copied role artifact caught before target mutation',r.returncode!=0 and not list(h.iterdir()))
# Wrapper dry-run must not invoke inventory provider CLIs, and --all must not select native targets.
h=home('wrapper');poison=bindir/'claude';poison.write_text('#!/bin/sh\ntouch "$HOME/provider-ran"\n');poison.chmod(0o755)
r=subprocess.run(['/bin/bash',str(copied/'install.sh'),'--codex-config'],env=dict(os.environ,HOME=str(h.parent),PATH=str(bindir)+':'+os.environ['PATH']),capture_output=True,text=True)
check('explicit native wrapper skips mutating provider inventory',r.returncode==0 and not (h.parent/'provider-ran').exists())
r=subprocess.run(['/bin/bash',str(copied/'install.sh'),'--apply','--all','--codex-config'],env=dict(os.environ,HOME=str(h.parent)),capture_output=True,text=True)
check('mixed all/native target rejected before mutation',r.returncode==2 and not list(h.iterdir()))
print('== '+str(passed)+' native installer checks passed')
PY
