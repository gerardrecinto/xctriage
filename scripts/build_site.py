#!/usr/bin/env python3
"""Build the same static assets for deployment and browser regression checks."""
import json
import re
import shutil
from pathlib import Path

out = Path("_site")
(out / "logs").mkdir(parents=True, exist_ok=True)
for name in ("index.html", "og.png"):
    shutil.copyfile(Path("site") / name, out / name)
for name, fixture in (("compile", "xcodebuild_compile_failure"), ("test", "xcodebuild_test_failure")):
    shutil.copyfile(Path("Tests/XCTriageKitTests/Fixtures") / (fixture + ".log"), out / "logs" / (name + ".log"))
s = open("Sources/XCTriageKit/Classifiers/RuleClassifier.swift").read()
pat = re.compile(r'ClassifierRule\(\s*pattern: #"(.*?)"#,\s*category: \.(\w+),\s*weight: ([0-9.]+),\s*summaryTemplate: "((?:[^"\\]|\\.)*)",\s*fixTemplate: ((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)\s*\)', re.S)
rules = [{"pattern": m[0], "category": m[1], "weight": float(m[2]), "summary": m[3], "fix": "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m[4]))} for m in pat.findall(s)]
assert len(rules) == s.count("ClassifierRule(\n        pattern:"), "rule count mismatch"
json.dump(rules, open("_site/rules.json", "w"))
print(len(rules), "rules")
(out / ".nojekyll").touch()
