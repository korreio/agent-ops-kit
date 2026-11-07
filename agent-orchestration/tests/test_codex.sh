#!/usr/bin/env bash
# Hermetic native hook tests: real commands and shared guards, synthetic input/files only.
set -eu
PKG="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 -I -B - "$PKG" <<'PY'
import datetime,json,os,pathlib,re,runpy,shlex,shutil,subprocess,sys,tempfile,tomllib
pkg=pathlib.Path(sys.argv[1]).resolve()
# Budget checks cover every native instruction/config surface beyond role TOMLs.
budgets={
    'codex/skills/cross-review/SKILL.md':'claude/skills/cross-review/SKILL.md',
    'codex/README.md':'claude/skills/cross-review/SKILL.md',
    'codex/config-fragment.toml':'claude/settings-fragment.json',
    'codex/hooks.json':'claude/settings-fragment.json',
    'codex/hooks/shared-guard.sh':'claude/hooks/brew-guards.sh',
    'codex/hooks/worker-git.sh':'claude/hooks/git-staging-guard.sh',
    'codex/hooks/bash-syntax.sh':'claude/hooks/bash-syntax.sh',
    'codex/hooks/roster-freshness.sh':'claude/hooks/roster-freshness.sh',
}
for native,counterpart in budgets.items():
    actual=(pkg/native).read_bytes(); limit=(pkg/counterpart).read_bytes()
    assert len(actual)<=len(limit) and len(actual.splitlines())<=len(limit.splitlines()),native+': counterpart byte/line budget'
# Simulate an older interpreter's missing standard-library module without installing Python.
block_import="""import builtins,runpy,sys
original=builtins.__import__
def missing(name,*args,**kwargs):
    if name=='tomllib': raise ImportError('synthetic missing tomllib')
    return original(name,*args,**kwargs)
builtins.__import__=missing
runpy.run_path(sys.argv[1],run_name='__main__')
"""
missing=subprocess.run([sys.executable,'-I','-B','-c',block_import,str(pkg/'codex/lane_config.py')],text=True,capture_output=True)
assert missing.returncode==2 and not missing.stdout
assert missing.stderr.strip()=='Codex lane configuration: Python 3.11+ (tomllib) required',missing.stderr
assert 'Traceback' not in missing.stderr
# The legacy cwd argument stays accepted without emitting project or hook trust.
with tempfile.TemporaryDirectory(prefix='codex-lane-paths-') as scratch:
    for name in ('space in path','unicode-café','unicode-🧪','control-\x7f'):
        workspace=pathlib.Path(scratch)/name; workspace.mkdir()
        for role,lane in (('reviewer','review'),('writer-bounded','writer')):
            result=subprocess.run([sys.executable,'-I','-B',str(pkg/'codex/lane_config.py'),
                                   role,lane,'','',str(workspace)],text=True,capture_output=True)
            assert result.returncode==0,(name,role,result.stderr)
            settings={}
            for setting in result.stdout.splitlines():
                settings.update(tomllib.loads(setting))
            assert set(settings)=={'permissions','default_permissions','approval_policy','model',
                                   'model_reasoning_effort','developer_instructions'},(name,role,settings)
            without_cwd=subprocess.run([sys.executable,'-I','-B',str(pkg/'codex/lane_config.py'),
                                        role,lane],text=True,capture_output=True)
            assert without_cwd.returncode==0 and result.stdout==without_cwd.stdout,(name,role,without_cwd.stderr)
            assert settings['approval_policy']=='never'
            assert settings['default_permissions']=='lane-orchestration-'+('write' if lane=='writer' else 'review')
print('native lane trust: no project or hook configuration emitted, with or without legacy cwd')
serialize=runpy.run_path(str(pkg/'codex/lane_config.py'))['toml']
controls=''.join(chr(code) for code in range(32))+'\x7f'
for value in ({'\x7f':'DEL key'}, {'value':'\x7f'}, {controls:controls},
              {'quote"key':'quote" and backslash\\'}, {'🧪':{'café':['🧭',True,False,1]}}):
    assert tomllib.loads('fixture='+serialize(value))['fixture']==value
