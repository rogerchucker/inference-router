# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["boto3==1.44.3", "botocore==1.44.3"]
# ///
"""Verify a promoted image through the private EKS API and router Service."""

import argparse
import http.client
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from contextlib import closing, contextmanager
from pathlib import Path
from urllib.parse import urlsplit

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

ACCOUNT = "922763798103"
REGION = "us-west-2"
ROUTER = "inference-router"
LOOPBACK = "127.0.0.1"
REPLICAS = 2
COMMIT = re.compile(r"[0-9a-f]{40}")
IMAGE = re.compile(
    rf"{ACCOUNT}\.dkr\.ecr\.{REGION}\.amazonaws\.com/{ROUTER}@sha256:[0-9a-f]{{64}}"
)
FORWARDING = re.compile(r"^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$", re.MULTILINE)
SDK_CONFIG = Config(connect_timeout=5, read_timeout=10, retries={"mode": "standard", "total_max_attempts": 3})


class VerificationFailed(Exception):
    """A verification error safe for Actions logs."""


def run(command):
    return subprocess.run(command, check=False, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=25)


@contextmanager
def background(command, **kwargs):
    with subprocess.Popen(command, stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT, **kwargs) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


@contextmanager
def private_kubeconfig(directory, region, cluster_name, session_host):
    session = boto3.Session(region_name=region)
    with closing(session.client("eks", config=SDK_CONFIG)) as eks:
        cluster = eks.describe_cluster(name=cluster_name)["cluster"]
    vpc = cluster["resourcesVpcConfig"]
    if (
        cluster["arn"] != f"arn:aws:eks:{region}:{ACCOUNT}:cluster/{cluster_name}"
        or cluster["status"] != "ACTIVE"
        or vpc["endpointPublicAccess"]
        or not vpc["endpointPrivateAccess"]
    ):
        raise VerificationFailed("Expected the active private EKS cluster.")
    endpoint = urlsplit(cluster["endpoint"])
    if endpoint.scheme != "https" or not endpoint.hostname:
        raise VerificationFailed("EKS returned an invalid HTTPS endpoint.")

    with socket.socket() as address:
        address.bind((LOOPBACK, 0))
        port = address.getsockname()[1]
    path = directory / "kubeconfig"
    path.touch(mode=0o600)
    path.write_text(json.dumps({
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [{"name": cluster_name, "cluster": {
            "server": f"https://{LOOPBACK}:{port}",
            "tls-server-name": endpoint.hostname,
            "certificate-authority-data": cluster["certificateAuthority"]["data"],
        }}],
        "users": [{"name": "verifier", "user": {"exec": {
            "apiVersion": "client.authentication.k8s.io/v1beta1",
            "command": "aws",
            "args": ["eks", "get-token", "--cluster-name", cluster_name, "--region", region],
            "interactiveMode": "Never",
        }}}],
        "contexts": [{"name": cluster_name, "context": {"cluster": cluster_name, "user": "verifier"}}],
        "current-context": cluster_name,
    }))

    request = {
        "Target": session_host,
        "DocumentName": "AWS-StartPortForwardingSessionToRemoteHost",
        "Parameters": {"host": [endpoint.hostname], "portNumber": ["443"], "localPortNumber": [str(port)]},
    }
    with closing(session.client("ssm", config=SDK_CONFIG)) as ssm:
        response = ssm.start_session(**request)
        try:
            payload = {key: response[key] for key in ("SessionId", "StreamUrl", "TokenValue")}
            tunnel = [
                "session-manager-plugin", "AWS_SSM_START_SESSION_RESPONSE", region, "StartSession",
                "", json.dumps(request), ssm.meta.endpoint_url,
            ]
            environment = dict(os.environ, AWS_SSM_START_SESSION_RESPONSE=json.dumps(payload))
            with background(tunnel, env=environment, stdout=subprocess.DEVNULL) as process:
                yield ["kubectl", "--kubeconfig", str(path)], process
        finally:
            try:
                ssm.terminate_session(SessionId=response["SessionId"])
            except ClientError as error:
                # The plugin may already have closed it after receiving SIGTERM.
                if error.response["Error"]["Code"] not in {"DoesNotExistException", "InvalidSessionId"}:
                    raise


