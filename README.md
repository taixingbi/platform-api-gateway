# platform-edge-gateway

The Bedrock Gateway platform's front door, split out of
`bedrock-runtime-gateway-infra`'s `modules/api_gateway` into its own repo (see
`plan.md` Section 25's repository structure). One HTTP API, one VPC
Link to the private ALB `bedrock-runtime-gateway-infra` manages, and two
routes reaching the same backend under different auth:

```text
ANY /iam/{proxy+}  AWS_IAM   -- SigV4-signed calls
ANY /{proxy+}      NONE      -- Bearer JWT calls, verified by the app itself
```

## Example usage

Base URL is this repo's own `api_endpoint` output (dev:
`https://as1n3q8d33.execute-api.us-east-1.amazonaws.com` — re-check the
output if this has ever been re-applied, since a destroyed/recreated
API Gateway gets a new one).

### `/iam/v1/chat` — AWS_IAM / SigV4

API Gateway verifies the signature itself, so the caller needs real
AWS credentials for a principal mapped in `platform-authz-service`
(`policies/iam_tenants.yaml`, or a provisioned application — see
`bedrock-runtime-gateway-app`'s onboarding workflow). Plain `curl` can't sign
a SigV4 request on its own; the two easiest ways to do it are:

**`awscurl`** (`pip install awscurl`) — closest thing to a literal curl call:

```bash
awscurl --service execute-api --region us-east-1 \
  -X POST https://as1n3q8d33.execute-api.us-east-1.amazonaws.com/iam/v1/chat \
  -H "content-type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hi in one word."}]}'
```

**Python + boto3** (no extra CLI tool, uses whatever credentials are
already active — an assumed role, an env var, etc.):

```python
import boto3, json, requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

url = "https://as1n3q8d33.execute-api.us-east-1.amazonaws.com/iam/v1/chat"
body = json.dumps({"messages": [{"role": "user", "content": "Say hi in one word."}]})

creds = boto3.Session().get_credentials().get_frozen_credentials()
request = AWSRequest(method="POST", url=url, data=body, headers={"content-type": "application/json"})
SigV4Auth(creds, "execute-api", "us-east-1").add_auth(request)

resp = requests.post(url, data=body, headers=dict(request.headers))
print(resp.status_code, resp.json())
```

An unmapped/unknown principal gets `403 UNKNOWN_IAM_PRINCIPAL` from
`platform-authz-service`, not a signature error — the signature itself
is already valid by the time API Gateway forwards the request.

### `/v1/chat` — Bearer JWT

Plain `curl` works here; no request signing needed, just a valid
OIDC-issued token (Cognito, via the portal's login flow) or, for local
testing, a dev-keypair-signed token
(`bedrock-runtime-gateway-app`'s `scripts/generate_dev_token.py`, only usable
where `OIDC_JWKS_URL` is unset):

```bash
curl -s -X POST https://as1n3q8d33.execute-api.us-east-1.amazonaws.com/v1/chat \
  -H "Authorization: Bearer $TOKEN" \
  -H "content-type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hi in one word."}]}'
```

## Edge protection: throttling is real, WAF is not (and can't be, as-is)

The stage has real, configurable throttling (`throttling_rate_limit`/
`throttling_burst_limit` on `aws_apigatewayv2_stage.default`'s
`default_route_settings`) -- an aggregate cap across every tenant
combined, distinct from `TenantPolicy.rpm_limit` (per-tenant, enforced
deep in the app) and from any per-source-IP protection.

AWS WAF was attempted and reverted (see `modules/api_gateway/main.tf`'s
own comment where the resources used to be): `aws_wafv2_web_acl` +
`aws_wafv2_web_acl_association` against this stage's ARN failed at
apply time with `WAFInvalidParameterException`. Confirmed against AWS's
own `AssociateWebACL` API reference, not guessed at -- AWS WAFv2 only
supports associating with API Gateway **REST APIs**, ALB, AppSync,
Cognito user pools, App Runner, Verified Access, Amplify, and Bedrock
AgentCore Gateway. This is an HTTP API (`aws_apigatewayv2_api`), which
isn't on that list. The only real way to put AWS WAF in front of this
API is a CloudFront distribution (CLOUDFRONT-scope WAF) with this
stage as its origin -- the same TLS/domain work as a custom API
domain, itself not built yet (needs a real domain/Route53 zone). Both
are deferred together, not attempted separately -- see `plan.md`
section 35 in the platform root.

## Deliberately loose coupling to bedrock-runtime-gateway-infra

This repo never reads `bedrock-runtime-gateway-infra`'s Terraform state
(no `terraform_remote_state`, no hardcoded resource IDs). It looks up
the existing private ALB by name via a plain `data "aws_lb"` source
and creates its own VPC Link + security group
(`gateway-{env}-api-gw-vpc-link` — deliberately not reusing
`bedrock-runtime-gateway-infra`'s old `gateway-{env}-vpc-link` name, since AWS
enforces unique security group names per VPC and the old one still
existed during this split's cutover). Either repo can be re-applied
independently without needing the other's state file.

For `bedrock-runtime-gateway-infra`'s ALB security group to actually accept
traffic from this VPC Link, its `modules/ecs_service` ingress rule
looks this security group up by name too (`data "aws_security_group"`,
not a cross-state reference) — see that repo's own commit history for
the cutover.

## Why "destroy and recreate", not a state migration

The original `modules/api_gateway` resources in `bedrock-runtime-gateway-infra`
were destroyed and this repo's resources created fresh, rather than
migrating the existing Terraform state across repos
(`terraform state mv`/`import`). That means a new
`api_endpoint` (a new `*.execute-api.*.amazonaws.com` URL) — every
caller (the portal's `GATEWAY_API_URL`, any SigV4 client's endpoint
config) needed updating to match. Simpler to set up than a careful
state migration, at the cost of that one-time URL change.

## The cutover's real gotcha: cross-repo SG destroy ordering

`bedrock-runtime-gateway-infra`'s `modules/ecs_service`'s ALB security group
ingress rule switched from `aws_security_group.vpc_link.id` (an
in-config resource) to `data.aws_security_group.api_gateway_vpc_link`
(a by-name lookup, once the old resource was deleted from that repo's
config entirely). Terraform's dependency graph has no way to know the
old resource and the new data-sourced value are "the same slot" --
they're structurally unrelated in the new config -- so it doesn't
reliably order "update the ALB's rule to the new SG" before "destroy
the now-config-absent old SG". Confirmed live twice: the old SG's
`DeleteSecurityGroup` call spent the full ~15-minute retry window on
`DependencyViolation` and failed the apply both times, because the
ALB's ingress rule still referenced it when the destroy was attempted.

Fixed by hand mid-cutover (revoke the old ingress rule, authorize the
new one, then delete the orphaned SG directly via the EC2 API) rather
than a third blind retry -- confirmed with `terraform plan` afterward
that state matched reality with zero drift. If this split is ever
redone in another account/environment, expect the same failure and
the same fix: don't count on Terraform to sequence a cross-repo
security-group swap correctly in one apply when the old side of it is
being removed from config in the same change.

## CI/CD

Same dev-auto/prod-manual-promotion shape as `bedrock-runtime-gateway-infra`:
push to `main` auto-applies `environments/dev`; `environments/prod` is
a separate `workflow_dispatch` (`promote-prod.yml`) pinned to a commit
SHA that already applied cleanly to dev, gated by a required-reviewer
GitHub Environment.
