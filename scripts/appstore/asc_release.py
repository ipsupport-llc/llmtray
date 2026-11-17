#!/usr/bin/env python3
"""A build's way into the App Store (ADR 0033), on asc_metadata's client.

    asc_release.py deliver --file LLMTray.pkg --version 0.9.3 --build 0.9.3
    asc_release.py submit  --version 0.9.3
    asc_release.py upload  --file LLMTray.pkg --version 0.9.3 --build 0.9.3

deliver: upload the build (skipped if App Store Connect has that build
number), wait until it is processed, find or create the version, push the
listing texts for every locale, attach the build. The version is left in
"Prepare for Submission".

submit: send that version to App Review.

upload: the build alone, for testers: upload it and wait until it is
processed. No version or text is touched, so it is safe while a version
is in review.

All print what they would do and change nothing without --apply.
The key: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (see asc_metadata.py).
"""

import argparse
import os
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import asc_metadata as am  # noqa: E402

# A submission that is still the user's to send or cancel.
OPEN_SUBMISSION = {"READY_FOR_REVIEW", "UNRESOLVED_ISSUES"}
IN_REVIEW = {"WAITING_FOR_REVIEW", "IN_REVIEW"}


def find_build(api, app, platform, version, build):
    """The build with this version and number, or None."""
    found = api.all(f"/v1/builds?filter[app]={app}&filter[version]={build}"
                    f"&filter[preReleaseVersion.version]={version}"
                    f"&filter[preReleaseVersion.platform]={platform}&limit=10")
    return found[0] if found else None


def upload_command(help_text, file, platform, version, build, app, key_id, issuer, key_path):
    """The altool call; its options changed between Xcode versions."""
    if "--p8-file-path" in help_text:
        return ["xcrun", "altool", "--upload-package", file, "--api-key", key_id,
                "--api-issuer", issuer, "--p8-file-path", key_path]
    return ["xcrun", "altool", "--upload-package", file, "--type", platform.lower().replace("_", ""),
            "--apple-id", app, "--bundle-id", am.BUNDLE_ID, "--bundle-version", build,
            "--bundle-short-version-string", version, "--apiKey", key_id, "--apiIssuer", issuer]


def upload(file, platform, version, build, app):
    key_path = os.path.expanduser(os.environ["ASC_KEY_PATH"])
    help_text = subprocess.run(["xcrun", "altool", "--help"], capture_output=True, text=True)
    command = upload_command(help_text.stdout + help_text.stderr, file, platform, version, build,
                             app, os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], key_path)
    # The older altool looks the key up by name in this folder.
    env = {**os.environ, "API_PRIVATE_KEYS_DIR": str(pathlib.Path(key_path).parent)}
    result = subprocess.run(command, env=env)
    if result.returncode:
        sys.exit(f"The upload failed (altool exit {result.returncode}).")


def wait_processed(api, app, platform, version, build, minutes, sleep=time.sleep):
    """The build once Apple has processed it; exits if it is refused or late."""
    deadline = time.time() + minutes * 60
    state = "not listed yet"
    while True:
        found = find_build(api, app, platform, version, build)
        if found:
            state = found["attributes"].get("processingState")
            if state == "VALID":
                return found
            if state in ("FAILED", "INVALID"):
                sys.exit(f"App Store Connect refused build {build}: {state}. See the email from Apple.")
        if time.time() > deadline:
            sys.exit(f"Build {build} isn't processed after {minutes} minutes (state: {state}).")
        print(f"  build {build}: {state}", flush=True)
        sleep(30)


def same_version(a, b):
    """1.0 and 1.0.0 are one version to the App Store."""
    def parts(v):
        numbers = [int(x) if x.isdigit() else x for x in v.split(".")]
        while numbers and numbers[-1] == 0:
            numbers.pop()
        return numbers
    return parts(a) == parts(b)


def find_version(api, app, platform, version):
    """(version or None, problem or None): a version that can still be edited."""
    listed = api.all(f"/v1/apps/{app}/appStoreVersions?filter[platform]={platform}&limit=200")
    found = [v for v in listed if same_version(v["attributes"].get("versionString", ""), version)]
    if not found:
        return None, None
    state = am.state_of(found[0])
    if state not in am.EDITABLE:
        return found[0], f"version {version} is {state}: it can't be changed"
    return found[0], None