def read_resource(kubectl, namespace, resource, *args):
    result = run([*kubectl, "--request-timeout=6s", "-n", namespace, "get", resource, *args, "-o", "json"])
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "(Forbidden)" in result.stderr or "(Unauthorized)" in result.stderr:
        raise VerificationFailed("The verification role cannot read the target Kubernetes resource.")
    return {}


def is_expected_revision(expected, observed):
    if not COMMIT.fullmatch(observed):
        return False
    if expected == observed:
        return True
    if any(run(["git", "cat-file", "-e", f"{revision}^{{commit}}"]).returncode for revision in (expected, observed)):
        fetched = run(["git", "fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main"])
        if fetched.returncode:
            raise VerificationFailed("Could not fetch main to verify the Argo CD revision.")
    return run(["git", "merge-base", "--is-ancestor", expected, observed]).returncode == 0


def deployment_matches(deployment, image):
    spec = deployment.get("spec", {})
    status = deployment.get("status", {})
    containers = spec.get("template", {}).get("spec", {}).get("containers", [])
    return (
        spec.get("replicas") == REPLICAS
        and deployment["metadata"]["generation"] == status.get("observedGeneration")
        and all(status.get(key) == REPLICAS for key in ("replicas", "updatedReplicas", "readyReplicas", "availableReplicas"))
        and any(container["name"] == "router" and container.get("image") == image for container in containers)
    )


def pods_match(pods, image):
    active = [pod for pod in pods if not pod["metadata"].get("deletionTimestamp")]
    return len(active) == REPLICAS and all(
        any(condition["type"] == "Ready" and condition["status"] == "True"
            for condition in pod.get("status", {}).get("conditions", []))
        and any(container["name"] == "router" and container.get("ready")
                and container.get("imageID", "").removeprefix("docker-pullable://") == image
                for container in pod.get("status", {}).get("containerStatuses", []))
        for pod in active
    )


def wait_for_rollout(kubectl, tunnel, namespace, image, revision, timeout):
    deadline = time.monotonic() + timeout
    incomplete = "Kubernetes API or Argo CD Application unavailable."
    while time.monotonic() < deadline:
        if tunnel.poll() is not None:
            raise VerificationFailed("Session Manager tunnel closed before verification.")
        application = read_resource(kubectl, "argocd", f"applications.argoproj.io/{namespace}")
        if application:
            status = application.get("status", {})
            sync = status.get("sync", {})
            observed = sync.get("revision") or ""
            incomplete = "Argo CD did not report Synced and Healthy at the promotion revision or its descendant."
            if (
                sync.get("status") == "Synced"
                and status.get("health", {}).get("status") == "Healthy"
                and is_expected_revision(revision, observed)
            ):
                deployment = read_resource(kubectl, namespace, f"deployment/{ROUTER}")
                pods = read_resource(kubectl, namespace, "pods", "-l", f"app.kubernetes.io/name={ROUTER}")
                incomplete = "The Deployment and both Ready Pods did not converge on the promoted image digest."
                if deployment_matches(deployment, image) and pods_match(pods.get("items", []), image):
                    return observed
        time.sleep(5)
    raise VerificationFailed(incomplete)


@contextmanager
def router_service(kubectl, namespace, directory):
    output = directory / "forward.log"
    command = [*kubectl, "-n", namespace, "port-forward", "--address", LOOPBACK, f"service/{ROUTER}", ":8080"]
    # SPDY uses the create verb on pods/portforward.
    with output.open("w") as log, background(
        command, env=dict(os.environ, KUBECTL_PORT_FORWARD_WEBSOCKETS="false"), stdout=log,
    ) as process:
        deadline = time.monotonic() + 30
        while process.poll() is None and time.monotonic() < deadline:
            forwarding = FORWARDING.search(output.read_text())
            if forwarding:
                yield int(forwarding[1])
                return
            time.sleep(0.25)
    raise VerificationFailed("Could not port-forward the private inference-router Service.")


