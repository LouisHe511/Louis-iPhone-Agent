#!/usr/bin/env python3
"""Build a separately signed local runner; never distribute signing material."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
WORK = ROOT / ".build"


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def package(source, output, unsigned):
    if output.exists():
        shutil.rmtree(output)  # Only this script's ignored build output.
    shutil.copytree(source, output, symlinks=True)
    info_path = output / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleDisplayName"] = "Louis Local Control"
    info["CFBundleURLTypes"] = [{"CFBundleURLName": "LouisLocalControl", "CFBundleURLSchemes": ["louislocalcontrol"]}]
    info_path.write_bytes(plistlib.dumps(info))
    plugin = output / "PlugIns/iCTRLUITests.xctest"
    plugin_info = plistlib.loads((plugin / "Info.plist").read_bytes())
    plugin_info["CFBundleIdentifier"] = info["CFBundleIdentifier"]
    (plugin / "Info.plist").write_bytes(plistlib.dumps(plugin_info))
    # XCTest comes from the mounted developer image, not redistributed SDKs.
    for name in ["XCTAutomationSupport.framework", "XCTest.framework", "XCTestCore.framework", "XCTestSupport.framework",
                 "XCUIAutomation.framework", "XCUnit.framework", "Testing.framework", "libXCTestSwiftSupport.dylib"]:
        path = output / "Frameworks" / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    if unsigned:
        identity = "-"
    else:
        inspected = run("codesign", "-dvv", source, capture_output=True, text=True)
        identity = next((line[10:] for line in inspected.stderr.splitlines() if line.startswith("Authority=")), None)
        if not identity:
            raise SystemExit("No development signing identity found in the built runner")
    for library in (output / "Frameworks").glob("*.dylib"):
        run("codesign", "--force", "--timestamp=none", "--sign", identity, library)
    run("codesign", "--force", "--timestamp=none", "--sign", identity, plugin)
    command = ["codesign", "--force", "--timestamp=none", "--sign", identity]
    if not unsigned:
        command += ["--preserve-metadata=entitlements"]
    run(*command, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", default=os.environ.get("ACTELL_DEVELOPMENT_TEAM", ""))
    parser.add_argument("--bundle-prefix", default=os.environ.get("ACTELL_BUNDLE_ID_PREFIX", ""))
    parser.add_argument("--unsigned", action="store_true", help="Compile only; output cannot be installed as-is")
    parser.add_argument("--install", metavar="DEVICE_UDID", help="Install the signed output on your own connected phone")
    args = parser.parse_args()
    if not args.unsigned and not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("Set your own 10-character Apple development team with --team or ACTELL_DEVELOPMENT_TEAM")
    prefix = args.bundle_prefix or ("com.example.louis" if args.unsigned else "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", prefix):
        parser.error("Set a unique reverse-DNS bundle prefix with --bundle-prefix or ACTELL_BUNDLE_ID_PREFIX")
    if args.unsigned and args.install:
        parser.error("Unsigned output cannot be installed")
    WORK.mkdir(exist_ok=True)
    settings = {"SWIFT_VERSION": "5.0", "DEVELOPMENT_TEAM": args.team, "CODE_SIGN_STYLE": "Automatic",
                "CURRENT_PROJECT_VERSION": 1, "MARKETING_VERSION": "0.1"}
    resources = [{"path": str(ROOT / name), "buildPhase": "resources"}
                 for name in ["SKILL.md", "Scripts/ictrl_rpc.py", "cli/ictrl.sh"] if (ROOT / name).exists()]
    spec = {"name": "LouisLocalRunner", "options": {"deploymentTarget": {"iOS": "27.0"}}, "settings": {"base": settings},
            "targets": {
                "ProbeHost": {"type": "application", "platform": "iOS", "sources": [str(ROOT / "ProbeHost")],
                              "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": prefix + ".localcontrol.host",
                                                       "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"}}},
                "iCTRLUITests": {"type": "bundle.ui-testing", "platform": "iOS",
                                  "sources": [str(ROOT / "iCTRLUITests"), str(ROOT / "iCTRLKit")] + resources,
                                  "dependencies": [{"target": "ProbeHost"}], "settings": {"base": {
                                      "PRODUCT_BUNDLE_IDENTIFIER": prefix + ".localcontrol.uitests", "GENERATE_INFOPLIST_FILE": "YES",
                                      "SWIFT_OBJC_BRIDGING_HEADER": str(ROOT / "iCTRLUITests/XCTestPrivate-Bridging-Header.h"), "TEST_HOST": ""}}}},
            "schemes": {"LouisLocalRunner": {"build": {"targets": {"ProbeHost": "all", "iCTRLUITests": ["test"]}},
                                             "test": {"targets": ["iCTRLUITests"], "captureScreenshotsAutomatically": False}}}}
    spec_path = WORK / "project.json"
    spec_path.write_text(json.dumps(spec, indent=2))
    run("xcodegen", "generate", "--spec", spec_path, "--project", WORK)
    command = ["xcodebuild", "build-for-testing", "-project", WORK / "LouisLocalRunner.xcodeproj", "-scheme", "LouisLocalRunner",
               "-destination", "generic/platform=iOS", "-derivedDataPath", WORK / "DerivedData", "ARCHS=arm64"]
    command += ["CODE_SIGNING_ALLOWED=NO"] if args.unsigned else ["-allowProvisioningUpdates"]
    run(*command)
    source = WORK / "DerivedData/Build/Products/Debug-iphoneos/iCTRLUITests-Runner.app"
    output = package(source, WORK / "LouisLocalControl.app", args.unsigned)
    print("Runner:", output)
    if args.install:
        run("xcrun", "devicectl", "--timeout", "60", "device", "install", "app", "--device", args.install, output)


if __name__ == "__main__":
    main()
