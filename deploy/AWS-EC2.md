# Deploy the demo to AWS EC2

The current CI workflow deploys through SSH. See [SSH deployment](SSH-EC2.md).
The OIDC, ECR, and SSM instructions below describe the alternative deployment
using `scripts/deploy-ec2.py`, which the current workflow does not invoke.

This deploys the six dummy services in `docker-compose.yml`, not the original
production application. Infrastructure must exist before running the pipeline.
The workflow does not create or terminate EC2 instances or create IAM roles.

## 1. Prepare EC2

Use an x86_64 Linux instance in your chosen region: the pipeline builds amd64
images. Install Docker Engine with Compose v2 (supporting `up --wait`), AWS CLI
v2, Python 3, Bash and `flock`. Enable Docker and the SSM Agent at boot.
The SSM agent runs deployment commands as root.

Attach an EC2 instance profile with `AmazonSSMManagedInstanceCore` and ECR pull
permissions (`ecr:GetAuthorizationToken` on `*`; `ecr:BatchGetImage`,
`ecr:GetDownloadUrlForLayer` and `ecr:BatchCheckLayerAvailability` scoped to the
six `vanika-demo/*` repositories). Do not put AWS access keys on the server.
Verify the instance appears **Online** in Systems Manager's managed nodes.
The host needs outbound HTTPS connectivity to SSM, ECR and ECR's S3 layers,
using internet/NAT access or the corresponding VPC endpoints.

All application ports remain bound to loopback, matching local Compose.
To publish the demo, configure a TLS reverse proxy on the host pointing to
`127.0.0.1:18080`, with security-group ingress for HTTPS. Internal service ports
should stay private. Without a reverse proxy, inspect it through SSM port
forwarding to port 18080. No inbound SSH is needed by this deployment.

## 2. Create ECR repositories

Run once using your administrator's AWS CLI session (choose your actual region):

```bash
export AWS_REGION=ap-south-1
for service in frontend gateway-service srm-service ai-proxy sim-worker ubuntu-sandbox; do
  aws ecr create-repository --region "$AWS_REGION" \
    --repository-name "vanika-demo/$service" \
    --image-scanning-configuration scanOnPush=true
 done
```

Skip repositories that already exist. Tags remain mutable so a rerun of the same
commit can publish again; deployments reference the full commit SHA. Configure
ECR lifecycle rules to retain the revisions you need for rollback.

## 3. Configure GitHub OIDC

In IAM, add the GitHub OIDC provider `https://token.actions.githubusercontent.com`
with audience `sts.amazonaws.com`. Create a deployment role that trusts that
provider through `sts:AssumeRoleWithWebIdentity`. Restrict its trust conditions to:

- `token.actions.githubusercontent.com:aud`: `sts.amazonaws.com`
- `token.actions.githubusercontent.com:sub`: `repo:dRajkumard/vanika:ref:refs/heads/main`

Use your actual repository owner and name if different. This workflow does not
use a GitHub Environment, so use the branch subject above.

Grant that role these permissions, scoped to your account and region:

- `ecr:GetAuthorizationToken` on `*`.
- `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`,
  `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`,
  `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` on the six ECR repositories.
- `ssm:SendCommand` on your exact EC2 instance ARN and
  `arn:aws:ssm:<region>::document/AWS-RunShellScript`.
- `ssm:GetCommandInvocation` on `*` (this API does not support resource scoping).

See the [official GitHub OIDC setup](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
and [AWS Run Command walkthrough](https://docs.aws.amazon.com/systems-manager/latest/userguide/walkthrough-cli.html).

## 4. Configure repository variables

GitHub repository → Settings → Secrets and variables → Actions → **Variables**
(or **Secrets**, if you already store these values there). The workflow accepts
either, with a nonempty Variable taking precedence over a Secret of the same name:

| Name | Example |
| --- | --- |
| `AWS_REGION` | `ap-south-1` |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/vanika-github-deploy` |
| `EC2_INSTANCE_ID` | `i-0123456789abcdef0` |

No static AWS access-key secrets or SonarQube settings are needed.
Commit and push to `main`. Tests, secret scan, builds and stack smoke tests must
all pass before publishing; all six publications must pass before deployment.

## Updates and failures

The deployment writes release files to `/opt/vanika-demo/releases/<commit-sha>`.
A host lock prevents simultaneous updates. It pulls all images before updating
containers, waits for Docker health checks, and runs the HTTP smoke script.
`/opt/vanika-demo/current.json` points to the last revision whose checks passed.
SSM command IDs and final output appear in Actions logs. If Actions times out,
inspect that command in Systems Manager before starting another deployment.

This is a single-host rolling Compose update with possible downtime. A failed
update can leave some containers on the new revision; rollback is manual.
On the EC2 host, restore the last successful revision with:

```bash
cd /opt/vanika-demo
# Refresh ECR login first if necessary, using the EC2 instance role.
docker compose -p vanikaai-demo -f current.json up -d --no-build --wait
```

If the first deployment fails there is no successful `current.json` yet: fix the
reported error and rerun the pipeline. Images and release files are retained;
monitor ECR storage and host disk space.
