#!/bin/bash
# AutoShift Installation Script
# Deploys AutoShift via ArgoCD Application

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    echo "Usage: $0 [OPTIONS] [VALUES_FILE]"
    echo ""
    echo "Arguments:"
    echo "  VALUES_FILE    Values profile to use: hub, minimal, sbx, hubofhubs (default: hub)"
    echo ""
    echo "Options:"
    echo "  --versioned    Enable versioned ClusterSets for gradual rollout"
    echo "                 - Application name includes version (e.g., autoshift-0-0-1)"
    echo "                 - ClusterSet names include version suffix (e.g., hub-0-0-1)"
    echo "                 - Allows multiple versions to run side-by-side"
    echo "  --dry-run      Enable dry run mode (policies report but don't enforce)"
    echo "  --name NAME    Custom application name (default: autoshift or autoshift-VERSION)"
    echo "  --gitops-namespace NS  GitOps namespace (default: openshift-gitops)"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 hub                                    # Standard deployment"
    echo "  $0 --versioned hub                        # Versioned deployment for gradual rollout"
    echo "  $0 --dry-run hub                          # Dry run mode"
    echo "  $0 --versioned --dry-run                  # Versioned + dry run"
    echo "  $0 --gitops-namespace custom-gitops hub   # Custom GitOps namespace"
    exit 0
}

VERSION="0.0.4"
REGISTRY="quay.io"
REGISTRY_NAMESPACE="autoshift"
OCI_REPO="oci://${REGISTRY}/${REGISTRY_NAMESPACE}"
OCI_REGISTRY="${REGISTRY}/${REGISTRY_NAMESPACE}"

# Parse arguments
VERSIONED=false
DRY_RUN=true
CUSTOM_NAME=""
VALUES_FILE="hub"
GITOPS_NAMESPACE="openshift-gitops"

while [[ $# -gt 0 ]]; do
    case $1 in
        --versioned)
            VERSIONED=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --name)
            CUSTOM_NAME="$2"
            shift 2
            ;;
        --gitops-namespace)
            GITOPS_NAMESPACE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            VALUES_FILE="$1"
            shift
            ;;
    esac
done

# Sanitize version for DNS-compatible names (dots -> dashes)
VERSION_SUFFIX=$(echo "${VERSION}" | tr '.' '-' | tr '/' '-' | tr '[:upper:]' '[:lower:]')

# Determine application name
if [ -n "$CUSTOM_NAME" ]; then
    APP_NAME="$CUSTOM_NAME"
elif [ "$VERSIONED" = true ]; then
    APP_NAME="autoshift-${VERSION_SUFFIX}"
else
    APP_NAME="autoshift"
fi

log "AutoShift Installation"
log "======================"
log "Version: ${VERSION}"
log "Registry: ${OCI_REPO}"
log "Values: ${VALUES_FILE}"
log "Application: ${APP_NAME}"
[ "$VERSIONED" = true ] && log "Mode: Versioned ClusterSets (gradual rollout)"
[ "$DRY_RUN" = true ] && log "Mode: Dry Run (policies won't enforce)"
echo ""

# Check prerequisites
command -v oc >/dev/null 2>&1 || error "oc CLI is required"

# Check cluster connection
oc whoami >/dev/null 2>&1 || error "Not logged in to OpenShift. Run: oc login"

# Map values file names to composable values files
case "$VALUES_FILE" in
    hub)
        VALUES_FILE_PATHS=("values/global.yaml" "values/clustersets/hub.yaml" "values/clustersets/managed.yaml")
        ;;
    minimal|min)
        VALUES_FILE_PATHS=("values/global.yaml" "values/clustersets/hub-minimal.yaml")
        ;;
    sbx|sandbox)
        VALUES_FILE_PATHS=("values/global.yaml" "values/clustersets/sbx.yaml")
        ;;
    hubofhubs|hoh)
        VALUES_FILE_PATHS=("values/global.yaml" "values/clustersets/hubofhubs.yaml" "values/clustersets/hub1.yaml" "values/clustersets/hub2.yaml")
        ;;
    *)
        error "Unknown values file: $VALUES_FILE. Use: hub, minimal, sbx, or hubofhubs"
        ;;
esac

# Build values override
VALUES_OVERRIDE="# Enable OCI registry mode for ApplicationSet
        autoshiftOciRegistry: true
        autoshiftOciRepo: ${OCI_REPO}/policies
        autoshiftOciVersion: \"${VERSION}\"
        gitopsNamespace: ${GITOPS_NAMESPACE}"

if [ "$VERSIONED" = true ]; then
    VALUES_OVERRIDE="${VALUES_OVERRIDE}
        # Enable versioned ClusterSets for gradual rollout
        versionedClusterSets: true"
fi

if [ "$DRY_RUN" = true ]; then
    VALUES_OVERRIDE="${VALUES_OVERRIDE}
        # Dry run mode - policies report but don't enforce
        autoshift:
          dryRun: true"
fi

# Build valueFiles YAML entries
VALUEFILES_YAML=""
for f in "${VALUES_FILE_PATHS[@]}"; do
    VALUEFILES_YAML="${VALUEFILES_YAML}        - ${f}
"
done

log "Creating ArgoCD Application for AutoShift..."

cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${GITOPS_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${OCI_REGISTRY}
    chart: autoshift
    targetRevision: "${VERSION}"
    helm:
      valueFiles:
${VALUEFILES_YAML}      values: |
        ${VALUES_OVERRIDE}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${GITOPS_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

log "✓ AutoShift Application created"
echo ""

log "Monitoring sync status..."
sleep 5
oc get application ${APP_NAME} -n ${GITOPS_NAMESPACE}

echo ""
log "========================================="
log "AutoShift installation initiated!"
log "========================================="
echo ""
log "Monitor deployment:"
echo "  oc get application ${APP_NAME} -n ${GITOPS_NAMESPACE} -w"
echo "  oc get applicationset -n ${GITOPS_NAMESPACE}"
echo "  oc get applications -n ${GITOPS_NAMESPACE} | grep ${APP_NAME}"
echo ""
log "View policies:"
echo "  oc get policies -A"

if [ "$VERSIONED" = true ]; then
    echo ""
    log "Versioned ClusterSets created:"
    echo "  Hub ClusterSet: hub-${VERSION_SUFFIX}"
    echo "  Managed ClusterSet: managed-${VERSION_SUFFIX}"
    echo ""
    log "Assign clusters to this version:"
    echo "  oc label managedcluster <cluster-name> cluster.open-cluster-management.io/clusterset=hub-${VERSION_SUFFIX} --overwrite"
fi

echo ""
log "Access ArgoCD UI:"
echo "  oc get route argocd-server -n ${GITOPS_NAMESPACE}"
