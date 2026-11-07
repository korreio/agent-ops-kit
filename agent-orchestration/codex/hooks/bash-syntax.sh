#!/usr/bin/env bash
# Native apply_patch has patch text in tool_input.command; edits have file_path.
set -u
# Advisory, and never silent: plain output here is ignored, and systemMessage is the warning channel.
unchecked() { printf '%s\n' '{"systemMessage":"bash-syntax: patch syntax not checked: python3 is unavailable. Install python3 to check edited shell scripts."}'; exit 0; }
here="$(python3 -I -B -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent)' "${BASH_SOURCE[0]}" 2>/dev/null)" || unchecked
python3 -I -B - "$here/../../claude/hooks/bash-syntax.sh" 3<&0 <<'PY'
import json,os,subprocess,sys
try:
    data=json.load(os.fdopen(3)); inp=data.get('tool_input') or {}
except Exception:
    print('bash-syntax: cannot read hook input; not checked',file=sys.stderr); sys.exit(0)
paths=[]
if inp.get('file_path'): paths.append(inp['file_path'])
for line in (inp.get('command') or '').splitlines():
    for prefix in ('*** Add File: ','*** Update File: ','*** Move to: '):
        if line.startswith(prefix): paths.append(line[len(prefix):])
result=0
for path in dict.fromkeys(paths):
    if not os.path.isabs(path): path=os.path.join(data.get('cwd') or os.getcwd(),path)
    rc=subprocess.run(['/bin/bash',sys.argv[1]],input=json.dumps({'tool_input':{'file_path':path}}),text=True).returncode
    if rc: result=2
sys.exit(result)
PY
