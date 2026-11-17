"""Open private EKS and router forwards for local and CI callers."""

import json
import os
import re
import socket
import subprocess
import time
from contextlib import closing, contextmanager
from urllib.parse import urlsplit

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

ACCOUNT = "922763798103"
REGION = "us-west-2"
ROUTER = "inference-router"
LOOPBACK = "127.0.0.1"
FORWARDING = re.compile(r"^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$", re.MULTILINE)
SDK_CONFIG = Config(connect_timeout=5, read_timeout=10, retries={"mode": "standard", "total_max_attempts": 3})


class TunnelError(Exception):
    """A tunnel error safe to print."""


@contextmanager
def background(command, **kwargs):
    with subprocess.Popen(
        command, stdin=subprocess.DEVNULL, stderr=subprocess.STDOUT, start_new_session=True, **kwargs,
    ) as process:
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


def find_session_host(session, cluster_name, vpc_id):
    with closing(session.client("ec2", config=SDK_CONFIG)) as ec2:
        pages = ec2.get_paginator("describe_instances").paginate(Filters=[
            {"Name": "tag:Name", "Values": [f"{cluster_name}-session-host"]},
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ])
        hosts = [
            instance["InstanceId"]
            for page in pages
            for reservation in page["Reservations"]
            for instance in reservation["Instances"]
        ]
    if len(hosts) != 1:
        raise TunnelError(f"Expected one running Session Manager host in the {cluster_name} VPC. Found {len(hosts)}.")
    return hosts[0]


@contextmanager
def private_kubeconfig(directory, region, cluster_name, session_host=None, *, role_arn=None):
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
        raise TunnelError("Expected the active private EKS cluster.")
    endpoint = urlsplit(cluster["endpoint"])
    if endpoint.scheme != "https" or not endpoint.hostname:
        raise TunnelError("EKS returned an invalid HTTPS endpoint.")
    if session_host is None:
        session_host = find_session_host(session, cluster_name, vpc["vpcId"])

    with socket.socket() as address:
        address.bind((LOOPBACK, 0))
        port = address.getsockname()[1]
    path = directory / "kubeconfig"
    path.touch(mode=0o600)
    token_args = ["eks", "get-token", "--cluster-name", cluster_name, "--region", region]
    if role_arn:
        token_args.extend(["--role-arn", role_arn])
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
            "args": token_args,
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


def wait_for_api(kubectl, tunnel):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if tunnel.poll() is not None:
            raise TunnelError("Session Manager exited before the private EKS API was ready.")
        try:
            result = subprocess.run(
                [*kubectl, "--request-timeout=5s", "get", "--raw=/readyz"],
                check=False, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=10,
            )
        except subprocess.TimeoutExpired:
            continue
        if result.returncode == 0:
            return
        if "(Forbidden)" in result.stderr or "(Unauthorized)" in result.stderr:
            raise TunnelError("Kubernetes rejected the request. Check your AWS profile and cluster access.")
        time.sleep(1)
    raise TunnelError("The private EKS API did not become ready within about 60 seconds.")


@contextmanager
def router_service(kubectl, namespace, directory, *, local_port=None):
    output = directory / "forward.log"
    ports = f"{local_port or ''}:8080"
    command = [*kubectl, "-n", namespace, "port-forward", "--address", LOOPBACK, f"service/{ROUTER}", ports]
    # SPDY uses the create verb on pods/portforward.
    with output.open("w") as log, background(
        command, env=dict(os.environ, KUBECTL_PORT_FORWARD_WEBSOCKETS="false"), stdout=log,
    ) as process:
        deadline = time.monotonic() + 30
        while process.poll() is None and time.monotonic() < deadline:
            forwarding = FORWARDING.search(output.read_text())
            if forwarding:
                yield int(forwarding[1]), process
                return
            time.sleep(0.25)
    if local_port is not None and "address already in use" in output.read_text():
        raise TunnelError(f"Local port {local_port} is already in use. Choose another port with --port.")
    raise TunnelError("Could not port-forward the private inference-router Service.")
