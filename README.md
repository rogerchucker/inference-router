# Interview model router

The FastAPI service routes nonstreaming inference to Ollama, Claude, or OpenAI. With cloud access enabled, it can use OpenRouter Jev to classify the request first.

## Run with Ollama

Use Python 3.12, uv, and a running Ollama server with `qwen3.5:4b` installed. From this directory, start the router.

```bash
uv run --locked uvicorn app:app --port 8080
```

In a second terminal, send a local request.

```bash
curl --fail-with-body -sS http://127.0.0.1:8080/v1/infer \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Explain a readiness probe in one sentence.","max_tokens":128}'
```

The response includes the provider, model, answer, token usage, latency, and request ID. The `routing_reason` field reports `local_only`. The local endpoint defaults to `http://127.0.0.1:11434/v1`. `MODEL_BASE_URL` can set a different loopback endpoint.

## Enable cloud routing

Set the keys for the services you use in the environment that starts the router. `OPENROUTER_API_KEY` enables Jev classification. `ANTHROPIC_API_KEY` enables `claude-opus-5-5`, and `OPENAI_API_KEY` enables `gpt-6-astra`. A missing key skips that service.

Send a request with explicit cloud consent. The `auto` task sends the prompt to Jev. Select a specific task to skip classification.

```bash
curl --fail-with-body -sS http://127.0.0.1:8080/v1/infer \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Draft a short incident update for engineers.","allow_cloud":true,"task":"auto"}'
```

| Request | First choice | Fallback |
| --- | --- | --- |
| `allow_cloud: false` (default) | Ollama | — |
| `simple` with cloud enabled | Ollama | Claude |
| `writing` with cloud enabled | Claude | OpenAI |
| `coding` or `reasoning` with cloud enabled | OpenAI | Claude |
| `auto` with cloud enabled | Jev chooses a task, then the router follows its row | Same fallback as the selected task |

The `auto` task defaults to `simple` if Jev is unavailable, returns an invalid response, or reports confidence below 0.80. The router uses at most two generation attempts. It tries the fallback after a timeout, HTTP 429, a transport error, or HTTP 5xx. Requests without an eligible provider return 503.

The default request deadline is 60 seconds. Each generation attempt gets up to 25 seconds. The classifier gets up to 2 seconds. All stages share the request deadline. Override these values with `ROUTER_TIMEOUT_SECONDS`, `PROVIDER_TIMEOUT_SECONDS`, and `CLASSIFIER_TIMEOUT_SECONDS`.

The default `max_tokens` is 1,024, with a limit of 4,096. Reasoning models can use part of that budget before they produce visible text.

- `app.py` configures provider credentials and maps failures to HTTP status codes.
- `router.py` selects providers and enforces the request deadline.
- `providers.py` normalizes completion results and calls Jev's Decisions API.
- The request ID connects routing and attempt logs. The logs omit prompts, answers, and keys.

