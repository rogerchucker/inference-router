# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["boto3==1.44.3", "botocore==1.44.3"]
# ///
"""Forward a private Dev or Stage router to localhost."""

import argparse
import shutil
import signal
import sys
import tempfile
import time
from pathlib import Path

from botocore.exceptions import BotoCoreError, ClientError
from eks_tunnel import (
    ACCOUNT,
    LOOPBACK,
    REGION,
    ROUTER,
    TunnelError,
    private_kubeconfig,
    router_service,
    wait_for_api,
)

PORTS = {"dev": 8081, "staging": 8082}


def forward(environment, port):
    for executable in ("aws", "session-manager-plugin", "kubectl"):
        if not shutil.which(executable):
            raise TunnelError(f"Install {executable} and put it on PATH.")

    cluster = f"{ROUTER}-{environment}"
    role_arn = f"arn:aws:iam::{ACCOUNT}:role/{cluster}-cluster-admin"
    with tempfile.TemporaryDirectory(prefix=f"router-{environment}-") as workspace:
        directory = Path(workspace)
        print(f"Waiting for the private EKS API for {cluster}...", flush=True)
        with private_kubeconfig(directory, REGION, cluster, role_arn=role_arn) as (kubectl, tunnel):
            wait_for_api(kubectl, tunnel)
            with router_service(kubectl, cluster, directory, local_port=port) as (bound_port, service):
                print(f"{cluster} is available at http://{LOOPBACK}:{bound_port}. Press Ctrl+C to stop.", flush=True)
                while tunnel.poll() is None and service.poll() is None:
                    time.sleep(0.25)
                raise TunnelError("A forward exited. Run the command again to reconnect.")


def stop(_signal, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", choices=PORTS)
    parser.add_argument("--port", type=int, help="Override the local router port (Dev 8081, Stage 8082).")
    args = parser.parse_args()
    port = args.port if args.port is not None else PORTS[args.environment]
    if not 1 <= port <= 65535:
        parser.error("--port must be between 1 and 65535")

    signal.signal(signal.SIGTERM, stop)
    try:
        forward(args.environment, port)
    except KeyboardInterrupt:
        return 0
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code", "unknown")
        print(f"AWS {error.operation_name} failed ({code}). Check your AWS session and permissions.", file=sys.stderr)
    except BotoCoreError:
        print("Could not connect to AWS. Check your AWS credentials and network.", file=sys.stderr)
    except (TunnelError, OSError) as error:
        print(f"Forward failed. {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
