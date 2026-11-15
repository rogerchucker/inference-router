# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import yaml

MAIN = "refs/remotes/origin/main"
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
IMAGE = re.compile(rf"[0-9]{{12}}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/inference-router@{DIGEST.pattern}")


def command(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def git(*args):
    return command("git", *args).stdout.rstrip("\n")


def has_ancestor(ancestor, descendant):
    result = command("git", "merge-base", "--is-ancestor", ancestor, descendant, check=False)
    if result.returncode > 1:
        result.check_returncode()
    return result.returncode == 0


def fetch_main():
    git("fetch", "--no-tags", "origin", f"refs/heads/main:{MAIN}")
    return git("rev-parse", MAIN)


def overlay(environment):
    return Path("deploy/overlays") / environment / "kustomization.yaml"


def router_image(manifest):
    entries = yaml.safe_load(manifest)["images"]
    matches = [entry for entry in entries if entry.get("name") == "inference-router"]
    if len(matches) != 1 or set(matches[0]) != {"name", "newName", "digest"}:
        raise ValueError("Expected one router image entry containing a repository and digest")
    entry = matches[0]
    if not DIGEST.fullmatch(entry["digest"]):
        raise ValueError("Router image entry must contain an immutable digest")
    return entry["newName"], entry["digest"]


def image_at(revision, environment):
    return "@".join(router_image(git("show", f"{revision}:{overlay(environment)}")))


def verify_gitops_revision(base, revision, environment, image):
    if not has_ancestor(revision, base) or image_at(revision, environment) != image:
        raise ValueError(f"{environment} GitOps revision does not identify this candidate on main")
    if image_at(base, environment) != image:
        raise ValueError(f"{environment} overlay on main no longer references this candidate")


def validate_render(path, image):
    rendered = command("kubectl", "kustomize", str(path.parent)).stdout
    routers = [
        document for document in yaml.safe_load_all(rendered)
        if document and document.get("kind") == "Deployment"
        and document.get("metadata", {}).get("name") == "inference-router"
    ]
    if len(routers) != 1:
        raise ValueError("Expected one rendered inference-router Deployment")
    containers = routers[0]["spec"]["template"]["spec"]["containers"]
    if [container["image"] for container in containers if container["name"] == "router"] != [image]:
        raise ValueError("Rendered router Deployment does not run the candidate image")


def change_digest(path, image, previous):
    repository, digest = image.split("@")
    manifest = path.read_bytes().decode()
    if router_image(manifest) != (repository, previous):
        raise ValueError("Candidate and overlay must use the same ECR repository")
    # Keep the manifest byte-for-byte identical except for the digest value.
    pattern = rf"(?m)^([ \t]+digest:[ \t]+){re.escape(previous)}([ \t]*\r?)$"
    updated, replacements = re.subn(pattern, rf"\g<1>{digest}\g<2>", manifest)
    if replacements != 1 or router_image(updated) != (repository, digest):
        raise ValueError("Expected exactly one editable router digest line")
    path.write_bytes(updated.encode())


def record_promotion(environment, image, revision, previous):
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        print(f"revision={revision}\nprevious_digest={previous}", file=output)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        print(f"{environment} GitOps revision `{revision}` selects `{image}`. "
              f"Previous digest `{previous}`.", file=summary)


def previous_promotion(base, path, environment):
    return git(
        "log", "-1", "--format=%H", f"--grep=^Promote {environment} image$", base, "--", str(path)
    )


def promote(args):
    path = overlay(args.environment)
    for attempt in range(3):
        base = fetch_main()
        if not has_ancestor(args.source, base):
            raise ValueError("The candidate source commit is not on main")
        if args.environment == "staging":
            verify_gitops_revision(base, args.dev_revision, "dev", args.image)

        git("switch", "--detach", base)
        repository, previous = router_image(path.read_text())
        if args.image.split("@")[0] != repository:
            raise ValueError("Candidate and overlay must use the same ECR repository")
        prior = previous_promotion(base, path, args.environment)
        if prior:
            prior_source = git("show", "-s", "--format=%(trailers:key=Promotion-Source,valueonly)", prior)
            if not SHA.fullmatch(prior_source) or not has_ancestor(prior_source, args.source):
                raise ValueError(f"{args.environment} has a newer or incompatible promotion")
            if prior_source == args.source and image_at(base, args.environment) != args.image:
                raise ValueError(f"{args.environment} previously promoted this source and then changed digest")

        if previous == args.image.split("@")[1]:
            validate_render(path, args.image)
            revision = git("log", "-1", "--format=%H", base, "--", str(path))
            if prior and image_at(prior, args.environment) == args.image:
                previous = image_at(f"{prior}^", args.environment).split("@")[1]
            record_promotion(args.environment, args.image, revision, previous)
            return

        change_digest(path, args.image, previous)
        validate_render(path, args.image)
        git("add", "--", str(path))
        if git("diff", "--cached", "--numstat") != f"1\t1\t{path}":
            raise ValueError("Promotion must change exactly one digest line in the target overlay")
        run_url = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
        evidence = [
            f"Promotion-Source: {args.source}",
            f"Promotion-Image: {args.image}",
            f"Promotion-Run: {run_url}",
            f"Previous-Digest: {previous}",
        ]
        if args.dev_revision:
            evidence.extend(["Dev-Verification: passed", f"Verified-Dev-Revision: {args.dev_revision}"])
        git("commit", "-m", f"Promote {args.environment} image", "-m", "\n".join(evidence))
        revision = git("rev-parse", "HEAD")
        result = command("git", "push", "origin", "HEAD:refs/heads/main", check=False)
        if result.returncode == 0:
            record_promotion(args.environment, args.image, revision, previous)
            return
        if fetch_main() == base or attempt == 2:
            result.check_returncode()
        print("main advanced during push. Revalidating against the latest revision.", file=sys.stderr)


def github_request(path, payload=None, missing_ok=False):
    url = f"{os.environ['GITHUB_API_URL']}/repos/{os.environ['GITHUB_REPOSITORY']}/{path}"
    request = Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
    }, data=json.dumps(payload).encode() if payload is not None else None)
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise


