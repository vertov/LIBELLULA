#!/usr/bin/env python3
import sys, re
if len(sys.argv)<2: 
    print("usage: count_toggles.py <vcd>", file=sys.stderr); sys.exit(2)
fname=sys.argv[1]
last={}; toggles=0
with open(fname,'r') as f:
    for line in f:
        if not line: continue
        c=line[0]
        if c in '01xzXZWw':
            val=c; idc=line[1:].strip()
            prev=last.get(idc)
            if prev is not None and prev != val: toggles += 1
            last[idc]=val
        elif c=='b':
            m=re.match(r"b([01xzXZ]+)\s+(\S+)", line.strip())
            if m:
                val=m.group(1); idc=m.group(2)
                prev=last.get(idc)
                if prev is not None and prev != val: toggles += 1
                last[idc]=val
print(toggles)