print('native lane strings: key/value control, quote, backslash and Unicode round trips passed')
# The lanes' literal denials, and network resolved as Codex resolves `extends`: parents first, child
# keys override (codex-rs/config/src/permissions_toml.rs). Fixture proof of the emitted tables only.
fragment_text=(pkg/'codex/config-fragment.toml').read_text()
fragment=tomllib.loads(fragment_text)
assert 'secret boundary' not in fragment_text and 'secret fence' not in fragment_text
assert 'a minimal literal denial list' in fragment_text.lower()
assert 'wildcard cases use the shell guard' not in fragment_text
literal=['~/.ssh','~/.aws','~/.codex/auth.json','~/.netrc','~/.npmrc','~/.pgpass','~/.config/gh/hosts.yml',
         '~/.local/share/fish/fish_history','~/.zsh_history','~/.bash_history','~/.git-credentials',
         '~/.docker/config.json','~/.kube','~/.gnupg','~/.config/gcloud','~/.pypirc','/**/.env','/**/key.properties',
         '/**/.ssh','/**/.env.local','/**/.env.development','/**/.env.production','/**/.env.staging',
         '/**/fish_history','/**/credentials.json','/**/secrets.json','/**/id_rsa','/**/id_ed25519','/**/id_ecdsa',
         '/**/.git-credentials']
filesystem=fragment['permissions']['orchestration-base']['filesystem']
assert all(filesystem.get(path)=='deny' for path in literal)
assert '~/.claude.json' not in filesystem,'nested Claude in the writer needs it'
assert not any(set('*?[').intersection(path.removeprefix('/**/')) for path in filesystem),'a wildcard basename denies folder unlink/rename on macOS'
# Parity with the Claude list, rule by rule: each one has a literal here, or it is a named difference
# that the fragment's own comment states. A new Claude rule fails here until it takes one or the other.
named_differences={'**/.env.*':'.env.*','**/*.jks':'*.jks','**/*.keystore':'*.keystore','**/*.p8':'*.p8','**/.*_history':'.*_history',
                   '~/.*_history':'.*_history','**/credentials*.json':'credentials*.json','**/secrets*.json':'secrets*.json',
                   '**/*.pem':'*.pem','**/*.key':'*.key','**/*.p12':'*.p12','**/*.pfx':'*.pfx','**/password':'@inquirer/password'}
claude_deny=json.loads((pkg/'claude/settings-fragment.json').read_text())['permissions']['deny']
for rule in (r[5:-1] for r in claude_deny if r.startswith('Read(') and r[5]!='!'):
    if rule in named_differences:
        assert named_differences[rule] in fragment_text,(rule,'a named difference the comment must state')
    else:
        native=rule.removesuffix('/**')
        assert filesystem.get('/'+native if native.startswith('**/') else native)=='deny',(rule,'no literal for this Claude rule')
assert 'secrets guard' in fragment_text and 'does not stop python' in fragment_text
assert '/**/password' not in filesystem and '/**/.env.test' not in filesystem,'no file-only rule, and test runs need .env.test'
left_out=next(line for line in fragment_text.splitlines() if line.startswith('# Left out:'))
assert 'password' in left_out and '.env.test' in left_out,left_out
assert not any(name.endswith(('.example','.sample','.template','.dist')) for name in filesystem),'templates stay readable, as under Claude'
def overlaid(parent,child):
    merged=dict(parent)
    for key,value in child.items():
        merged[key]=overlaid(merged[key],value) if isinstance(value,dict) and isinstance(merged.get(key),dict) else value
    return merged
def resolved(catalog,name):
    profile=dict(catalog[name]); parent=profile.pop('extends','')
    return overlaid(resolved(catalog,parent),profile) if parent in catalog else profile
catalog=fragment['permissions']
assert resolved(catalog,'orchestration-review')['network']['enabled'] is False
assert resolved(catalog,'orchestration-write')['network']['enabled'] is True,'the writer keeps command network access'
assert 'network' not in catalog['orchestration-write'],'the writer table takes network from the base'
assert catalog['development']['network']['enabled'] is True
for role,lane,profile,enabled in (('reviewer','review','lane-orchestration-review',False),('writer-bounded','writer','lane-orchestration-write',True)):
    emitted={}
    for setting in subprocess.run([sys.executable,'-I','-B',str(pkg/'codex/lane_config.py'),role,lane],text=True,capture_output=True,check=True).stdout.splitlines():
        emitted.update(tomllib.loads(setting))
    assert resolved(emitted['permissions'],profile)['network']['enabled'] is enabled,(role,emitted['permissions'])
    assert all(resolved(emitted['permissions'],profile)['filesystem'].get(path)=='deny' for path in literal),role
