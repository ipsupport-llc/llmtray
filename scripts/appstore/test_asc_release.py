#!/usr/bin/env python3
"""Offline checks for asc_release.py: a scripted App Store Connect."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import asc_release as ar  # noqa: E402

failures = 0


def expect(what, ok):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    failures += 0 if ok else 1


class Fake:
    """Answers GETs from a table of path fragments; records the writes."""

    def __init__(self, answers):
        self.answers = answers
        self.writes = []

    def all(self, path):
        for fragment, data in self.answers.items():
            if fragment in path:
                return data.pop(0) if data and isinstance(data[0], list) else data
        return []

    def call(self, method, path, body=None):
        if method == "GET":
            return {"data": self.all(path)}
        self.writes.append((method, path, body))
        return {"data": {"id": "new", "attributes": {}}}


def exits(fn):
    try:
        fn()
    except SystemExit as e:
        return str(e.code)
    return None


def version(state):
    return {"id": "v1", "attributes": {"versionString": "1.2.3", "appVersionState": state}}


def build(state):
    return {"id": "b1", "attributes": {"version": "7", "processingState": state}}


# The version: none, editable, locked.
expect("no version", ar.find_version(Fake({}), "app", "MAC_OS", "1.2.3") == (None, None))
found, problem = ar.find_version(Fake({"appStoreVersions": [version("PREPARE_FOR_SUBMISSION")]}), "app", "MAC_OS", "1.2.3")
expect("editable version", found["id"] == "v1" and problem is None)
found, problem = ar.find_version(Fake({"appStoreVersions": [version("READY_FOR_SALE")]}), "app", "MAC_OS", "1.2.3")
expect("released version is refused", "can't be changed" in problem)

# Waiting: listed late, processing, then valid.
polls = Fake({"/v1/builds": [[], [build("PROCESSING")], [build("VALID")]]})
done = ar.wait_processed(polls, "app", "MAC_OS", "1.2.3", "7", 5, sleep=lambda s: None)
expect("waits until valid", done["attributes"]["processingState"] == "VALID")
refused = exits(lambda: ar.wait_processed(Fake({"/v1/builds": [[build("INVALID")]]}), "app", "MAC_OS", "1.2.3", "7", 5, sleep=lambda s: None))
expect("a refused build stops", refused and "refused" in refused)
late = exits(lambda: ar.wait_processed(Fake({"/v1/builds": [[build("PROCESSING")]]}), "app", "MAC_OS", "1.2.3", "7", 0, sleep=lambda s: None))
expect("a late build stops", late and "isn't processed" in late)

# The upload command for both generations of altool.
new = ar.upload_command("... --p8-file-path <filepath> ...", "a.pkg", "MAC_OS", "1.2.3", "7", "42", "KEY", "ISS", "/k/AuthKey_KEY.p8")
expect("new altool", new[2:] == ["--upload-package", "a.pkg", "--api-key", "KEY", "--api-issuer", "ISS", "--p8-file-path", "/k/AuthKey_KEY.p8"])
old = ar.upload_command("--apiKey", "a.pkg", "MAC_OS", "1.2.3", "7", "42", "KEY", "ISS", "/k/AuthKey_KEY.p8")
expect("old altool", old[4:8] == ["--type", "macos", "--apple-id", "42"] and old[-4:] == ["--apiKey", "KEY", "--apiIssuer", "ISS"]
       and "7" in old and "1.2.3" in old)

# Writes: a version is created for manual release; a build is attached.
api = Fake({})
ar.create_version(api, "app", "MAC_OS", "1.2.3")
method, path, body = api.writes[0]
expect("create version", (method, path) == ("POST", "/v1/appStoreVersions")
       and body["data"]["attributes"] == {"platform": "MAC_OS", "versionString": "1.2.3", "releaseType": "MANUAL"}
       and body["data"]["relationships"]["app"]["data"]["id"] == "app")
ar.attach(api, "v1", "b1")
expect("attach build", api.writes[1] == ("PATCH", "/v1/appStoreVersions/v1/relationships/build",
                                         {"data": {"type": "builds", "id": "b1"}}))

sys.exit(1 if failures else 0)
