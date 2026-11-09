#!/usr/bin/env python3
"""Portable source-layout checks; does not access a phone or credentials."""
import ast
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
for relative in ["local-control/build.py", "ios-app/scripts/generate_xcode_project.py"]:
    ast.parse((ROOT / relative).read_text())
for relative in ["ios-app/ProviderKit/Package.swift", "ios-app/Vendor/SwiftAgentKit/Package.swift"]:
    text = (ROOT / relative).read_text()
    assert not re.search(r'package\(path:\s*"(?:/|\.\./\.\./\.vendor)', text), relative
project = (ROOT / "ios-app/PhoneAgent.xcodeproj/project.pbxproj").read_text()
assert not re.search(r"DEVELOPMENT_TEAM = [A-Z0-9]{10}", project), "Personal team committed"
assert "/Users/" not in project, "Absolute developer path committed"
for relative in ["LICENSE", "THIRD_PARTY.md", "README.md", "README.zh-CN.md", "SECURITY.md", "local-control/LICENSE", "local-control/NOTICE.md", "local-control/UPSTREAM.md"]:
    assert (ROOT / relative).is_file(), relative
print("Public source checks passed")
