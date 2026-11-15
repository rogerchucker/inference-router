"""Exercise the verifier's AWS SDK client lifecycle without contacting AWS."""

import importlib.util
import json
import pathlib
import tempfile
from contextlib import contextmanager
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

import boto3

spec = importlib.util.spec_from_file_location("verify_eks", pathlib.Path(__file__).with_name("verify-eks.py"))
verify_eks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_eks)


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
            patch.object(verify_eks.boto3, "Session", return_value=stub_session),
            patch.object(eks, "describe_cluster", return_value=description),
            patch.object(eks, "close") as close_eks,
            patch.object(ssm, "start_session", return_value=session_response),
            patch.object(ssm, "terminate_session") as terminate,
            patch.object(ssm, "close") as close_ssm,
            patch.object(verify_eks, "background", no_tunnel),
        ):
            with verify_eks.private_kubeconfig(pathlib.Path(directory), "us-west-2", cluster, "i-test") as (
                kubectl,
                _,
            ):
                kubeconfig = json.loads(pathlib.Path(kubectl[-1]).read_text())
                self.assertEqual(kubeconfig["clusters"][0]["cluster"]["tls-server-name"], endpoint)
            terminate.assert_called_once_with(SessionId="test")
            close_eks.assert_called_once_with()
            close_ssm.assert_called_once_with()
