# Inference router GitOps implementation plan

The [environment matrix](envs.md) defines the original environment roles. This plan makes Dev persistent. GitHub Actions runs application CI and Terraform. Argo CD reconciles router configuration on EKS.

Stage already runs the router on private EKS. Add a persistent Dev cluster and deploy each successful candidate there first. After Dev verification passes, promote the same ECR digest to Stage automatically. After the Stage rollout and smoke tests pass, publish the GitHub release.

## Environment lifecycle

| Environment | Application delivery | Infrastructure and cleanup |
| --- | --- | --- |
| CI runner | Run lint, unit tests, mocked provider tests, and a container smoke test. Use kind for Kubernetes-specific changes. | Run format, validation, and module tests. Run a cloud-backed plan for affected roots only through trusted workflows. The runner and kind cluster are disposable. |
| PR preview / sandbox | Create a preview on request in a temporary namespace on a shared non-production cluster. Use synthetic inputs and test doubles by default. | Use a dedicated sandbox account and isolated state for changes that need real AWS resources. Destroy resources on PR close or test completion. Run a scheduled TTL reconciler for missed cleanup. |
| Dev / integration | Deploy successful candidates from `main` by digest. Verify the deployed image and run smoke tests before promotion. | Run a persistent private EKS cluster with Dev-specific state, identities, and secrets. Apply a saved Dev plan after review. |
| Stage / pre-prod | Promote Dev-verified digests automatically. Publish a GitHub prerelease after Stage verification. | Keep the existing private EKS cluster persistent. Review saved infrastructure plans separately from application releases. |
| Production | Promote the staging-tested digest through a reviewed change. Confirm Argo sync, workload health, and service health. | Review a separate production plan. Use production credentials and state. Rehearse rebuild and restore in an isolated environment. |

Extend CI and Stage with Dev. Keep Dev running between deployments. Add production after the Dev-to-Stage exercise passes. Add preview environments when needed.

## 1. Configure the router for EKS

Add a validated `ROUTER_MODE=eks` setting. In this mode, build only the cloud adapters. Reject a startup configuration that enables demo providers or sets an Ollama endpoint. Keep the existing local and demo modes for developer use and kind.

| Request on EKS | Expected behavior |
| --- | --- |
| `allow_cloud` is false or omitted | Return HTTP 422 with `local_inference_unavailable` before making any provider call. Keep the request default at `false`. |
| Cloud allowed, `simple` or `writing` | Try Claude, then OpenAI if a transient failure leaves time in the request budget. |
| Cloud allowed, `coding` or `reasoning` | Try OpenAI, then Claude under the same fallback policy. |
| Cloud allowed, `auto` | Ask Jev for a task label. If Jev is unavailable or confidence is below the configured threshold, use the `simple` route. |
| No eligible generator | Return HTTP 503 with `providers_unavailable`. Skip disabled providers. |

Keep classification and at most two generation attempts under one deadline. Keep the routing reason and request ID in logs. Exclude prompts, output, and credentials. Make readiness check that the process initialized the required provider configuration. Use a separate synthetic request to verify provider reachability and routing. Keep liveness independent of provider outages.

Require an authenticated caller before exposing the service outside a trusted network. Keep the first EKS release internal. Set an upstream timeout above the router deadline and define an initial concurrency limit before expanding access.

Add tests for EKS startup, missing keys, each route, transient and permanent faults, and the shared deadline. Assert **zero outbound requests** for omitted or false `allow_cloud`, including classification and fallback. Assert that no EKS request constructs or calls the Ollama adapter. Run the existing local and demo tests.

## 2. Define configuration, secrets, and identities