def create_version(api, app, platform, version):
    return api.call("POST", "/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": platform, "versionString": version, "releaseType": "MANUAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]


def attach(api, version_id, build_id):
    api.call("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build",
             {"data": {"type": "builds", "id": build_id}})


def push_texts(args):
    command = [sys.executable, str(pathlib.Path(__file__).parent / "asc_metadata.py"), "push",
               "--app-info", "--platform", args.platform, "--dir", str(args.dir)]
    if args.apply:
        command.append("--apply")
    if subprocess.run(command).returncode:
        sys.exit("The texts were not all pushed.")


def upload_only(args):
    api = am.Client()
    app = am.find_app(api)
    build = find_build(api, app, args.platform, args.version, args.build)
    print(f"Build {args.version} ({args.build}): " + ("already uploaded" if build else f"upload {args.file}"))
    if not args.apply:
        print("Dry run. Add --apply to upload.")
        return
    if not build:
        if not args.file or not pathlib.Path(args.file).exists():
            sys.exit(f"No build file: {args.file}")
        upload(args.file, args.platform, args.version, args.build, app)
    wait_processed(api, app, args.platform, args.version, args.build, args.wait_minutes)
    print(f"Uploaded: {args.platform} {args.version} ({args.build}) is processed. No version was changed.")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"**{args.platform} {args.version} ({args.build})** is uploaded and processed; no version was changed.\n")


def deliver(args):
    api = am.Client()
    app = am.find_app(api)
    notes = args.dir / "en-US" / "release_notes.txt"
    live = am.targets(api, app, args.platform)[2]
    if live and not (notes.exists() and notes.read_text(encoding="utf-8").strip()):
        sys.exit(f"{notes} is needed: what is new in {args.version}.")
    problems = [p for p in am.check(am.read_locales(args.dir)) if p[1].startswith("error")]
    if problems:
        sys.exit("The texts have errors; run asc_metadata.py check.")

    version, problem = find_version(api, app, args.platform, args.version)
    if problem:
        sys.exit(problem)
    build = find_build(api, app, args.platform, args.version, args.build)

    print(f"Build {args.version} ({args.build}): " + ("already uploaded" if build else f"upload {args.file}"))
    print(f"Version {args.version}: " + ("there" if version else "create"))
    if not args.apply:
        if version:
            push_texts(args)
        print("Dry run. Add --apply to deliver.")
        return

    if not build:
        if not args.file or not pathlib.Path(args.file).exists():
            sys.exit(f"No build file: {args.file}")
        upload(args.file, args.platform, args.version, args.build, app)
    build = wait_processed(api, app, args.platform, args.version, args.build, args.wait_minutes)
    if not version:
        version = create_version(api, app, args.platform, args.version)
    push_texts(args)
    attach(api, version["id"], build["id"])
    link = f"https://appstoreconnect.apple.com/apps/{app}/distribution"
    print(f"Delivered: {args.platform} {args.version} ({args.build}) is in Prepare for Submission.\n{link}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"**{args.platform} {args.version} ({args.build})** is in Prepare for Submission: "
                    f"[App Store Connect]({link})\n")


def submit(args):
    api = am.Client()
    app = am.find_app(api)
    version, problem = find_version(api, app, args.platform, args.version)
    if not version:
        sys.exit(f"No {args.platform} version {args.version}: deliver it first.")
    if am.state_of(version) in IN_REVIEW:
        print(f"Version {args.version} is already {am.state_of(version)}.")
        return
    if problem:
        sys.exit(problem)
    attached = api.call("GET", f"/v1/appStoreVersions/{version['id']}/relationships/build").get("data")
    if not attached:
        sys.exit(f"Version {args.version} has no build: deliver it first.")

    submissions = api.all(f"/v1/reviewSubmissions?filter[app]={app}&filter[platform]={args.platform}"
                          f"&filter[state]={','.join(sorted(OPEN_SUBMISSION))}&limit=10")
    print(f"Submit {args.platform} {args.version} for review"
          + (" (in the open submission)" if submissions else ""))
    if not args.apply:
        print("Dry run. Add --apply to submit.")
        return

    if submissions:
        submission = submissions[0]
    else:
        submission = api.call("POST", "/v1/reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": args.platform},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
    items = api.all(f"/v1/reviewSubmissions/{submission['id']}/items?limit=50")
    if not items:
        api.call("POST", "/v1/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    api.call("PATCH", f"/v1/reviewSubmissions/{submission['id']}", {"data": {
        "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    print(f"Submitted: {args.platform} {args.version} is waiting for review.")


def main():
    p = argparse.ArgumentParser(description="Deliver a build to App Store Connect, or submit it.")
    p.add_argument("command", choices=["deliver", "submit", "upload"])
    p.add_argument("--version", required=True, help="the version, e.g. 0.9.3")
    p.add_argument("--build", help="the build number (default: the version)")
    p.add_argument("--file", help="the package to upload")
    p.add_argument("--platform", default="MAC_OS", help="App Store Connect platform of the version")
    p.add_argument("--dir", type=pathlib.Path, default=am.ROOT / "appstore" / "metadata")
    p.add_argument("--wait-minutes", type=int, default=30)
    p.add_argument("--apply", action="store_true", help="do it (a dry run without)")
    args = p.parse_args()
    args.build = args.build or args.version
    {"deliver": deliver, "submit": submit, "upload": upload_only}[args.command](args)


if __name__ == "__main__":
    main()