The `attempts` field counts generation attempts. Latency includes classification. Usage describes the successful generator response, and cost estimates come from the demo provider rates. A timed-out request can still incur upstream charges. [Jev Decisions API](https://openrouter.ai/blog/insights/what-is-jev/) · [Claude Messages API](https://platform.claude.com/docs/en/api/messages/create) · [OpenAI model](https://developers.openai.com/api/docs/models/gpt-6-astra)

## Run in EKS mode

Set `ROUTER_MODE=eks` and supply the enabled cloud providers' credentials through the environment. Leave `MODEL_BASE_URL` and `DEMO_PRIMARY_FAULT` unset. EKS mode creates no Ollama adapter.

With `allow_cloud` omitted or set to `false`, inference returns HTTP 422 with `local_inference_unavailable` before any outbound request. With cloud use enabled, simple and writing tasks try Claude then OpenAI. Coding and reasoning tasks try OpenAI then Claude. `auto` uses Jev. If classification is unavailable or uncertain, the router uses the simple route.

## Run the deterministic demo and tests

For the interview demo, start the service with simulated providers. Send the same local request shown above.

```bash
DEMO_PRIMARY_FAULT=none uv run --locked uvicorn app:app --port 8080
```

The response reports `primary` and one attempt. To demonstrate failover, restart with `DEMO_PRIMARY_FAULT=timeout`. The response reports `backup` and two attempts.

Run the tests from this directory.

```bash
uv run --locked ruff check .
uv run --locked python -m unittest discover -s tests -v
```

The [GitHub Actions workflow](.github/workflows/app-ci.yml) runs lint, tests, and Docker smoke checks on pull requests and pushes to `main`. The smoke checks exercise demo and EKS modes without cloud credentials.

The `PYTHON_VERSION` and `UV_VERSION` defaults in the [Dockerfile](Dockerfile) set the toolchain for both App CI and the container build.

When a delivery script changes how it opens or closes an SDK client, test with the pinned SDK client and stub the network calls. A mock can accept a `with` block that the real client rejects. The [EKS verifier regression test](.github/scripts/test_verify_eks.py) exercises client cleanup and Session Manager termination without AWS credentials.

The verifier roles [scope StartSession](infra/environments/promotion-access/access.tf) to one host and one port-forwarding document per environment. Use the hosted verification run to check the role against the real API. IAM simulation alone cannot tell which condition keys Systems Manager supplies during the instance check.

## Forward the Dev or Stage router

Use `uv`, the AWS CLI, the Session Manager plugin, and `kubectl` with your AWS login. Run one command per environment from the repository:

```bash
uv run --script .github/scripts/forward-router.py dev
uv run --script .github/scripts/forward-router.py staging
```

Dev listens on `127.0.0.1:8081` and Stage listens on `127.0.0.1:8082`. Use `--port` to choose another local port. The script finds the session host in the selected cluster's VPC and waits for the Kubernetes API before it forwards the router Service.

Keep the command running and test the printed URL from another terminal. Press `Ctrl+C` to close both forwards. The script uses a temporary kubeconfig and preserves TLS verification.

## Practice a Kubernetes rollback

Run this drill with Docker, kind, and kubectl. The commands target a local cluster named `kind-router-lab`. The CircleCI workflow runs tests, builds a commit-tagged image, smoke-tests it, and saves the tested image as an artifact. The local lab builds its own image.

A published container port can accept a connection before the app responds. The CircleCI smoke test retries the readiness request with a bounded budget. Can the workflow pass from a cold start, including when the first connection returns an empty response?

```bash
kind create cluster --name router-lab
docker build -t model-router:lab-v1 .
kind load docker-image --name router-lab model-router:lab-v1
kubectl --context kind-router-lab apply -f k8s/router.yaml
kubectl --context kind-router-lab rollout status deployment/model-router --timeout=100s
kubectl --context kind-router-lab port-forward service/model-router 8080:8080
```

If the local demo still uses port 8080, stop it before you run the port-forward command. Send the demo request from another terminal.

Set the demo fault to an invalid value to simulate a release with bad configuration. In the terminal that issued the request, run these commands.

```bash
kubectl --context kind-router-lab set env deployment/model-router DEMO_PRIMARY_FAULT=bad-value
kubectl --context kind-router-lab get pods -l app=model-router --sort-by=.metadata.creationTimestamp
kubectl --context kind-router-lab describe deployment/model-router
kubectl --context kind-router-lab logs -l app=model-router -c router --prefix --tail=30
```

Look for the startup error from the newest pod. If its log is empty, run the log command again after the container starts. To inspect a prior restart, copy the failing pod name from the `NAME` column, then enter it at the prompt.

```bash
printf 'Failing pod name: '
read -r pod_name
kubectl --context kind-router-lab logs "$pod_name" -c router --previous
```

The `--previous` flag requires a prior instance of the container in that pod. After you diagnose the error, reapply the known-good manifest from this directory. It sets `DEMO_PRIMARY_FAULT` back to `none`.

```bash
kubectl --context kind-router-lab apply -f k8s/router.yaml
kubectl --context kind-router-lab rollout status deployment/model-router --timeout=100s
```

The invalid value prevents startup. With surge capacity, the rolling update keeps the old ready replicas available while the new rollout stalls. The progress deadline reports failure. If the rollback removes the pod used for port forwarding, restart the port-forward command. [kubectl logs](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/) · [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) · [Probe behavior](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

If you already ran `kubectl rollout undo`, use `rollout status` to check recovery. The warning refers to the saved configuration that client-side `apply` uses to calculate patches. Reapplying the known-good manifest records that configuration. [Declarative configuration](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/)

In a GitOps release, revert the configuration in Git so that the controller reconciles the rollback. An imperative rollback alone leaves Git's desired state in place.

After the drill, delete the local cluster.

```bash
kind delete cluster --name router-lab
```
