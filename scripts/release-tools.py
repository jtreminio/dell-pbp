"""Offline release validation. Does not import or contact monitor hardware."""
import base64
import hashlib
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ARCHIVE = "Dell-PBP-Apple-silicon.zip"


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", value):
        raise ValueError("RELEASE_REPO must be a GitHub owner/repository name.")
    return value


def repository_from_remote(value):
    for prefix in ("https://github.com/", "git@github.com:", "ssh://git@github.com/"):
        if value.startswith(prefix):
            return repository(value[len(prefix):].removesuffix("/").removesuffix(".git"))
    raise ValueError("Release remote must use a GitHub HTTPS or SSH URL.")


def default_repository(plist_path):
    with open(plist_path, "rb") as file:
        feed = plistlib.load(file)["SUFeedURL"]
    prefix, suffix = "https://github.com/", "/releases/latest/download/appcast.xml"
    if not feed.startswith(prefix) or not feed.endswith(suffix):
        raise ValueError("Set RELEASE_REPO or configure a GitHub release feed in Resources/Info.plist.")
    return repository(feed[len(prefix):-len(suffix)])


def version(value):
    # CFBundleVersion permits four major digits and two minor/patch digits.
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]?)\.(?:0|[1-9][0-9]?)", value):
        raise ValueError("Use a stable version such as 1.0.1 (major <= 9999, minor/patch <= 99).")
    if value == "0.0.0":
        raise ValueError("Version must be greater than 0.0.0.")
    return value


def public_key(value):
    if len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError("Sparkle public key must contain exactly 32 bytes.")
    return value


def verify_feed(directory, expected_version, key, release_repo):
    version(expected_version)
    public_key(key)
    repo_url = "https://github.com/" + repository(release_repo)
    archive = directory / ARCHIVE
    with zipfile.ZipFile(archive) as bundle:
        plist = plistlib.loads(bundle.read("Dell PBP.app/Contents/Info.plist"))
    for field in ("CFBundleVersion", "CFBundleShortVersionString"):
        if plist[field] != expected_version:
            raise ValueError(f"Archive {field} does not match release version.")
    if plist["SUPublicEDKey"] != key:
        raise ValueError("Archive signing public key mismatch.")
    if plist["SUFeedURL"] != f"{repo_url}/releases/latest/download/appcast.xml":
        raise ValueError("Archive feed URL mismatch.")
    if not plist.get("SURequireSignedFeed") or not plist.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Archive must require signed feeds and signed downloads.")
    items = ET.parse(directory / "appcast.xml").findall("./channel/item")
    if len(items) != 1 or items[0].findtext(f"{SPARKLE}version") != expected_version:
        raise ValueError("Feed must describe exactly this release.")
    enclosure = items[0].find("enclosure")
    expected_url = f"{repo_url}/releases/download/v{expected_version}/{ARCHIVE}"
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("Feed download URL mismatch.")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Feed download length mismatch.")
    signature = enclosure.get(f"{SPARKLE}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Missing or invalid archive signature.")
    return signature


def verify_assets(directory, metadata):
    assets = {item["name"]: item for item in json.loads(metadata)["assets"]}
    for name in (ARCHIVE, "appcast.xml", "SHA256SUMS"):
        local = directory / name
        asset = assets.get(name)
        digest = "sha256:" + hashlib.sha256(local.read_bytes()).hexdigest()
        if not asset or asset.get("size") != local.stat().st_size or asset.get("digest") != digest:
            raise ValueError(f"GitHub asset verification failed: {name}")


def release_preflight(new_version, pages):
    new = tuple(map(int, version(new_version).split(".")))
    draft_id = ""
    for page in pages:
        for release in page:
            if release["tag_name"] == "v" + new_version:
                if not release["draft"]:
                    raise ValueError("This version is already published. Choose a new version.")
                draft_id = str(release["id"])
            if not release["draft"] and not release["prerelease"]:
                old = tuple(map(int, version(release["tag_name"].removeprefix("v")).split(".")))
                if new <= old:
                    raise ValueError("Release version must be newer than every published stable release.")
    return draft_id


def main(args):
    command, *args = args
    if command == "version":
        print(version(args[0]))
    elif command == "repository":
        print(repository(args[0]))
    elif command == "remote-repository":
        print(repository_from_remote(args[0]))
    elif command == "default-repository":
        print(default_repository(args[0]))
    elif command == "public-key":
        public_key(args[0])
    elif command == "newer":
        new, old = [tuple(map(int, version(v.removeprefix("v")).split("."))) for v in args]
        if new <= old:
            raise ValueError("Release version must be newer than the latest published release.")
    elif command == "feed":
        print(verify_feed(Path(args[0]), args[1], Path(args[2]).read_text().strip(), args[3]))
    elif command == "assets":
        verify_assets(Path(args[0]), sys.stdin.read())
    elif command == "preflight":
        print(release_preflight(args[0], json.load(sys.stdin)))
    else:
        raise ValueError(f"Unknown command: {command}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, ET.ParseError) as error:
        sys.exit(f"Error: {error}")
