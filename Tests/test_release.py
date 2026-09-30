"""Release guards and orchestration tested without network, Keychain, or hardware."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TEST_REPO = "example-maintainer/dell-pbp"
TEST_REPO_URL = "https://github.com/" + TEST_REPO
spec = importlib.util.spec_from_file_location("release_tools", ROOT / "scripts/release-tools.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class MetadataTests(unittest.TestCase):
    def test_repository_urls_accept_supported_transports_and_reject_wrong_hosts(self):
        for remote in (TEST_REPO_URL, TEST_REPO_URL + ".git", "git@github.com:" + TEST_REPO + ".git",
                       "ssh://git@github.com/" + TEST_REPO + ".git"):
            self.assertEqual(release.repository_from_remote(remote), TEST_REPO)
        for remote in ("https://github.com.example.invalid/owner/repo", "https://user:secret@github.com/owner/repo",
                       "git@example.invalid:owner/repo.git", "https://github.com/owner/repo/extra"):
            with self.subTest(remote=remote), self.assertRaises(ValueError):
                release.repository_from_remote(remote)
        for value in ("owner/repo;echo oops", "owner/repo\n", "../repo", "owner/repo/path"):
            with self.assertRaises(ValueError):
                release.repository(value)

    def test_versions_reject_shell_syntax_and_nonstable_versions(self):
        for value in ("1.0.1", "2.10.9", "9999.99.99"):
            self.assertEqual(release.version(value), value)
        for value in ("1.0.1;touch /tmp/bad", "v1.0.1", "1.0.1-beta", "01.0.1", "1.100.1", "0.0.0", ""):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.version(value)

    def test_release_preflight_rejects_downgrades_and_published_reuse(self):
        old = {"tag_name": "v1.2.0", "draft": False, "prerelease": False, "id": 1}
        self.assertEqual(release.release_preflight("1.3.0", [[old]]), "")
        for value in ("1.1.0", "1.2.0"):
            with self.assertRaises(ValueError):
                release.release_preflight(value, [[old]])
        draft = {**old, "tag_name": "v1.3.0", "draft": True, "id": 2}
        self.assertEqual(release.release_preflight("1.3.0", [[old], [draft]]), "2")

    def test_github_asset_verification_rejects_corrupt_or_missing_uploads(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            assets = []
            for name in (release.ARCHIVE, "appcast.xml", "SHA256SUMS"):
                data = name.encode()
                (directory / name).write_bytes(data)
                assets.append({"name": name, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
            release.verify_assets(directory, json.dumps({"assets": assets}))
            with self.assertRaises(ValueError):
                release.verify_assets(directory, json.dumps({"assets": assets[:2]}))
            assets[0]["digest"] = "sha256:incorrect"
            with self.assertRaises(ValueError):
                release.verify_assets(directory, json.dumps({"assets": assets}))

    def test_feed_matches_bundled_version_key_and_versioned_url(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            key = base64.b64encode(bytes(32)).decode()
            plist = {"CFBundleVersion": "1.2.3", "CFBundleShortVersionString": "1.2.3", "SUPublicEDKey": key,
                     "SUFeedURL": TEST_REPO_URL + "/releases/latest/download/appcast.xml",
                     "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True}
            with zipfile.ZipFile(directory / release.ARCHIVE, "w") as archive:
                archive.writestr("Dell PBP.app/Contents/Info.plist", plistlib.dumps(plist))
            signature = base64.b64encode(bytes(64)).decode()
            feed = f'''<rss xmlns:sparkle="{release.SPARKLE[1:-1]}"><channel><item>
              <sparkle:version>1.2.3</sparkle:version><enclosure
              url="{TEST_REPO_URL}/releases/download/v1.2.3/{release.ARCHIVE}"
              length="{(directory / release.ARCHIVE).stat().st_size}" sparkle:edSignature="{signature}"/>
              </item></channel></rss>'''
            (directory / "appcast.xml").write_text(feed)
            self.assertEqual(release.verify_feed(directory, "1.2.3", key, TEST_REPO), signature)
            with self.assertRaises(ValueError):
                release.verify_feed(directory, "1.2.4", key, TEST_REPO)
            with self.assertRaises(ValueError):
                release.verify_feed(directory, "1.2.3", key, "different-owner/dell-pbp")
            (directory / "appcast.xml").write_text(feed.replace("/download/v1.2.3/", "/latest/download/"))
            with self.assertRaises(ValueError):
                release.verify_feed(directory, "1.2.3", key, TEST_REPO)


class ReleaseScriptTests(unittest.TestCase):
    """Real disposable Git repo; fake GitHub, network transport, and packaging."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        scripts = self.repo / "scripts"
        scripts.mkdir()
        resources = self.repo / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.DellPBP",
            "SUFeedURL": TEST_REPO_URL + "/releases/latest/download/appcast.xml",
        }))
        for name in ("common.sh", "release.sh", "release-tools.py"):
            shutil.copy(ROOT / "scripts" / name, scripts / name)
        (scripts / "package.sh").write_text('''#!/bin/bash
set -euo pipefail
echo package >> "$TEST_LOG"
[[ "${TEST_PACKAGE_FAIL:-}" != yes ]] || exit 1
mkdir -p "build/releases/v$1"
for asset in Dell-PBP-Apple-silicon.zip appcast.xml SHA256SUMS; do
  printf fixture > "build/releases/v$1/$asset"
done
if [[ "${TEST_SOURCE_CHANGED:-}" == yes ]]; then printf change >> tracked.txt; fi
''')
        (self.repo / ".gitignore").write_text("build/\n__pycache__/\n")
        (self.repo / "tracked.txt").write_text("source\n")
        self.real_git = shutil.which("git")
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.root / "no-hooks"))
        self.git("remote", "add", "origin", "git@github.com:" + TEST_REPO + ".git")
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_git = '''#!/bin/bash
if [[ "$1" == ls-remote ]]; then
  if [[ -n "${TEST_REMOTE_COMMIT:-}" ]]; then printf '%s\trefs/tags/v1.0.1^{}\n' "$TEST_REMOTE_COMMIT"; fi
elif [[ "$1" == push ]]; then
  printf '%s\n' "$*" >> "$TEST_LOG"
else
  exec "$TEST_REAL_GIT" "$@"
fi
'''
        fake_gh = '''#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
a = sys.argv[1:]
state_file = Path(os.environ["TEST_GH_STATE"])
s = json.loads(state_file.read_text())
with open(os.environ["TEST_LOG"], "a") as log: log.write("gh " + " ".join(a) + "\\n")
if a[0] == "auth": pass
elif a[0] == "api":
    print(json.dumps([s["releases"]] if a[1].endswith("/releases") else s["releases"][-1]))
elif a[:2] == ["release", "create"]:
    s["releases"].append({"tag_name": a[2], "id": 7, "draft": True, "prerelease": False, "assets": []})
elif a[:2] == ["release", "view"]:
    print("true" if "isDraft" in a else "7")
elif a[:2] == ["release", "upload"]:
    assets = []
    for path in a[-3:]:
        p = Path(path)
        assets.append({"name": p.name, "size": p.stat().st_size, "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()})
    if os.environ.get("TEST_BAD_UPLOAD"): assets[0]["digest"] = "sha256:broken"
    s["releases"][-1]["assets"] = assets
elif a[:2] == ["release", "edit"]:
    if "--draft=false" in a: s["releases"][-1]["draft"] = False
else: sys.exit("Unexpected fake gh call: " + repr(a))
state_file.write_text(json.dumps(s))
'''
        for name, content in (("git", fake_git), ("gh", fake_gh), ("make", '#!/bin/bash\necho tests >> "$TEST_LOG"\n')):
            path = fake_bin / name
            path.write_text(content)
            path.chmod(0o755)
        self.state = self.root / "gh-state.json"
        self.state.write_text('{"releases": []}')
        self.log = self.root / "calls.log"
        self.env = {**os.environ, "PATH": str(fake_bin) + ":" + os.environ["PATH"],
                    "TEST_REAL_GIT": self.real_git, "TEST_GH_STATE": str(self.state), "TEST_LOG": str(self.log)}
        # Release-script tests always use their own metadata, not the caller's overrides.
        self.env.pop("RELEASE_REPO", None)
        self.env.pop("SPARKLE_ACCOUNT", None)

    def git(self, *args):
        return subprocess.run([self.real_git, *args], cwd=self.repo, check=True, capture_output=True, text=True)

    def run_release(self, *args):
        return subprocess.run(["bash", "scripts/release.sh", "1.0.1", *args], cwd=self.repo,
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_release_orders_testing_packaging_tag_upload_verify_publish(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        for earlier, later in (("tests", "package"), ("package", "push origin refs/tags/v1.0.1"),
                               ("release upload", f"api repos/{TEST_REPO}/releases/7"),
                               (f"api repos/{TEST_REPO}/releases/7", "--draft=false --latest")):
            self.assertLess(calls.index(earlier), calls.index(later))
        self.assertEqual(self.git("rev-parse", "v1.0.1^{}").stdout.strip(), self.commit)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.commit)
        self.assertEqual(calls.count("push origin"), 1)

    def test_configuration_uses_product_defaults_and_explicit_overrides(self):
        def configuration():
            result = subprocess.run(["bash", "-c", 'source scripts/common.sh; printf "%s\\n%s\\n%s\\n" "$RELEASE_REPO" "$SPARKLE_ACCOUNT" "$UPDATE_FEED_URL"'],
                                    cwd=self.repo, env=self.env, capture_output=True, text=True, check=True)
            return result.stdout.splitlines()
        self.assertEqual(configuration(), [TEST_REPO, "org.example.DellPBP", TEST_REPO_URL + "/releases/latest/download/appcast.xml"])
        self.env.update(RELEASE_REPO="another-maintainer/monitor-app", SPARKLE_ACCOUNT="monitor-release-key")
        self.assertEqual(configuration(), ["another-maintainer/monitor-app", "monitor-release-key",
                                           "https://github.com/another-maintainer/monitor-app/releases/latest/download/appcast.xml"])

    def test_fork_requires_explicit_repository_selection(self):
        fork = "another-maintainer/monitor-app"
        self.git("remote", "set-url", "origin", "ssh://git@github.com/" + fork + ".git")
        self.assertNotEqual(self.run_release("--dry-run").returncode, 0)
        self.assertEqual(self.calls(), "")
        self.env["RELEASE_REPO"] = fork
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--repo {fork}", self.calls())
        self.assertNotIn(TEST_REPO, self.calls())

    def test_dirty_tree_is_rejected_before_external_operations(self):
        (self.repo / "tracked.txt").write_text("dirty")
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertEqual(self.calls(), "")
        self.assertEqual(self.git("tag").stdout, "")

    def test_untracked_source_is_rejected(self):
        (self.repo / "extra.swift").write_text("source")
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertEqual(self.calls(), "")

    def test_remote_tag_conflict_is_rejected(self):
        self.env["TEST_REMOTE_COMMIT"] = "0" * 40
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertNotIn("package", self.calls())
        self.assertEqual(self.git("tag").stdout, "")

    def test_dry_run_creates_no_tag_or_assets(self):
        self.assertEqual(self.run_release("--dry-run").returncode, 0)
        self.assertEqual(self.git("tag").stdout, "")
        self.assertNotIn("package", self.calls())
        self.assertNotIn("release create", self.calls())

    def test_package_failure_never_pushes_a_tag(self):
        self.env["TEST_PACKAGE_FAIL"] = "yes"
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertEqual(self.git("tag").stdout, "")
        self.assertNotIn("push origin", self.calls())

    def test_concurrent_source_edit_never_tags(self):
        self.env["TEST_SOURCE_CHANGED"] = "yes"
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertEqual(self.git("tag").stdout, "")

    def test_bad_upload_stays_draft_and_can_be_resumed(self):
        self.env["TEST_BAD_UPLOAD"] = "yes"
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertNotIn("--draft=false", self.calls())
        del self.env["TEST_BAD_UPLOAD"]
        self.env["TEST_REMOTE_COMMIT"] = self.commit
        self.assertEqual(self.run_release().returncode, 0)
        self.assertEqual(self.calls().count("release create"), 1)
        self.assertEqual(self.calls().count("push origin"), 1)

    def test_draft_is_not_published_and_published_version_is_not_replaced(self):
        self.assertEqual(self.run_release("--draft").returncode, 0)
        self.assertNotIn("--draft=false", self.calls())
        state = json.loads(self.state.read_text())
        state["releases"][0]["draft"] = False
        self.state.write_text(json.dumps(state))
        self.log.write_text("")
        self.assertNotEqual(self.run_release().returncode, 0)
        self.assertNotIn("package", self.calls())
        self.assertNotIn("release upload", self.calls())
