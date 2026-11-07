#!/usr/bin/env python3
"""Explicit native Codex installation. Prints the package fragment's own values, never existing configuration values."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import time
import uuid
try:
    import tomllib
except ImportError:
    raise SystemExit('FAIL native Codex targets require Python 3.11+ (tomllib)')

PACKAGE = Path(__file__).resolve().parent
UNSET = object()

class Refusal(Exception):
    pass

def snapshot(path):
    try:
        st = path.lstat()
    except FileNotFoundError:
        return None
    if path.is_symlink():
        return ('link', st.st_ino, st.st_mtime_ns, os.readlink(path))
    if not path.is_file():
        raise Refusal(f'{path}: expected a regular file or symlink')
    return ('file', st.st_ino, st.st_mtime_ns, path.read_bytes())

def real_dirs(path, home):
    # Stops at the target home, inclusive: what leads to it belongs to the machine, and macOS
    # itself links /var to /private/var. Only what this installer writes through must be real.
    for p in [path, *path.parents]:
        if p.is_symlink() or (p.exists() and not p.is_dir()):
            raise Refusal(f'{p}: not a real directory')
        if p == home:
            return

def backup(path):
    if path.exists() or path.is_symlink():
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        dst = path.with_name(path.name + '.bak-' + stamp + '-' + uuid.uuid4().hex[:12])
        if path.is_symlink():
            dst.symlink_to(os.readlink(path))
        else:
            shutil.copy2(path, dst, follow_symlinks=False)
        print(f'  BACKUP {path} -> {dst}')
        return dst

def check_link(path, source):
    old = snapshot(path)
    if old and path.is_symlink() and os.readlink(path) == str(source) and path.exists():
        return old
    if old and path.exists():
        if not path.is_file() or path.read_bytes() != source.read_bytes():
            raise Refusal(f'{path}: differs from package artifact; left alone, reconcile before applying')
    return old

def role_copy(path, source):
    body=source.read_bytes()
    data=b'# agent-ops-kit managed role sha256: '+hashlib.sha256(body).hexdigest().encode()+b'\n'+body
    old=snapshot(path)
    if old:
        owned=old[0]=='link' and old[3]==str(source)
        if old[0]=='file':
            header,separator,remaining=old[3].partition(b'\n')
            marker=re.fullmatch(rb'# agent-ops-kit managed role sha256: ([0-9a-f]{64})',header)
            owned=old[3]==body or bool(separator and marker and marker[1]==hashlib.sha256(remaining).hexdigest().encode())
        if not owned:
            raise Refusal(f'{path}: differs from managed role; left alone, reconcile before applying')
    return old,data

class Installer:
    def __init__(self, home, apply):
        self.home, self.apply, self.changes = home, apply, 0
        self.word = 'APPLY' if apply else 'PLAN'
        real_dirs(home, home)
    def replace(self, path, data=None, link=None, expected=UNSET, receipt=None, label=None):
        real_dirs(path.parent, self.home)
        old = check_link(path,link) if link is not None else snapshot(path)
        if expected is not UNSET and old != expected:
            raise Refusal(f'{path}: changed concurrently; left alone')
        if link is not None and old and old[0] == 'link' and old[3] == str(link) and path.exists():
            print(f'  OK {path}: already linked'); return
        if data is not None and old and old[0] == 'file' and old[3] == data:
            print(f'  OK {path}: already configured'); return
        self.changes += 1
        print(f'  {self.word} {path}: '+ (label or ('link package artifact' if link else 'merge selected configuration')))
        if not self.apply:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=path.name+'.tmp-', dir=path.parent)
        tmp = Path(tmp)
        try:
            if link is not None:
                os.close(fd); tmp.unlink(); tmp.symlink_to(link)
            else:
                with os.fdopen(fd, 'wb') as f:
                    f.write(data); f.flush(); os.fsync(f.fileno())
                os.chmod(tmp, (path.stat().st_mode & 0o777) if old else 0o600)
            if snapshot(path) != old:
                raise Refusal(f'{path}: changed concurrently; left alone')
            real_dirs(path.parent, self.home)
            saved = backup(path)
            if receipt is not None:
                receipt['backup'] = saved
            if snapshot(path) != old:
                raise Refusal(f'{path}: changed during backup; left alone')
            # Publish recovery evidence before the rename: cancellation may arrive
            # after os.replace lands but before this call can return its backup.
            if receipt is not None:
                receipt['staged'] = snapshot(tmp)
            os.replace(tmp, path)
            return saved
        finally:
            if tmp.exists() or tmp.is_symlink(): tmp.unlink()
    def links(self, kind):
        folder = PACKAGE / kind
        sources = sorted(folder.glob('*.toml')) if kind == 'agents' else sorted(folder.iterdir())
        if not sources:
            raise Refusal(f'package {kind}: no artifacts')
        plans = []
        for src in sources:
            if kind == 'agents':
                if src.is_symlink() or not src.is_file(): raise Refusal('package agent must be a regular file')
                tomllib.loads(src.read_text())
            elif not (src / 'SKILL.md').is_file():
                raise Refusal(f'package skill {src.name}: missing SKILL.md')
            dst = self.home / kind / src.name
            real_dirs(dst.parent, self.home)
            if kind == 'agents':
                old,data=role_copy(dst,src); plans.append((dst,src,old,data))
            else:
                check_link(dst,src); plans.append((dst,src,None,None))
        for dst,src,old,data in plans:
            if kind == 'agents': self.replace(dst,data=data,expected=old,label='install managed role copy')
            else: self.replace(dst,link=src)
    def config(self, updates, legacy=False, expected=UNSET, public=False):
        # public: the new values come from the package's config-fragment.toml, so PLAN and APPLY
        # name them. Hook trust carries the owner's stored states and stays withheld.
        path = self.home / 'config.toml'
        old = snapshot(path)
        if expected is not UNSET and old != expected:
            raise Refusal('config.toml changed concurrently; left alone')
        if old and old[0] != 'file':
            raise Refusal('config.toml must remain a per-Mac regular file')
        text = old[3].decode('utf-8') if old else ''
        merged = merge_toml(text, updates, legacy)
        existing = tomllib.loads(text)
        for section, fields in updates.items():
            current = existing
            for part in section:
                current = current.get(part, {}) if isinstance(current, dict) else {}
            for key, desired in fields.items():
                if not isinstance(current, dict) or current.get(key, UNSET) != desired:
                    name = '.'.join((*section, key))
                    shown = ' = '+value(desired) if public else ' (value withheld)'
                    print(f'  {self.word} {path}: set {name}{shown}')
        if legacy:
            for key in ('sandbox_mode','sandbox_workspace_write'):
                if key in existing: print(f'  {self.word} {path}: remove legacy {key} (value withheld)')
        self.replace(path, data=merged.encode(), expected=old)

# Statement boundaries track strings and brackets, so apparent headers inside multiline
# strings cannot affect the merge. Unusual managed-key spellings fail closed.
def statements(text):
    lines = text.splitlines(keepends=True)
    result, start, quote, triple, depth = [], 0, None, False, 0
    for n, line in enumerate(lines):
        i = 0
        while i < len(line):
            c = line[i]
            if quote:
                if c == '\\' and quote == '"': i += 2; continue
                delimiter = quote * (3 if triple else 1)
                if line.startswith(delimiter, i):
                    quote = None; i += len(delimiter); continue
            else:
                if c == '#': break
                if c in ('"', "'"):
                    quote = c; triple = line.startswith(c*3, i); i += 3 if triple else 1; continue
                if c in '[{': depth += 1
                if c in ']}': depth -= 1
            i += 1
        if quote is None and depth == 0:
            result.append((start, n+1, ''.join(lines[start:n+1])))
            start = n+1
    if start != len(lines): raise Refusal('configuration has unsupported unfinished statement')
    return lines, result

def value(v):
    if isinstance(v, bool): return str(v).lower()
    if isinstance(v, str): return json.dumps(v)
    if isinstance(v, int): return str(v)
    if isinstance(v, list): return '[' + ', '.join(value(x) for x in v) + ']'
    if isinstance(v, dict): return '{' + ', '.join(json.dumps(k)+' = '+value(x) for k,x in v.items()) + '}'
    raise Refusal('unsupported package TOML value')

def statement_comments(statement):
    """Keep comments when an owned declaration disappears, including multiline values."""
    kept, quote, triple, i = [], None, False, 0
    while i < len(statement):
        c = statement[i]
        if quote:
            if c == '\\' and quote == '"': i += 2; continue
            delimiter = quote * (3 if triple else 1)
            if statement.startswith(delimiter, i):
                quote = None; i += len(delimiter); continue
        elif c in ('"', "'"):
            quote = c; triple = statement.startswith(c*3, i)
            i += 3 if triple else 1; continue
        elif c == '#':
            end = statement.find('\n', i)
            end = len(statement) if end < 0 else end+1
            kept.append(statement[i:end]); i = end; continue
        i += 1
    return ''.join(kept)

def merge_toml(text, updates, legacy=False):
    try: original = tomllib.loads(text)
    except tomllib.TOMLDecodeError: raise Refusal('config.toml is not valid TOML; contents withheld')
    lines, spans = statements(text)
    section = ()
    entries, headers, declarations = {}, {}, {}
    header_starts, array_sections = [], []
    in_array = False
    for start, end, statement in spans:
        stripped = statement.strip()
        if not stripped or stripped.startswith('#'): continue
        if stripped.startswith('['):
            # Parse the header into its actual names (quoted dots are not separators).
            try:
                tree = tomllib.loads(statement+'\n__installer_marker__ = true\n')
                section = ()
                in_array = stripped.startswith('[[')
                while isinstance(tree, (dict,list)) and not (isinstance(tree,dict) and '__installer_marker__' in tree):
                    if isinstance(tree,list):
                        tree = tree[0]
                        continue
                    if len(tree) != 1: raise Refusal('ambiguous configuration table')
                    k, tree = next(iter(tree.items())); section += (k,)
                if not isinstance(tree, dict): raise Refusal('unsupported configuration table')
            except tomllib.TOMLDecodeError: raise Refusal('unsupported configuration header')
            header_starts.append(start)
            if in_array: array_sections.append(section)
            else: headers[section] = (start, end)
            continue
        match = re.match(r'\s*([A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|\'[^\']*\')\s*=', statement)
        if match and not in_array:
            key = match.group(1)
            name = next(iter(tomllib.loads(key+' = 0')))
            entries[section+(name,)] = (start, end, match.end(), statement)
        # Semantic declaration paths also cover dotted keys. Keep the old scalar
        # index above: only owned hook-state mappings use subtree replacement.
        atom = r'(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|\'[^\']*\')'
        path_match = re.match(r'\s*('+atom+r'(?:\s*\.\s*'+atom+r')*)\s*=', statement)
        if path_match and not in_array:
            tree = tomllib.loads(path_match.group(1)+' = 0'); path = section
            while isinstance(tree,dict):
                part,tree = next(iter(tree.items())); path += (part,)
            declarations[path] = (start,end,section,statement)
    patches, additions = [], {}
    if legacy:
        for k in [('sandbox_mode',), ('sandbox_workspace_write',)]:
            if k in entries:
                start,end,_,statement = entries[k]
                if end-start != 1: raise Refusal('multiline legacy setting requires owner reconciliation')
                patches.append((start,end,''))
        for sec,(start,end) in headers.items():
            if sec[:1] == ('sandbox_workspace_write',):
                stop = next((s for s,_,st in spans if s > start and st.strip().startswith('[') and s in header_starts),len(lines))
                kept = ''.join(line for line in lines[start:stop] if not line.strip() or line.lstrip().startswith('#'))
                patches.append((start,stop,kept))
    for sec, fields in updates.items():
        for key,v in fields.items():
            full = sec+(key,)
            if any(full[:len(array)] == array or array[:len(full)] == full for array in array_sections):
                raise Refusal('array table overlaps a managed setting; reconcile first')
            tree = original
            for part in sec: tree = tree.get(part,{}) if isinstance(tree,dict) else None
            exists = isinstance(tree,dict) and key in tree
            if exists and tree[key] == v: continue
            if exists and sec[:1] == ('permissions',):
                raise Refusal('existing named permission profile conflicts; reconcile the selected profile first')
            if exists and sec == ('hooks','state') and isinstance(v,dict):
                # Replace the semantic subtree at its own syntax anchor, rather than
                # assigning leaves. Descendant sections may be interleaved with siblings.
                selected_headers = [(p,span) for p,span in headers.items() if p[:len(full)] == full]
                selected_entries = [(p,span) for p,span in declarations.items() if p[:len(full)] == full]
                if not selected_headers and not selected_entries:
                    raise Refusal('managed mapping is inside an ambiguous inline ancestor')
                anchor = headers.get(full)
                if selected_headers:
                    anchor = anchor or min((span for _,span in selected_headers),key=lambda span:span[0])
                    body = ''.join(json.dumps(k)+' = '+value(x)+'\n' for k,x in v.items())
                    for path,(start,end) in selected_headers:
                        statement = ''.join(lines[start:end])
                        if (start,end) == anchor:
                            heading = statement if path == full else '['+'.'.join(json.dumps(x) for x in full)+']\n'+statement_comments(statement)
                            if not heading.endswith(('\n','\r')): heading += '\n'
                            patches.append((start,end,heading+body))
                        else: patches.append((start,end,statement_comments(statement)))
                else:
                    first = min(selected_entries,key=lambda item:item[1][0])[0]
                for path,(start,end,declaring,statement) in selected_entries:
                    kept = statement_comments(statement)
                    if not selected_headers and path == first:
                        relative = full[len(declaring):]
                        kept = '.'.join(json.dumps(x) for x in relative)+' = '+value(v)+'\n'+kept
                    patches.append((start,end,kept))
                continue
            if exists and full not in entries:
                raise Refusal('managed setting uses an ambiguous dotted/inline declaration')
            if full in entries:
                start,end,offset,statement = entries[full]
                if end-start != 1: raise Refusal('managed setting is multiline; reconcile before applying')
                # Find a real comment outside the old value's strings.
                q = None; comment = len(statement.rstrip('\r\n')); i=offset
                while i < comment:
                    c=statement[i]
                    if q:
                        if c=='\\' and q=='"': i+=2; continue
                        if c==q: q=None
                    elif c in ('"',"'"): q=c
                    elif c=='#': comment=i; break
                    i+=1
                suffix = statement[comment:]
                if suffix.startswith('#'): suffix=' '+suffix
                patches.append((start,end,statement[:offset]+' '+value(v)+suffix))
            else: additions.setdefault(sec,[]).append(json.dumps(key)+' = '+value(v)+'\n')
    # One insertion per boundary, ordered by what each block is and never by update order:
    # lines for a table that already exists (root included) first, new table blocks last.
    # A line placed after a new header at the same boundary would belong to that new table.
    insertions = {}
    for sec, extra in additions.items():
        new = bool(sec) and sec not in headers
        # A table that dotted keys already define cannot be reopened by a header: its new
        # keys join the declaring section, after the last such declaration, under the same
        # relative dotted path.
        dotted = [(end,declaring) for path,(_,end,declaring,_) in declarations.items()
                  if new and len(declaring) < len(sec) < len(path) and path[:len(sec)] == sec]
        if dotted:
            at,declaring = max(dotted); new = False
            prefix = '.'.join(json.dumps(x) for x in sec[len(declaring):])+'.'
            extra = [prefix+line for line in extra]
        elif not sec: at=min(header_starts,default=len(lines))
        elif new: at=len(lines); extra=['\n['+'.'.join(json.dumps(x) for x in sec)+']\n']+extra
        else: at=headers[sec][1]
        insertions.setdefault(at,[]).append((new,''.join(extra)))
    for at, blocks in insertions.items():
        added = ''.join(block for _,block in sorted(blocks,key=lambda b:b[0]))
        # The line break an unterminated last line needs is decided once, on the ordered whole.
        if at and not lines[at-1].endswith(('\n','\r')) and not added.startswith(('\n','\r')):
            added = '\n' + added
        patches.append((at,at,added))
    for start,end,replacement in sorted(patches,key=lambda p:(p[0],p[1]),reverse=True):
        lines[start:end]=[replacement]
    result=''.join(lines)
    try: merged = tomllib.loads(result)
    except tomllib.TOMLDecodeError: raise Refusal('merged TOML would be ambiguous; no configuration changed')
    for sec,fields in updates.items():
        actual = merged
        for part in sec: actual = actual.get(part,{}) if isinstance(actual,dict) else {}
        if not isinstance(actual,dict) or any(actual.get(k) != v for k,v in fields.items()):
            raise Refusal('merged configuration did not retain selected settings; no configuration changed')
    if legacy and any(k in merged for k in ('sandbox_mode','sandbox_workspace_write')):
        raise Refusal('legacy sandbox configuration uses ambiguous declarations; reconcile first')
    return result

def flatten(tree, prefix=()):
    out={}
    for k,v in tree.items():
        if isinstance(v,dict): out.update(flatten(v,prefix+(k,)))
        else: out.setdefault(prefix,{})[k]=v
    return out

def list_hooks(home):
    # Metadata only: no thread or authentication calls; the native loader computes hashes.
    cli = shutil.which('codex')
    if not cli: raise Refusal('codex CLI absent; hook hash trust cannot be established')
    # CODEX_HOME: the loader must read the home being edited, never the one this process inherited.
    env = dict(os.environ, CODEX_HOME=str(home))
    p = subprocess.Popen([cli,'app-server','--listen','stdio://','-c','features.hooks=true'],
                         stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                         env=env,bufsize=0)
    pending=b''
    def rpc(identifier,method,params,timeout=15):
        nonlocal pending
        p.stdin.write((json.dumps({'id':identifier,'method':method,'params':params})+'\n').encode()); p.stdin.flush()
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1)
                try: response=json.loads(line)
                except ValueError: raise Refusal('app-server emitted invalid RPC metadata')
                if response.get('id') == identifier:
                    if 'error' in response: raise Refusal('app-server rejected hook metadata request')
                    return response.get('result',{})
            if select.select([p.stdout],[],[],min(1,max(0,deadline-time.monotonic())))[0]:
                data=os.read(p.stdout.fileno(),65536)
                if not data: raise Refusal('app-server closed before returning hook metadata')
                pending+=data
                if len(pending)>2_000_000: raise Refusal('app-server metadata exceeded bound')
        raise Refusal('app-server hook metadata timed out')
    try:
        rpc(1,'initialize',{'clientInfo':{'name':'orchestration-installer','version':'1'},'capabilities':{'experimentalApi':True}},timeout=60)
        p.stdin.write(b'{"method":"initialized","params":{}}\n'); p.stdin.flush()
        result=rpc(2,'hooks/list',{'cwds':[str(PACKAGE.parent)]})
        return [h for group in result.get('data',[]) for h in group.get('hooks',[])]
    finally:
        p.terminate()
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill(); p.wait()

def merge_hook_groups(existing, desired):
    # Package ownership is (event, command), not whole-group equality. Mixed
    # groups retain their unrelated handlers and attributes under the old matcher.
    if not isinstance(existing,list): raise Refusal('existing hook event is not a list')
    commands = [h['command'] for group in desired for h in group['hooks']]
    if len(commands) != len(set(commands)):
        raise Refusal('package defines the same hook command twice in one event')
    kept, attributes = [], {}
    for group in existing:
        if not isinstance(group,dict) or not isinstance(group.get('hooks'),list):
            raise Refusal('existing hook group is malformed; left alone')
        remaining, touched = [], False
        for handler in group['hooks']:
            if not isinstance(handler,dict): raise Refusal('existing hook handler is malformed; left alone')
            command = handler.get('command')
            if command not in commands:
                remaining.append(handler)
                continue
            touched = True
            extra = {k:v for k,v in group.items() if k != 'hooks'}
            if command in attributes and attributes[command] != extra:
                raise Refusal('existing package command has ambiguous group attributes; reconcile first')
            attributes[command] = extra
        if remaining or not touched: kept.append(dict(group,hooks=remaining))
    for group in desired:
        extra = {}
        for handler in group['hooks']:
            for key,v in attributes.get(handler['command'],{}).items():
                if key not in group and key in extra and extra[key] != v:
                    raise Refusal('existing package group attributes conflict; reconcile first')
                extra[key] = v
        kept.append(dict(extra,**group))
    return kept

def hook_states(snap):
    tree = tomllib.loads(snap[3].decode()) if snap else {}
    for part in ('hooks','state'): tree = tree.get(part,{}) if isinstance(tree,dict) else {}
    return tree if isinstance(tree,dict) else {}

def home_hooks(entries, owned):
    # This home's definitions as {native key: ((event, command, hash), packaged)}. The
    # identity is the loader's own metadata; a repeated key cannot name one destination.
    found = {}
    for h in entries:
        if h.get('source') not in ('global','user'): continue
        identity = (h.get('eventName'),h.get('command'),h.get('currentHash'))
        if (not isinstance(h.get('key'),str) or h['key'] in found or not isinstance(identity[2],str)
                or not all(x is None or isinstance(x,str) for x in identity[:2])):
            raise Refusal('native hook metadata repeats a key or lacks a definition hash; hook trust left unchanged')
        found[h['key']] = (identity, identity[:2] in owned)
    return found

def install_hooks(inst):
    source=PACKAGE/'hooks.json'
    definition=json.loads(source.read_text())
    hooks=definition.get('hooks',definition)
    if not isinstance(hooks,dict) or not hooks: raise Refusal('package hooks.json has no definitions')
    expected=[]
    for event, groups in hooks.items():
        for group in groups:
            for hook in group.get('hooks',[]):
                if hook.get('type') != 'command' or not isinstance(hook.get('command'),str):
                    raise Refusal('package hook is not a command definition')
                for name in re.findall(r'\$HOME/\.codex/hooks/([^\" \t]+)',hook['command']):
                    if '/' in name or not (PACKAGE/'hooks'/name).is_file():
                        raise Refusal('package hook command refers to a missing script')
                expected.append((event[0].lower()+event[1:],hook['command']))
    real_dirs(inst.home/'hooks', inst.home)
    dst=inst.home/'hooks.json'; old=snapshot(dst)
    if old and old[0]=='file':
        try: current=json.loads(old[3])
        except ValueError: raise Refusal('existing hooks.json is invalid; contents withheld')
        if not isinstance(current,dict): raise Refusal('existing hooks.json is not an object')
        existing=current.get('hooks',current)
        if not isinstance(existing,dict): raise Refusal('existing hooks.json is not an event map')
        for event,groups in hooks.items():
            existing[event] = merge_hook_groups(existing.get(event,[]),groups)
        hook_data=(json.dumps(current,indent=2)+'\n').encode()
    elif old and old[0]=='link' and old[3] != str(source):
        raise Refusal('hooks.json points outside this package; reconcile first')
    else: hook_data=None
    # Preflight config before links: invalid configuration must not produce partial installation.
    config=inst.home/'config.toml'; state=snapshot(config)
    if state and state[0]!='file': raise Refusal('config.toml must be a regular file')
    merge_toml(state[3].decode() if state else '',{('features',):{'hooks':True}})
    scripts=sorted((PACKAGE/'hooks').glob('*.sh'))
    if not scripts: raise Refusal('package hook scripts absent')
    for script in scripts:
        if not script.is_file(): raise Refusal('package hook script unavailable')
        check_link(inst.home/'hooks'/script.name,script)
    # Native trust is keyed by position and a merge can move the owner's hooks: read the
    # loader's metadata and the stored states before the file changes, to carry them after.
    owned=set(expected)
    carry=inst.apply and hook_data is not None and hook_data!=old[3]
    if carry:
        frozen=hook_states(state)
        before=home_hooks(list_hooks(inst.home),owned)
        moved={identity:key for key,(identity,packaged) in before.items() if not packaged}
        if len(moved)!=sum(not packaged for _,packaged in before.values()):
            raise Refusal('existing hooks repeat one definition; their trust cannot be followed, reconcile first')
        if snapshot(dst)!=old or snapshot(config)!=state:
            raise Refusal('hooks.json or config.toml changed concurrently; left alone')
    for script in scripts: inst.replace(inst.home/'hooks'/script.name,link=script)
    receipt={}; landed=commit=None
    try:
        if hook_data is not None:
            inst.replace(dst,data=hook_data,expected=old,receipt=receipt)
        else:
            inst.replace(dst,link=source,expected=old,receipt=receipt)
        if not inst.apply:
            print('  PLAN enable native hooks and trust only matching package definition hashes via hooks/list')
            return
        landed=receipt['staged'] if receipt else snapshot(dst)
        if snapshot(dst)!=landed:
            raise Refusal('hooks.json changed concurrently after replacement; trust incomplete')
        if carry and (not landed or landed[0]!='file' or landed[3]!=hook_data):
            raise Refusal('hooks.json changed concurrently after replacement; trust incomplete')
        entries=list_hooks(inst.home)
        trusted={}
        for event,command in expected:
            matches=[h for h in entries if h.get('eventName')==event and h.get('command')==command
                     and h.get('source') in ('global','user')]
            if len(matches)!=1: raise Refusal('native loader did not return exactly one global package hook; links installed, trust incomplete')
            h=matches[0]
            if not isinstance(h.get('key'),str) or not isinstance(h.get('currentHash'),str) or not re.fullmatch(r'sha256:[0-9a-f]{64}',h['currentHash']):
                raise Refusal('native hook hash metadata unsupported; links installed, trust incomplete')
            trusted[h['key']]={'trusted_hash':h['currentHash'],'enabled':True}
        if carry:
            after=home_hooks(entries,owned)
            arrived={identity:key for key,(identity,packaged) in after.items() if not packaged}
            if set(arrived)!=set(moved) or len(arrived)!=sum(not packaged for _,packaged in after.values()):
                raise Refusal('existing hook definitions did not keep one identity each; hooks.json merged, trust incomplete')
            # Every destination is assigned at once from the frozen states, verbatim. A hook that
            # had no state gets an empty one where another hook's state would otherwise remain.
            for identity,key in arrived.items():
                if moved[identity] in frozen: trusted[key]=frozen[moved[identity]]
                elif key in frozen: trusted[key]={}
            if snapshot(dst)!=landed or snapshot(config)!=state:
                raise Refusal('hooks.json or config.toml changed concurrently; hooks.json merged, trust incomplete')
        commit=trusted
        inst.config({('features',):{'hooks':True},('hooks','state'):trusted},expected=state if carry else UNSET)
    except BaseException:
        # A trust commit that fails or is cancelled must leave the original positions
        # available to retry, so this path also takes the owner's Ctrl-C and re-raises it.
        # A kill or a power loss runs no handler: undoing those would need a journal, which
        # this installer does not keep, and the BACKUP line is then the only record.
        # Restore only our landed bytes; preserve a concurrent owner edit and name
        # the exact original backup when automatic recovery cannot complete. Once
        # config.toml holds the trust for the new positions the commit has landed, and
        # the merged file is the one that matches it.
        if carry:
            try:
                stored=None if commit is None else hook_states(snapshot(config))
                if stored is not None and all(stored.get(key)==v for key,v in commit.items()):
                    print('  KEPT hooks.json merged: its trust is already stored, nothing to undo')
                elif snapshot(dst)==old:
                    print('  UNCHANGED hooks.json original positions; trust unchanged, retry is safe')
                else:
                    landed=receipt.get('staged')
                    if not landed or landed[0] != 'file' or landed[3] != hook_data:
                        raise Refusal('hooks.json changed before recovery snapshot')
                    inst.replace(dst,data=old[3],expected=landed)
                    print('  RECOVERED hooks.json original positions; trust unchanged, retry is safe')
            except BaseException:
                if receipt.get('backup') is not None:
                    print(f'  RECOVERY INCOMPLETE hooks.json left alone; original preserved at {receipt["backup"]}')
                else:
                    print('  RECOVERY INCOMPLETE hooks.json left alone; backup receipt unavailable')
        raise

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--mode',choices=['check','apply'],default='check')
    parser.add_argument('--home',type=Path,required=True)
    parser.add_argument('targets',nargs='+',choices=['agents','hooks','skills','config','coordinator'])
    args=parser.parse_args()
    inst=Installer(args.home,args.mode=='apply')
    for target in dict.fromkeys(args.targets):
        print(f'-- native Codex [--codex-{target}]')
        if target in ('agents','skills'): inst.links(target)
        elif target=='hooks': install_hooks(inst)
        else:
            fragment=tomllib.loads((PACKAGE/'config-fragment.toml').read_text())
            updates = flatten(fragment)
            if target == 'config':
                updates = {sec: fields for sec, fields in updates.items()
                           if len(sec) > 1 and sec[0] == 'permissions' and sec[1].startswith('orchestration-')}
            else:
                updates = {sec: fields for sec, fields in updates.items()
                           if not sec or sec == ('features',) or sec[:2] == ('permissions', 'development')}
            inst.config(updates, legacy=target == 'coordinator', public=True)
    print(f'== native Codex done: {inst.changes} planned/applied changes')

if __name__=='__main__':
    try: main()
    except (Refusal,OSError,ValueError) as error:
        # TOML/JSON parser errors may contain private source text: never expose them.
        message=str(error) if isinstance(error,Refusal) else 'artifact or configuration could not be processed; contents withheld'
        print('  FAIL '+message)
        raise SystemExit(1)