def request_json(port, path, payload=None):
    connection = http.client.HTTPConnection(LOOPBACK, port, timeout=65 if payload else 10)
    try:
        if payload is None:
            connection.request("GET", path)
        else:
            connection.request("POST", path, json.dumps(payload), {"Content-Type": "application/json"})
        response = connection.getresponse()
        data = response.read(1_048_577)
        if len(data) > 1_048_576:
            raise VerificationFailed("The router returned an oversized response.")
        try:
            body = json.loads(data)
        except (ValueError, UnicodeError):
            body = {}
        return response.status, body if isinstance(body, dict) else {}
    finally:
        connection.close()


def smoke_test(port):
    status, body = request_json(port, "/readyz")
    if status != 200 or body.get("status") != "ready":
        raise VerificationFailed(f"Readiness check failed (HTTP {status}).")
    print("Readiness passed.")

    for label, fields in (("explicit", {"task": "auto", "allow_cloud": False}), ("omitted", {})):
        status, body = request_json(port, "/v1/infer", {"prompt": "Release smoke test", **fields})
        if status != 422 or body.get("detail") != "local_inference_unavailable":
            raise VerificationFailed(f"Cloud-disabled check ({label}) failed (HTTP {status}).")
        print(f"Cloud-disabled check ({label}) passed.")

    checks = (
        ("writing", "Write a two-sentence team update about a fictional product demo.", "claude", "explicit_writing"),
        ("coding", "Write a Python function that adds two integers. Return only the code.", "openai", "explicit_coding"),
        ("reasoning", "Which is greater, 13 squared or 12 squared plus 24? Reply in one short sentence.",
         "openai", "explicit_reasoning"),
        (
            "auto",
            (
                "Write a Python function with an assertion-based unit test for a function that returns "
                "the maximum of two integers. Keep it short."
            ),
            "openai",
            "classified_coding",
        ),
    )
    for task, prompt, provider, reason in checks:
        status, body = request_json(port, "/v1/infer", {
            "task": task, "prompt": prompt, "allow_cloud": True, "max_tokens": 384,
        })
        if (
            status != 200
            or body.get("provider") != provider
            or body.get("routing_reason") != reason
            or not isinstance(body.get("text"), str)
            or not body["text"].strip()
        ):
            raise VerificationFailed(f"{task} routing check failed (HTTP {status}, expected {provider}/{reason}).")
        print(f"{task} routing check passed ({provider}/{reason}).")


def verify(args):
    namespace = f"{ROUTER}-{args.environment}"
    region = os.getenv("AWS_REGION")
    cluster = os.getenv("EKS_CLUSTER")
    session_host = os.getenv("EKS_SESSION_HOST_ID", "")
    if region != REGION or cluster != namespace or not re.fullmatch(r"i-[0-9a-f]{17}", session_host):
        raise VerificationFailed("The verification environment variables do not match the target EKS environment.")
    for tool in ("aws", "git", "kubectl", "session-manager-plugin"):
        if not shutil.which(tool):
            raise VerificationFailed(f"{tool} is required on the verification runner.")

    with tempfile.TemporaryDirectory() as workspace:
        directory = Path(workspace)
        with private_kubeconfig(directory, region, cluster, session_host) as (kubectl, tunnel):
            wait_for_rollout(kubectl, tunnel, namespace, args.image, args.revision, timeout=540)
            with router_service(kubectl, namespace, directory) as port:
                smoke_test(port)
            observed = wait_for_rollout(kubectl, tunnel, namespace, args.image, args.revision, timeout=30)
    print(f"{args.environment} verified {args.image} at Argo CD revision {observed} with {REPLICAS} Ready Pods.")


def cancel(_signal, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=("dev", "staging"), required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    if not IMAGE.fullmatch(args.image) or not COMMIT.fullmatch(args.revision):
        parser.error("provide the router ECR image by digest and the 40-character GitOps commit SHA")

    signal.signal(signal.SIGTERM, cancel)
    try:
        verify(args)
    except VerificationFailed as error:
        print(f"Verification failed. {error}", file=sys.stderr)
        return 1
    except ClientError as error:
        operation = error.operation_name
        print(f"Verification failed. AWS {operation} request failed.", file=sys.stderr)
        return 1
    except (BotoCoreError, OSError, ValueError, http.client.HTTPException, subprocess.TimeoutExpired):
        print("Verification failed. A dependency, network connection, or response was unavailable.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Verification was interrupted.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
