"""Exercise the verifier's AWS SDK client lifecycle without contacting AWS."""

import json
import pathlib
import tempfile
from contextlib import contextmanager
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

import boto3
import eks_tunnel


@contextmanager
def no_tunnel(*args, **kwargs):
    yield object()


class PrivateKubeconfigTests(TestCase):
    def test_uses_and_closes_real_sdk_clients(self):
        session = boto3.Session(
            aws_access_key_id="test",
            aws_secret_access_key="test",
            region_name="us-west-2",
        )
        eks, ssm = session.client("eks"), session.client("ssm")
        cluster = "inference-router-dev"
        endpoint = "test.eks.amazonaws.com"
        description = {
            "cluster": {
                "arn": f"arn:aws:eks:us-west-2:922763798103:cluster/{cluster}",
                "status": "ACTIVE",
                "resourcesVpcConfig": {"endpointPublicAccess": False, "endpointPrivateAccess": True},
                "endpoint": f"https://{endpoint}",
                "certificateAuthority": {"data": "test-certificate"},
            },
        }
        session_response = {"SessionId": "test", "StreamUrl": "wss://example.invalid", "TokenValue": "test"}
        clients = {"eks": eks, "ssm": ssm}
        stub_session = SimpleNamespace(client=lambda name, **_: clients[name], profile_name="default")

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(eks_tunnel.boto3, "Session", return_value=stub_session),
            patch.object(eks, "describe_cluster", return_value=description),
            patch.object(eks, "close") as close_eks,
            patch.object(ssm, "start_session", return_value=session_response),
            patch.object(ssm, "terminate_session") as terminate,
            patch.object(ssm, "close") as close_ssm,
            patch.object(eks_tunnel, "background", no_tunnel),
        ):
            with eks_tunnel.private_kubeconfig(pathlib.Path(directory), "us-west-2", cluster, "i-test") as (
                kubectl,
                _,
            ):
                kubeconfig = json.loads(pathlib.Path(kubectl[-1]).read_text())
                self.assertEqual(kubeconfig["clusters"][0]["cluster"]["tls-server-name"], endpoint)
            terminate.assert_called_once_with(SessionId="test")
            close_eks.assert_called_once_with()
            close_ssm.assert_called_once_with()

    def test_waits_for_the_kubernetes_api(self):
        refused = SimpleNamespace(returncode=1, stderr="connection refused")
        ready = SimpleNamespace(returncode=0, stderr="")
        tunnel = SimpleNamespace(poll=lambda: None)

        with (
            patch.object(eks_tunnel.subprocess, "run", side_effect=[refused, ready]) as run,
            patch.object(eks_tunnel.time, "sleep"),
        ):
            eks_tunnel.wait_for_api(["kubectl", "--kubeconfig", "test"], tunnel)

        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.args[0][-2:], ["get", "--raw=/readyz"])