| Location | Configuration or credentials | Consumer |
| --- | --- | --- |
| Git-tracked Kustomize overlays | Image digest, namespace, replicas, resource requests and limits, Service and ingress configuration, probe and rollout tuning | Argo CD |
| Git-tracked ConfigMap | `ROUTER_MODE`, `ROUTER_TIMEOUT_SECONDS`, `PROVIDER_TIMEOUT_SECONDS`, `CLASSIFIER_TIMEOUT_SECONDS`. Add validated model IDs and Jev confidence threshold. Keep the current model IDs and `0.80` as initial defaults. | Router |
| GitHub repository variables | Shared non-sensitive defaults, such as the ECR repository name or artifact region | Trusted GitHub Actions jobs |
| GitHub Environment variables | Target AWS region, ECR location, and the environment's plan, apply, or publish role ARN where applicable | Jobs assigned to that environment |
| GitHub Environment secrets | An optional environment-specific credential for a live CI smoke test. Prefer a credential scoped to the test account and synthetic traffic. | Only the corresponding deploy or test job |
| GitHub Repository secrets | A shared credential only when a trusted workflow has a documented need. Start with an empty set. Use the built-in GitHub token for supported same-repo actions. | Trusted workflows that need the credential |
| AWS Secrets Manager | `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `OPENROUTER_API_KEY` as separate values per environment | EKS runtime, via External Secrets Operator |

Use AWS OIDC with narrowly scoped GitHub Actions roles. Restrict each AWS trust policy to the repo and the protected ref or GitHub Environment used by its job. Separate image publish, Terraform plan, and Terraform apply permissions. Keep AWS access keys out of GitHub secrets.

Create Secrets Manager containers and IAM policy through Terraform. Populate secret values through an authorized AWS operation outside Terraform. Use an environment-scoped External Secrets store and EKS workload identity. Map the resulting Kubernetes Secret keys through `secretKeyRef`. Git and Terraform state contain references only. Confirm that secret namespace and IAM scope match each environment. After secret rotation, roll the pods so the process reads the new environment values.

Verify the private repo's GitHub plan before adding Environment secrets or branch protections. Keep review of Terraform applies separate from automated application promotion. Use the existing saved-plan approval process for infrastructure. [GitHub environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) · [GitHub OIDC on AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws) · [External Secrets with AWS](https://external-secrets.io/latest/provider/aws-secrets-manager/)

## 3. Add GitHub Actions for application CI and publishing

1. Create `.github/workflows/app-ci.yml` for pull requests and `main`. Pin actions to commit SHAs. Enable read-only repository permissions by default.
2. Run lint and `uv run --locked python -m unittest discover -s tests -v`. Add the linter to the project and commit the updated `uv.lock`.
3. Build and smoke-test the container on PRs. Use demo mode or mocked providers and synthetic data. Add kind checks for manifest and rollout changes.
4. Create a build-and-publish job for trusted `main` commits. Build for the EKS node architecture and smoke-test that image. Authenticate through OIDC, then push the tested image to ECR.
5. Record the source SHA, image digest, and CI run as release evidence. Pass the verified digest to the deployment jobs in the same workflow run.
6. Make the GitHub checks required where repository protections support them. Retire CircleCI after GitHub Actions has passed equivalent checks.

Use the same ECR image in Dev and Stage. If the environments use separate repositories, replicate the image and verify the destination digest. Keep previous release images for rollback. Run untrusted PR code with read-only GitHub permissions. [GitHub OIDC on AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)

## 4. Add Terraform and its plan/apply workflows

Use `infra/bootstrap/`, `infra/modules/`, and separate roots under `infra/environments/`. Add `dev` for the private EKS cluster and `dev-gitops` for its controllers and application registration. Reuse the Stage pattern for the Dev VPC, private workers, NAT egress, Session Manager access, and EKS add-ons. Use Dev-specific state keys, GitHub OIDC roles, and Secrets Manager entries. Record the Dev AWS account and region before bootstrap.

Commit non-sensitive infrastructure inputs per root. Include the region, network CIDRs, cluster version, and node sizes and scaling bounds. Pin Terraform, providers, and module versions. Commit provider lockfiles for the runnable roots.

1. Bootstrap encrypted, versioned S3 state and the GitHub OIDC provider and roles through a trusted administrative path. Enable S3 lockfiles and restrict state access. Use a separate state location per environment and a unique state key per temporary sandbox.
2. Define VPC, cluster, node capacity, ECR access, workload identity, and required EKS add-ons. Put the Argo CD bootstrap in a separately ordered step or root. Keep Terraform execution independent of the target cluster.
3. Run `terraform fmt -check -recursive`, initialization without the backend for static checks, `terraform validate`, and module tests. Use mocked providers where practical. Map shared-module changes to all affected roots.
4. Run cloud-backed plans from trusted code with the environment-specific plan role. Show reviewers a safe summary of creates, updates, replacements, and destroys. Avoid exposing sensitive values in comments or logs.
5. After merge, generate a final saved plan for the exact commit and environment. Record the commit, plan run ID, and plan checksum. Keep the full plan in restricted, encrypted storage with short retention. Apply the exact approved plan with the separate apply role. Replan and repeat review after a change to the commit, state, or approved inputs.
6. Serialize applies per environment and keep state locking active. Keep production plan and approval separate from staging. Require explicit review for destructive changes. After apply, check EKS and add-on health.

For private EKS endpoints, give the bootstrap and smoke test jobs a private path to their target cluster. Reuse scoped Session Manager access or a runner with VPC reachability. Give smoke test jobs a separate identity with access to Argo status, rollout status, and the internal router Service.

Use the existing owner-restricted apply workflow and time-limited apply role for AWS infrastructure. Bind approval to the target environment, reviewed commit, and saved plan checksum. Run cluster bootstrap plans through the private access path and apply the reviewed file. [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3) · [Terraform saved plans](https://developer.hashicorp.com/terraform/cli/commands/plan)

## 5. Bootstrap Dev, promote to Stage, and publish the GitHub release

### Bootstrap the Dev deployment

1. Add `deploy/overlays/dev/` beside `deploy/overlays/staging/`. Reuse `deploy/base/` for the router and set `ROUTER_MODE=eks` in both overlays.
2. Install Argo CD in Dev through Terraform. Give it read-only access to the private repo. Scope its AppProject to the Dev namespace.
3. Install External Secrets Operator and its identity through Terraform. Verify that the Dev runtime secret has synced before the first rollout.

### Automate Dev verification and Stage promotion

Use one trusted workflow to carry the source SHA and ECR digest from publication through Dev verification, Stage verification, and release. Trigger candidates from changes to build inputs on `main`. Overlay-only commits are outside those trigger paths. Serialize promotion runs and retain the previous Stage digest for rollback.

1. After the image passes CI and publishes to ECR, update the Dev overlay with its digest. Let Dev Argo CD sync the change.
2. Wait for Dev Argo CD to report `Synced` and `Healthy`. Verify that the Ready pods run the candidate digest. Run the smoke tests against the private Dev Service.
3. After Dev verification passes, update only the Stage image digest. Validate the rendered Stage overlay and verify that the digest matches the Dev evidence. Record the source SHA, workflow run, Dev result, and previous Stage digest in the promotion record.
4. Wait for Stage Argo CD to report `Synced` and `Healthy`. Verify that the rollout has reached the expected digest and that both replicas are Ready. Run the same smoke tests against the private Stage Service.

The smoke tests cover readiness, Claude writing, OpenAI coding and reasoning, Jev auto-classification, and the cloud-disabled `422` response. Record results without provider keys or response text. If Stage verification fails, report the failed check and keep the previous digest available for a Git revert. Verify recovery after Argo CD syncs the revert.

This private repo has GitHub auto-merge disabled and its current plan rejects branch protection. Use a dedicated GitOps job on trusted `main` with job-scoped `contents: write`. Restrict its diff to the target overlay image field. Use a normal fast-forward push and revalidate against the latest base if another push wins. Keep downstream verification in the same workflow because a `GITHUB_TOKEN` push does not start a new push-triggered run. If the repo gains enforceable branch rules, use a repo-scoped GitHub App and an auto-merge PR with required checks. [GitHub workflow triggers](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow) · [Argo CD automated sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)

### Publish the release after Stage verification

1. After Stage verification passes, publish a GitHub **prerelease** tagged `staging-<source-sha>`. Point the tag at the source commit that built the image. Set `prerelease: true`, `draft: false`, and `make_latest: "false"`.
2. Include the full ECR image reference, the Dev and Stage GitOps revisions, and links to the CI and smoke test results. Record the release URL in the workflow summary.
3. Verify the tag and digest when resuming a run. If an identical release already exists, reuse it. If the tag or release points to different evidence, fail the publish job.

Grant `contents: write` to the release job. The job runs only after Stage verification succeeds for the same candidate digest. A failed verification or rollback stops release publication for that candidate. A future production promotion can use the verified Stage digest and its release record. [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#create-a-release)

## 6. Add opt-in previews and sandbox cleanup

Use a trusted workflow to approve preview requests and write a preview entry for an immutable image digest. Build PR code without credentials. Publish its artifact through a trusted job that does not execute the PR code. Let Argo CD create the preview from the protected GitOps configuration.

Use a namespace per PR, resource quotas, network isolation, and synthetic inputs. Keep previews free of credentials by default. Grant preview-only credentials only to reviewed code. Apply the EKS no-Ollama rule to previews that run the real router.

Delete the preview entry on PR close and let the controller prune its resources. Use a scheduled job to reconcile expired entries and report cleanup failures. For temporary AWS resources, use a sandbox role and an isolated state key linked to the PR. Run destroy through the trusted Terraform workflow. Delete or archive state only after confirming the resources are gone.

## Acceptance checks

- An ordinary PR passes app and Terraform checks without provisioning AWS resources.
- With credentials absent, CI tests still run. An EKS request with cloud use disabled returns the specified error before any outbound call.
- Dev and Stage run the same ECR digest. Stage promotion starts automatically only after Dev passes its deployed-digest and smoke tests.
- Stage verification checks Argo CD health, replica readiness, the running digest, and all smoke routes, including the cloud-disabled error.
- A successful Stage deployment creates one GitHub prerelease tied to the source commit and digest. A failed Dev or Stage test prevents publication. A retry reuses an identical release.
- Production uses the staging-tested digest. Its infrastructure apply requires a separately reviewed production plan.
- A staging rollback restores a healthy prior release through Git. An isolated rebuild can start from Terraform state and Git without the target cluster's Argo CD.
- A closed or expired preview leaves no preview namespace. An expired AWS sandbox leaves no temporary resources tracked by its state.

Record the target AWS accounts and region, GitHub protection features, EKS endpoint and runner access, and Argo CD installation choice before provisioning. Select the staging smoke-test identity before deploying the first candidate.
