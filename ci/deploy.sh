#!/usr/bin/env bash
# Deploy PulseWatch to one environment (namespace) of the EKS cluster.
#
#   ci/deploy.sh <staging|production>
#
# Required env: APP_IMAGE, CLUSTER_NAME, AWS_REGION and AWS credentials
#               (in GitLab CI these come from OIDC, see .aws_oidc in .gitlab-ci.yml).
# Optional env: CI_DEPLOY_USER / CI_DEPLOY_PASSWORD - GitLab deploy token used as
#               the image pull secret when the container registry is private.
#
# Steps:
#   1. get a kubeconfig for the cluster
#   2. apply cluster-wide platform objects (IngressClass for ALBs)
#   3. refresh the registry pull secret
#   4. render the Kustomize overlay with the immutable, commit-tagged image
#   5. run the database migration Job and wait for it to succeed
#   6. roll out web + worker; roll back automatically if they don't become ready
#   7. write the public URL to deploy.env (smoke test + GitLab environment link)
set -euo pipefail

ENVIRONMENT="${1:?usage: $0 <staging|production>}"
: "${APP_IMAGE:?APP_IMAGE is not set}"
: "${CLUSTER_NAME:?CLUSTER_NAME is not set}"
: "${AWS_REGION:?AWS_REGION is not set}"

NAMESPACE="pulsewatch-${ENVIRONMENT}"
OVERLAY="k8s/overlays/${ENVIRONMENT}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
MIGRATION_TIMEOUT_SECONDS="${MIGRATION_TIMEOUT_SECONDS:-300}"
DEPLOYMENTS=(pulsewatch-web pulsewatch-worker)

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
kc() { kubectl --namespace "$NAMESPACE" "$@"; }

wait_for_job() {
  local job="$1" deadline=$((SECONDS + $2)) conditions
  while ((SECONDS < deadline)); do
    conditions="$(kc get job "$job" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}')"
    case "$conditions" in
      *Complete*) return 0 ;;
      *Failed*) return 1 ;;
    esac
    sleep 5
  done
  echo "Timed out after $2s waiting for job/$job"
  return 1
}

rollback() {
  local name
  for name in "${DEPLOYMENTS[@]}"; do
    kc rollout undo "deployment/$name" || echo "No previous revision of $name to roll back to."
  done
}

[[ -d "$OVERLAY" ]] || fail "unknown environment '$ENVIRONMENT' (no $OVERLAY directory)"

# 1 ---------------------------------------------------------------------------
log "Connecting to EKS cluster '$CLUSTER_NAME' in $AWS_REGION"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME"
kubectl get namespace "$NAMESPACE" -o name \
  || fail "namespace $NAMESPACE not found - run the terraform:apply job first"
kc get secret pulsewatch-app -o name \
  || fail "secret pulsewatch-app not found in $NAMESPACE - run the terraform:apply job first"

# 2 ---------------------------------------------------------------------------
log "Applying cluster-wide platform resources"
kubectl apply -k k8s/platform

# 3 ---------------------------------------------------------------------------
if [[ -n "${CI_DEPLOY_USER:-}" && -n "${CI_DEPLOY_PASSWORD:-}" ]]; then
  log "Refreshing image pull secret for ${CI_REGISTRY:?}"
  kc create secret docker-registry gitlab-registry \
    --docker-server="$CI_REGISTRY" \
    --docker-username="$CI_DEPLOY_USER" \
    --docker-password="$CI_DEPLOY_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "No GitLab deploy token (CI_DEPLOY_USER) available - assuming the registry is public."
fi

# 4 ---------------------------------------------------------------------------
log "Rendering $OVERLAY with image $APP_IMAGE"
(cd "$OVERLAY" && kustomize edit set image "pulsewatch=${APP_IMAGE}")
kustomize build "$OVERLAY" >"$RENDERED"

# 5 ---------------------------------------------------------------------------
log "Running the database migration Job"
kc apply -f "$RENDERED" -l app.kubernetes.io/component=shared
# Job specs are immutable, so the previous run is replaced rather than updated.
kc delete job pulsewatch-migrate --ignore-not-found --wait=true
kc apply -f "$RENDERED" -l app.kubernetes.io/component=migration
if ! wait_for_job pulsewatch-migrate "$MIGRATION_TIMEOUT_SECONDS"; then
  kc logs job/pulsewatch-migrate --all-containers --tail=200 || true
  fail "database migration failed - the running version was left untouched"
fi

# 6 ---------------------------------------------------------------------------
log "Rolling out the application"
kc apply -f "$RENDERED" -l 'app.kubernetes.io/component!=migration'
for deployment in "${DEPLOYMENTS[@]}"; do
  if ! kc rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"; then
    kc get pods -l app.kubernetes.io/name=pulsewatch -o wide || true
    kc describe "deployment/$deployment" | tail -n 25 || true
    log "Rollout failed - rolling back to the previous release"
    rollback
    fail "deployment/$deployment did not become ready within $ROLLOUT_TIMEOUT"
  fi
done

# 7 ---------------------------------------------------------------------------
log "Waiting for the load balancer address"
host=""
for _ in $(seq 1 60); do
  host="$(kc get ingress pulsewatch-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  [[ -n "$host" ]] && break
  sleep 5
done
[[ -n "$host" ]] || fail "Ingress has no load balancer address yet (kubectl -n $NAMESPACE describe ingress pulsewatch-web)"

echo "APP_URL=http://${host}" >deploy.env
kc get deployments,hpa,ingress -o wide
log "Deployed $APP_IMAGE to $ENVIRONMENT: http://${host}"