def check_tag(tag, source):
    tag_ref = f"refs/tags/{tag}"
    refs = {
        ref: sha for sha, ref in (row.split() for row in git("ls-remote", "origin", tag_ref, f"{tag_ref}^{{}}").splitlines())
    }
    target = refs.get(f"{tag_ref}^{{}}", refs.get(tag_ref))
    if target and target != source:
        raise ValueError(f"Existing {tag} tag points at {target}, expected {source}")
    return target is not None


def release(args):
    tag = f"staging-{args.source}"
    release_path = f"releases/tags/{tag}"
    base = fetch_main()
    verify_gitops_revision(base, args.dev_revision, "dev", args.image)
    verify_gitops_revision(base, args.stage_revision, "staging", args.image)
    source_fields = {
        "source": args.source, "image": args.image,
        "dev_revision": args.dev_revision, "stage_revision": args.stage_revision,
        "previous_stage_digest": args.previous_digest,
    }
    marker = f"<!-- promotion-evidence: {json.dumps(source_fields, sort_keys=True)} -->"
    image_line = f"Tested image `{args.image}` from source `{args.source}`."
    body = "\n".join([
        image_line,
        "",
        f"- Dev GitOps revision `{args.dev_revision}`. [Smoke test results]({args.dev_evidence})",
        f"- Stage GitOps revision `{args.stage_revision}`. [Smoke test results]({args.stage_evidence})",
        f"- Previous Stage digest `{args.previous_digest}`.",
        f"- [CI and promotion run]({args.run_url}).",
        "",
        marker,
    ])
    tag_exists = check_tag(tag, args.source)
    existing = github_request(release_path, missing_ok=True)
    if existing is None:
        try:
            existing = github_request("releases", {
                "tag_name": tag, "target_commitish": args.source, "name": tag, "body": body,
                "prerelease": True, "draft": False, "make_latest": "false",
            })
        except URLError as error:
            if isinstance(error, HTTPError) and error.code not in {422, 500, 502, 503, 504}:
                raise
            existing = github_request(release_path, missing_ok=True)
            if existing is None:
                raise
    elif not tag_exists:
        raise ValueError(f"Existing {tag} release has no tag")
    if not check_tag(tag, args.source):
        raise ValueError(f"Expected {tag} to identify the source commit")
    release_lines = (existing.get("body") or "").splitlines()
    if (existing.get("tag_name") != tag or existing.get("draft") is not False
            or existing.get("prerelease") is not True or marker not in release_lines
            or image_line not in release_lines):
        raise ValueError(f"Existing {tag} release conflicts with this verified promotion")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        print(f"[Stage prerelease {tag}]({existing['html_url']}) selects `{args.image}`.", file=summary)


def matching(pattern):
    def parse(value):
        if not pattern.fullmatch(value):
            raise argparse.ArgumentTypeError(f"Invalid value {value!r}")
        return value
    return parse


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_subparsers(dest="action", required=True)
    deploy = actions.add_parser("promote")
    deploy.add_argument("--environment", choices=("dev", "staging"), required=True)
    publish = actions.add_parser("release")
    for action in (deploy, publish):
        action.add_argument("--source", type=matching(SHA), required=True)
        action.add_argument("--image", type=matching(IMAGE), required=True)
        action.add_argument("--dev-revision", type=matching(SHA), required=action is publish)
    publish.add_argument("--stage-revision", type=matching(SHA), required=True)
    publish.add_argument("--previous-digest", type=matching(DIGEST), required=True)
    for flag in ("run-url", "dev-evidence", "stage-evidence"):
        publish.add_argument(f"--{flag}", required=True)
    args = parser.parse_args()
    if args.action == "promote" and (args.environment == "staging") != bool(args.dev_revision):
        parser.error("Only the staging promotion requires a verified Dev revision")
    try:
        promote(args) if args.action == "promote" else release(args)
    except subprocess.CalledProcessError as error:
        parser.exit(1, f"Command failed: {error.stderr.strip() or error}\n")
    except (ValueError, KeyError, URLError, yaml.YAMLError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
