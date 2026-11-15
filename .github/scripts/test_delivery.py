import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import delivery

REPOSITORY = "922763798103.dkr.ecr.us-west-2.amazonaws.com/inference-router"
OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64
IMAGE = f"{REPOSITORY}@{NEW}"
MANIFEST = f"""apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
  - name: inference-router
    newName: {REPOSITORY}
    digest: {OLD}
"""


class GitOpsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        origin = root / "origin.git"
        delivery.git("init", "--bare", "--initial-branch=main", str(origin))
        work = root / "work"
        work.mkdir()
        self.addCleanup(os.chdir, Path.cwd())
        os.chdir(work)
        delivery.git("init", "--initial-branch=main")
        delivery.git("config", "user.name", "Promotion Test")
        delivery.git("config", "user.email", "test@example.com")
        delivery.git("config", "commit.gpgsign", "false")
        delivery.git("remote", "add", "origin", str(origin))
        for environment in ("dev", "staging"):
            overlay = delivery.overlay(environment)
            overlay.parent.mkdir(parents=True)
            overlay.write_text(MANIFEST)
        delivery.git("add", "deploy")
        delivery.git("commit", "-m", "Source commit")
        delivery.git("push", "origin", "main")
        self.source = delivery.git("rev-parse", "HEAD")
        self.output = root / "output"
        context = patch.dict(os.environ, {
            "GITHUB_OUTPUT": str(self.output), "GITHUB_STEP_SUMMARY": str(root / "summary"),
            "GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": "owner/router",
            "GITHUB_RUN_ID": "1",
        })
        context.start()
        self.addCleanup(context.stop)
        render = patch.object(delivery, "validate_render", autospec=True)
        render.start()
        self.addCleanup(render.stop)

    def promote(self, environment="dev", dev_revision=None):
        delivery.promote(SimpleNamespace(
            environment=environment, source=self.source, image=IMAGE, dev_revision=dev_revision,
        ))
        return dict(line.split("=", 1) for line in self.output.read_text().splitlines())

    def test_promotes_only_the_digest_and_reuses_the_same_commit(self):
        dev = self.promote()
        self.assertEqual(delivery.git("show", "--format=", "--name-only", dev["revision"]),
                         str(delivery.overlay("dev")))
        self.assertEqual(delivery.overlay("dev").read_text(), MANIFEST.replace(OLD, NEW))
        self.assertEqual(delivery.overlay("staging").read_text(), MANIFEST)
        self.assertEqual(self.promote(), dev)
        stage = self.promote("staging", dev["revision"])
        self.assertEqual(stage["previous_digest"], OLD)
        self.assertEqual(delivery.git("show", "--format=", "--name-only", stage["revision"]),
                         str(delivery.overlay("staging")))
        self.assertEqual(delivery.overlay("staging").read_text(), MANIFEST.replace(OLD, NEW))
        self.assertEqual(self.promote("staging", dev["revision"]), stage)

    def test_refuses_to_promote_staging_if_dev_was_reverted(self):
        dev = self.promote()
        delivery.git("revert", "--no-edit", dev["revision"])
        delivery.git("push", "origin", "HEAD:main")
        with self.assertRaisesRegex(ValueError, "no longer references"):
            self.promote("staging", dev["revision"])
        with self.assertRaisesRegex(ValueError, "previously promoted"):
            self.promote()

    def test_refuses_to_promote_an_old_source_after_a_newer_candidate(self):
        original_source = self.source
        delivery.git("commit", "--allow-empty", "-m", "New source")
        delivery.git("push", "origin", "main")
        self.source = delivery.git("rev-parse", "HEAD")
        self.promote()
        self.source = original_source
        with self.assertRaisesRegex(ValueError, "newer or incompatible promotion"):
            self.promote()

    def test_rebuilds_the_promotion_after_a_non_fast_forward_push(self):
        rival = Path.cwd().parent / "rival"
        origin = delivery.git("remote", "get-url", "origin")
        delivery.git("clone", origin, str(rival))
        delivery.git("-C", str(rival), "-c", "user.name=Rival", "-c", "user.email=rival@example.com",
                     "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Concurrent merge")
        rival_sha = delivery.git("-C", str(rival), "rev-parse", "HEAD")
        original_command = delivery.command
        has_pushed = False

        def race(*args, **kwargs):
            nonlocal has_pushed
            if args[:2] == ("git", "push") and not has_pushed:
                has_pushed = True
                delivery.git("-C", str(rival), "push", "origin", "main")
            return original_command(*args, **kwargs)

        with patch.object(delivery, "command", side_effect=race):
            dev = self.promote()
        self.assertEqual(delivery.git("rev-parse", dev["revision"] + "^"), rival_sha)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(
            source="1" * 40, image=IMAGE, dev_revision="2" * 40, stage_revision="3" * 40,
            previous_digest=OLD, dev_evidence="https://github.com/owner/router/actions/runs/1/artifacts/1",
            stage_evidence="https://github.com/owner/router/actions/runs/1/artifacts/2",
            run_url="https://github.com/owner/router/actions/runs/1",
        )

    def test_release_creation_and_identical_retry(self):
        state = {}

        def request(path, payload=None, missing_ok=False):
            if path == "releases":
                state.update(payload, html_url="https://github.com/owner/router/releases/tag/staging")
            return state or None

        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {
            "GITHUB_STEP_SUMMARY": str(Path(temp) / "summary"),
        }), patch.object(delivery, "fetch_main"), patch.object(delivery, "verify_gitops_revision"), \
             patch.object(delivery, "check_tag", side_effect=lambda *_: bool(state)), \
             patch.object(delivery, "github_request", side_effect=request) as github:
            delivery.release(self.args)
            self.assertEqual(state["tag_name"], f"staging-{self.args.source}")
            self.assertEqual(state["target_commitish"], self.args.source)
            self.assertTrue(state["prerelease"])
            self.assertFalse(state["draft"])
            self.assertEqual(state["make_latest"], "false")
            delivery.release(self.args)
            self.assertEqual([call.args[0] for call in github.call_args_list].count("releases"), 1)
            self.args.image = f"{REPOSITORY}@{OLD}"
            with self.assertRaisesRegex(ValueError, "conflicts"):
                delivery.release(self.args)

    def test_rejects_a_tag_that_points_to_another_source(self):
        tag = f"staging-{self.args.source}"
        with (
            patch.object(delivery, "git", return_value=f"{'4' * 40}\trefs/tags/{tag}"),
            self.assertRaisesRegex(ValueError, "tag points at"),
        ):
            delivery.check_tag(tag, self.args.source)


if __name__ == "__main__":
    unittest.main()