print('native lane boundary: literal denials reach both lanes; only the reviewer has command network off')
with tempfile.TemporaryDirectory(prefix='codex-hooks-') as scratch:
    root=pathlib.Path(scratch); fixture=root/'package'; home=root/'home'
    for folder in ('codex/hooks','claude/hooks'):
        shutil.copytree(pkg/folder,fixture/folder)
    roster=fixture/'roster.md'
    roster.write_text(re.sub(r'Last checked: [0-9-]+','Last checked: 2026-10-10',(pkg/'roster.md').read_text()))
    (home/'.codex/hooks').mkdir(parents=True)
    for script in (fixture/'codex/hooks').glob('*.sh'): (home/'.codex/hooks'/script.name).symlink_to(script)
    env=dict(os.environ,HOME=str(home),ROSTER_FRESHNESS_TODAY='2026-10-11')
    env.pop('CODEX_ORCHESTRATION_WORKER',None); env.pop('CLAUDE_ORCHESTRATION_WORKER',None)
    config=json.loads((pkg/'codex/hooks.json').read_text())['hooks']
    assert 'Stop' not in config and 'SubagentStop' not in config
    commands={event:[h['command'] for entry in entries for h in entry['hooks']] for event,entries in config.items()}
    assert any('worker-git' in c for c in commands['PreToolUse'])
    assert any('apply_patch' in entry['matcher'] for entry in config['PostToolUse'])
    assert commands['PreToolUse'][-1].endswith('shared-guard.sh" outward-ask'),commands['PreToolUse']
    def invoke(command,data,expected,extra=None,cwd=None):
        result=subprocess.run(['/bin/bash','-c',command],input=json.dumps(data),text=True,capture_output=True,env=dict(env,**(extra or {})),cwd=cwd or root)
        assert result.returncode==expected,(command,data,result.returncode,result.stdout,result.stderr)
        return result
    def pre(command,expected,**identity):
        results=[invoke(c,dict(tool_name='Bash',cwd=str(root),tool_input={'command':command},**identity),e) for c,e in zip(commands['PreToolUse'],expected)]
        return results
    pre('echo safe',[0,0,0,0])
    pre('brew install example',[2,0,0,0])
    pre('HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 brew install example',[0,0,0,0])
    pre('brew autoremove',[2,0,0,0])
    pre('cat .env',[0,2,0,0])
    pre("sed -n '1,5p' .env.local",[0,2,0,0])
    pre("awk '{print}' server.key",[0,2,0,0])
    pre("awk '1<2' server.key",[0,2,0,0])
    pre('cat .env.example',[0,0,0,0])
    pre('git add .',[0,0,2,0])
    pre('git add one.txt',[0,0,0,0])
    pre('git add one.txt',[0,0,0,2],agent_id='child',agent_type='writer-bounded')
    pre('env X=1 git -C repo commit -m update',[0,0,0,2],agent_id='child')
    pre('sudo -u owner git push',[0,0,0,2],agent_id='child')
    pre('env -C repo git commit -m update',[0,0,0,2],agent_id='child')
    pre('arch -arm64 git push',[0,0,0,2],agent_id='child')
    pre('sudo -u owner cat .env',[0,2,0,0])
    pre('git add --al',[0,0,2,0])
    pre("echo $((1<<2))\ncat .env",[0,2,0,0])
    pre("echo $'it\\'s'; cat .env",[0,2,0,0])
    pre('git diff',[0,0,0,2],agent_id='child')
    pre('git status --short',[0,0,0,0],agent_id='child')
    pre("echo 'git commit'",[0,0,0,0],agent_id='child')
    # outward-ask: the Claude rules and allow file, but a block. Codex continues the call on an ask.
    outward=commands['PreToolUse'][-1]; allow=fixture/'claude/hooks/outward-ask.allow'
    repo=root/'repo'; subprocess.run(['git','init','-q',str(repo)],check=True,env=dict(env,GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1'))
    allow.write_text(str(repo.resolve())+' ci.yml\n')
    for text,where,expected in (('gh workflow run ci.yml',repo,0),('gh workflow run --ref main ci.yml',repo,0),('gh workflow list',root,0),
                                ('gh workflow run other.yml',repo,2),('gh workflow run ci.yml',root,2),('gh workflow run ci.yml -R o/r',repo,2),
                                ('gh -R o/r workflow run ci.yml',repo,2),('gh workflow run',repo,2),('sudo -u owner gh workflow run other.yml',repo,2)):
        result=invoke(outward,{'tool_name':'Bash','cwd':str(where),'tool_input':{'command':text}},expected)
        assert not result.stdout,(text,'a decision on stdout: Codex fails the hook run on ask and continues',result.stdout)
        assert bool(result.stderr)==bool(expected),(text,result.stderr)
        assert not expected or str(allow.resolve()) in result.stderr,(text,'the reason names the allow file',result.stderr)
    invoke(commands['PreToolUse'][0].replace('brew-guards','not-a-guard'),{'tool_input':{'command':'echo safe'}},2)
    worker=next(c for c in commands['PreToolUse'] if 'worker-git' in c)
    invoke(worker,{'tool_input':{'command':'git push'}},2,{'CODEX_ORCHESTRATION_WORKER':'1'})
    # The Codex hook is the shared Claude guard: same exit and same line, whichever family runs it.
    shared_worker='/bin/bash '+shlex.quote(str(fixture/'claude/hooks/worker-git.sh'))
    def worker_case(text,expected,extra=None,**identity):
        data=dict(tool_name='Bash',cwd=str(root),tool_input={'command':text},**identity)
        ours=invoke(worker,data,expected,extra); theirs=invoke(shared_worker,data,expected,extra)
        assert (ours.stdout,ours.stderr)==(theirs.stdout,theirs.stderr),(text,ours.stderr,theirs.stderr)
    for marker in ({'CODEX_ORCHESTRATION_WORKER':'1'},{'CLAUDE_ORCHESTRATION_WORKER':'1'}):
        for text in ('git add one.txt','git commit -m update','git push','git diff','git show HEAD'):
            worker_case(text,2,marker); worker_case(text,0)
        for text in ('git status --short','git log -5','git blame one.txt','git show HEAD:one.txt'):
            worker_case(text,0,marker)
    for text,expected in (('git push',2),('git show HEAD:one.txt',0),('git status',0)):
        worker_case(text,expected,agent_id='child',agent_type='writer-bounded')
    worker_case('git push',0,agent_type='main-agent')
    good=root/'good.sh'; good.write_text('#!/bin/bash\necho good\n')
    bad=root/'bad.sh'; bad.write_text('#!/bin/bash\nif then\n')
    other=root/'other.sh'; other.write_text('#!/usr/bin/env python3\nif then\n')
    syntax=commands['PostToolUse'][0]
    for path,expected in ((good,0),(bad,2),(other,0)):
        invoke(syntax,{'cwd':str(root),'tool_input':{'command':'*** Begin Patch\n*** Update File: '+path.name+'\n*** End Patch'}},expected)
    invoke(syntax,{'cwd':str(root),'tool_input':{'command':'*** Update File: good.sh\n*** Move to: bad.sh'}},2)
    invoke(syntax,{'tool_input':{'file_path':str(bad)}},2)
    freshness=commands['SessionStart'][0]
    clean=invoke(freshness,{},0); assert not clean.stdout
    unknown=invoke(freshness,{'model':'unknown-synthetic-model'},0); assert 'runtime model' in unknown.stdout
    unsafe=invoke(freshness,{'model':'untrusted prose with spaces'},0); assert not unsafe.stdout
    roster=fixture/'roster.md'; roster.write_text(roster.read_text().replace('Last checked: 2026-10-10','Last checked: 2026-09-01'))
    stale=invoke(freshness,{},0); assert 'Roster check:' in stale.stdout and 'last checked' in stale.stdout
    # The same line as the Claude hook on one fixture: date, catalog and alias drift.
    shared_freshness='/bin/bash '+shlex.quote(str(fixture/'claude/hooks/roster-freshness.sh'))
    def same_line(fragment,today='2026-09-02'):   # a fresh date by default: the path shares a 400-character line
        fresh={'ROSTER_FRESHNESS_TODAY':today}
        ours=invoke(freshness,{},0,fresh).stdout; theirs=invoke(shared_freshness,{},0,fresh).stdout
        assert ours==theirs and fragment in ours,(fragment,ours,theirs)
    same_line('last checked 2026-09-01',env['ROSTER_FRESHNESS_TODAY'])
    names=sorted({c.split('|')[2].strip().strip('`') for c in roster.read_text().split('## Codex')[1].split('\n## ')[0].splitlines()
                  if c.startswith('| ') and c.split('|')[1].strip()!='Role'})
    entries=[{'slug':name,'visibility':'list','upgrade':None} for name in names]
    catalog=home/'.codex/models_cache.json'
    catalog.write_text(json.dumps({'models':entries[1:]})); same_line('is not in the installed catalog')
    catalog.write_text(json.dumps({'models':[dict(entries[0],visibility='hide')]+entries[1:]})); same_line('is no longer listed')
    catalog.write_text(json.dumps({'models':[dict(entries[0],upgrade={'model':'synthetic-next'})]+entries[1:]})); same_line('is being replaced by synthetic-next')
    catalog.write_text(json.dumps({'models':entries}))
    lanes=home/'.claude/projects/p/s/subagents'; lanes.mkdir(parents=True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    (lanes/'agent-a.jsonl').write_text(json.dumps({'type':'assistant','timestamp':stamp,'message':{'model':'claude-opus-0-0','role':'assistant'}})+'\n')
    same_line('alias opus ran as claude-opus-0-0')
    catalog.unlink(); shutil.rmtree(home/'.claude')
    fresh={'ROSTER_FRESHNESS_TODAY':'2026-09-02'}
    assert 'runtime model synthetic-unknown is not in the Codex roster' in invoke(freshness,{'model':'synthetic-unknown'},0,fresh).stdout
    assert not invoke(shared_freshness,{'model':'synthetic-unknown'},0,fresh).stdout,'a Claude session has no Codex model'
    assert not invoke(freshness,{'model':names[0]},0,fresh).stdout
    assert not invoke(freshness,'not an object',0,fresh).stdout
    assert 'tell the owner; change nothing without their approval.' in stale.stdout and ' his ' not in stale.stdout
    assert 'To clear it, recheck and update Last checked in the roster, or omit the hook.' in stale.stdout,stale.stdout
    # Fail closed: every safety guard, worker or not, with no parser or input none can read; advisory
    # hooks stay out of the way. With jq alone Codex behaves as Claude does, so Python is not required.
    no_parser=root/'no-parser'; no_parser.mkdir(); (no_parser/'readlink').symlink_to(shutil.which('readlink'))
    jq_only=root/'jq-only'; jq_only.mkdir()
    for tool in ('jq','readlink','git'): (jq_only/tool).symlink_to(shutil.which(tool))
    for command in commands['PreToolUse']:
        for data in ({'tool_name':'Bash','cwd':str(root),'tool_input':{'command':'echo safe'}},
                     {'tool_name':'Bash','cwd':str(root),'agent_id':'child','tool_input':{'command':'echo safe'}}):
            refused=invoke(command,data,2,{'PATH':str(no_parser)})
            assert not refused.stdout and 'blocked' in refused.stderr and 'Install jq or python3' in refused.stderr,(command,refused.stderr)
            assert len(refused.stderr.strip().splitlines())==1,(command,refused.stderr)
            invoke(command,dict(data,tool_input={'command':'ls'}),0,{'PATH':str(jq_only)}) if 'agent_id' in data or 'worker-git' not in command else None
        invoke(command,'not an object',2)
    # bash-syntax stays advisory without python3, and says so where Codex shows it: no silent skip.
    for folder in (no_parser,jq_only):
        unchecked=invoke(syntax,{'cwd':str(root),'tool_input':{'command':'*** Update File: bad.sh'}},0,{'PATH':str(folder)})
        assert set(json.loads(unchecked.stdout))=={'systemMessage'} and 'not checked: python3 is unavailable' in unchecked.stdout,unchecked.stdout
    assert not invoke(freshness,{},0,{'PATH':str(no_parser)}).stdout
    bash_input=lambda text,**identity: dict(tool_name='Bash',cwd=str(root),tool_input={'command':text},**identity)
    for index,text,identity in ((0,'brew install example',{}),(1,'cat .env',{}),(2,'git add .',{}),(3,'git push',{'agent_id':'child'}),(4,'gh workflow run other.yml',{})):
        invoke(commands['PreToolUse'][index],bash_input(text,**identity),2,{'PATH':str(jq_only)})
    # A hook link in a chain and through a linked folder still finds the guards, and a lost guard blocks.
    linked=home/'.codex/linked-hooks'; linked.symlink_to(fixture/'codex/hooks')
    invoke('/bin/bash "$HOME/.codex/linked-hooks/shared-guard.sh" secrets-guard',bash_input('cat .env'),2)
    (home/'.codex/hop').symlink_to(fixture/'codex/hooks/shared-guard.sh')
    linked_guard=home/'.codex/hooks/shared-guard.sh'; linked_guard.rename(root/'parked.link')
    lost=invoke(commands['PreToolUse'][3],bash_input('git status'),2); assert 'worker-git: blocked' in lost.stderr,lost.stderr
    assert not invoke(freshness,{},0).stdout,'advisory: no wrapper, no line, no failure'
    (root/'parked.link').rename(linked_guard)
    invoke('/bin/bash "$HOME/.codex/hop" secrets-guard',bash_input('cat .env'),2)
    moved=fixture/'claude/hooks/secrets-guard.sh'; moved.rename(root/'parked.sh')
    lost=invoke(commands['PreToolUse'][1],bash_input('echo safe'),2); assert 'shared-guard: blocked' in lost.stderr
    (root/'parked.sh').rename(moved)
    tokenizer=fixture/'claude/hooks/lib/shell-tokens.bash'; tokenizer.rename(root/'parked.bash')
    for index,text in ((0,'brew install example'),(1,'cat .env'),(2,'git add .'),(4,'gh workflow run other.yml')):
        lost=invoke(commands['PreToolUse'][index],bash_input(text),2); assert 'shell-tokens.bash is missing' in lost.stderr,lost.stderr
    lost=invoke(commands['PreToolUse'][3],bash_input('git status',agent_id='child'),2); assert 'worker-git: blocked' in lost.stderr
    (root/'parked.bash').rename(tokenizer)
    # A session directory's modules must not load: every hook, with python3 the only parser it finds.
    poison=root/'poison'; poison.mkdir(); mark=root/'poisoned'
    for module in ('glob','json','datetime','pathlib'):
        (poison/(module+'.py')).write_text('import os\nopen(os.environ["POISON_MARK"],"a").close()\nraise SystemExit(7)\n')
    bare=root/'bare-bin'; bare.mkdir()
    for tool in ('python3','readlink'): (bare/tool).symlink_to(shutil.which(tool))
    def poisoned(command,data,expected):
        result=invoke(command,data,expected,{'PATH':str(bare),'POISON_MARK':str(mark)},poison)
        assert not mark.exists(),(command,'a working-directory module ran')
        return result
    guard=commands['PreToolUse']
    shell=lambda text,**identity: dict(tool_name='Bash',cwd=str(poison),tool_input={'command':text},**identity)
    for command,text,expected in ((guard[0],'brew install example',2),(guard[1],'cat .env',2),(guard[2],'git add .',2),(guard[1],'echo safe',0)):
        poisoned(command,shell(text),expected)
    poisoned(guard[4],shell('gh workflow run ci.yml'),2)
    poisoned(guard[3],shell('git push',agent_id='child'),2)
    poisoned(guard[3],shell('git status --short',agent_id='child'),0)
    poisoned(syntax,{'cwd':str(root),'tool_input':{'file_path':str(bad)}},2)
    poisoned(syntax,{'cwd':str(root),'tool_input':{'command':'*** Update File: '+good.name}},0)
    assert 'last checked' in poisoned(freshness,{},0).stdout
    for script in (pkg/'codex/hooks').glob('*.sh'):
        for line in script.read_text().splitlines():
            for call in re.findall(r'(?<![-\w/.])python3 +-.*',line):
                assert call.startswith('python3 -I -B '),(script.name,line)
print('native hooks: shared guards, worker identity, patch syntax, freshness and isolated python passed')
PY
