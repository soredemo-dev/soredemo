#!/usr/bin/env python3
"""Lists public Codable types whose initialiser validates but whose decode does not.

Swift's synthesised `init(from:)` assigns stored properties directly and never calls yours, so
every `precondition` and every `throw` defining an invariant is skipped exactly when a value
arrives from disk. See AGENTS.md and the Phase 2 design doc's D2-14.

This exists as a script rather than a number in a document because the number was got wrong three
times by hand, each time in a different way:

  1. scanning for `Codable` on the declaration line only — missing every type that conforms in an
     extension, which is how GeometryRegistry, ContentDigest and Evidence are written;
  2. asserting which types are reachable from `ProjectSnapshot` instead of tracing it;
  3. `break`ing after the first public type in each file, so `Normalized.swift`'s three types and
     `Derivation.swift`'s several were counted as one.

The precondition count is printed because it matters for architecture rule 8: a type can have an
explicit `init(from:)` that validates one invariant out of four. `PixelRect` and `PointRect` have
four each. Presence of `init(from:)` is necessary and not sufficient.
"""

import re, glob, sys
# 每個檔案裡的每個 public 型別，都要看；Codable 和 init(from:) 都可能在 extension 上。
rows=[]
for f in sorted(glob.glob("Sources/*/[A-Z]*.swift")):
    src=open(f).read()
    decls=[(m.start(), m.end(), m.group(1)) for m in
           re.finditer(r"public (?:struct|enum|final class) (\w+)", src)]
    for i,(s0,e0,t) in enumerate(decls):
        if t.endswith("Error") or t.endswith("Failure"): continue
        end = decls[i+1][0] if i+1 < len(decls) else len(src)
        own = src[e0:end]
        exts = "".join(re.findall(rf"\nextension {t}\b[^{{]*\{{(.*?)\n\}}", src, re.S))
        decl_line = src[s0:e0+200].split("{")[0]
        codable = bool(re.search(r"(Codable|Decodable)", decl_line)) \
               or bool(re.search(rf"\nextension {t}\s*:[^{{]*(Codable|Decodable)", src))
        if not codable: continue
        body = own + exts
        pres = len(re.findall(r"precondition\(", body))
        throwing = bool(re.search(r"init\([^)]*\)\s*throws", body))
        # A FAILABLE validating initialiser is the same defect, and the tree
        # contains the proof: Evidence.init? guards on a non-empty precondition
        # and its own comment says the guarantee is "mirrored on the decode side
        # by init(from:)". Delete that decoder init and a scan without this line
        # stays green.
        #
        # This line exists because the two implementations of this rule stopped
        # agreeing. The checker plugin started counting `init?` and this script
        # did not, so one said nine and the other eight — and the two-
        # implementation cross-check is exactly what validated the count of
        # eight in the first place. Two scanners that disagree silently are
        # worse than one, because both still answer.
        failable = bool(re.search(r"init\?\([^)]*\)", body))
        # The parameter's TYPE, not just its label. `init(from data: Data)`
        # coexists legally with the synthesised `init(from decoder: any
        # Decoder)`, so a label-only match closes a type that was never closed.
        explicit = bool(re.search(r"init\(from\s+\w+\s*:\s*[^)]*Decoder", body))
        if pres or throwing or failable:
            rows.append((t, f.split("/")[-1], pres, throwing or failable, explicit))
print(f"{'type':20s} {'file':24s} {'preconditions':13s} {'validating init':15s} {'init(from:)':11s} verdict")
print("-"*95)
open_n=0
for t,f,p,th,e in rows:
    v = "closed" if e else "*** OPEN ***"
    if not e: open_n+=1
    print(f"{t:20s} {f:24s} {p:<13d} {str(th):15s} {str(e):11s} {v}")
print(f"\n開著: {open_n} / 有驗證且 Codable 的: {len(rows)}")
