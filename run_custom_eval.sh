#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Multi-SWE-bench Custom Dataset Evaluation Runner
#
# Supports: ECR images, local Dockerfiles, pass@k runs
# Output:   eval_outputs/<instance_id>/<model>/run_<N>/...
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup handler for graceful shutdown
# ─────────────────────────────────────────────────────────────────────────────
CONTAINERS_TO_CLEANUP=()
cleanup_on_exit() {
    local exit_code=$?
    # Disable exit on error during cleanup
    set +e
    
    if [[ ${#CONTAINERS_TO_CLEANUP[@]} -gt 0 ]]; then
        echo "[CLEANUP] Stopping tracked containers..."
        for container_id in "${CONTAINERS_TO_CLEANUP[@]}"; do
            if docker ps -q --filter "id=$container_id" | grep -q .; then
                docker stop "$container_id" 2>/dev/null || true
            fi
        done
    fi
    
    # Only kill orphaned agent-server containers if no OTHER eval sessions are running.
    # This prevents one dataset's exit from nuking another dataset's containers.
    local other_eval_count
    other_eval_count=$(pgrep -cf "run_custom_eval.sh" 2>/dev/null || echo "0")
    # Subtract 1 for ourselves (this process is still counted by pgrep)
    other_eval_count=$((other_eval_count - 1))
    if [[ "$other_eval_count" -le 0 ]]; then
        echo "[CLEANUP] No other eval sessions — cleaning orphaned agent-server containers..."
        docker ps -q --filter "name=agent-server-" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
    else
        echo "[CLEANUP] $other_eval_count other eval session(s) running — skipping global agent-server cleanup."
    fi
    
    exit $exit_code
}
trap cleanup_on_exit EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Startup: Kill orphaned agent-server containers from previous sessions.
# ─────────────────────────────────────────────────────────────────────────────
_cleanup_orphaned_containers() {
    # Skip if SKIP_ORPHAN_CLEANUP=1 (used when another harness is running concurrently)
    if [[ "${SKIP_ORPHAN_CLEANUP:-0}" == "1" ]]; then
        echo "[STARTUP] SKIP_ORPHAN_CLEANUP=1 — skipping container cleanup."
        return 0
    fi
    set +e
    local orphan_count=0
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        docker rm -f "$cid" >/dev/null 2>&1 || true
        orphan_count=$((orphan_count + 1))
    done < <(docker ps -q --filter "name=agent-server-" 2>/dev/null || true)
    [[ $orphan_count -gt 0 ]] && echo "[STARTUP] Removed $orphan_count orphaned agent-server containers."
    set -e
}
_cleanup_orphaned_containers

# ─────────────────────────────────────────────────────────────────────────────
# Reap dead containers: remove exited/dead agent-server containers.
# Safe to call while other workers are running — only removes stopped ones.
# ─────────────────────────────────────────────────────────────────────────────
_reap_dead_containers() {
    local reaped=0
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        docker rm -f "$cid" >/dev/null 2>&1 || true
        reaped=$((reaped + 1))
    done < <(docker ps -a -q --filter "name=agent-server-" --filter "status=dead" 2>/dev/null || true)
    [[ $reaped -gt 0 ]] && log "[REAP] Removed $reaped dead containers."
}

# ── Defaults ─────────────────────────────────────────────────────────────────
K=1
LANG="rust"
LLM_CONFIG=""
DATASET=""
SPLIT="train"
MAX_ITER=1000
NUM_WORKERS=1
MAX_RETRIES=3
CONVERSATION_TIMEOUT=3600
WORKSPACE="docker"
OUTPUT_BASE="${SCRIPT_DIR}/eval_outputs"
SELECT_FILE=""
N_LIMIT=0
START_RUN=1
SKIP_INFER=false
SKIP_EVAL=false
SKIP_SUMMARY=false
DOCKERFILE=""
ECR_PREFIX=""
IMAGE_TAG=""
DATASET_TAG=""
DOCKER_BUILD_ONLY=false

# ─────────────────────────────────────────────────────────────────────────────
# Validation helper functions
# ─────────────────────────────────────────────────────────────────────────────
validate_positive_int() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]]; then
        echo "ERROR: $name must be a positive integer, got: '$value'"
        exit 1
    fi
}

validate_non_negative_int() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $name must be a non-negative integer, got: '$value'"
        exit 1
    fi
}

usage() {
    cat <<'EOF'
Usage: run_custom_eval.sh [OPTIONS]

Complete evaluation runner for custom datasets with Docker/ECR support.

Required:
  --llm-config PATH        Path to LLM JSON config
  --dataset PATH            Path to task instances JSONL file

Image Source (optional -- pulls from Docker Hub if none given):
  --dockerfile PATH         Build image from a local Dockerfile
  --ecr-prefix PREFIX       Use ECR images (e.g. <account>.dkr.ecr.<region>.amazonaws.com/repo)
  --image-tag TAG           Override image tag (default: pr-{number} from dataset)

Language & Dataset:
  --lang LANG               Language: rust, cpp, java, python, go, c  [default: rust]
  --split SPLIT             Dataset split                              [default: train]
  --dataset-tag NAME        Short name for output dir (default: {org}__{repo}-{number})

Runs:
  -k, --num-runs N          Number of independent runs (pass@k)        [default: 1]
  --start-run N             Resume from run N                          [default: 1]

Inference:
  --max-iter N              Max agent iterations per instance           [default: 1000]
  --num-workers N           Parallel inference workers                  [default: 1]
                            WARNING: High values (>20) may cause resource exhaustion
  --max-retries N           Max retries for crashed instances            [default: 3]
  --workspace TYPE          docker or remote                           [default: docker]
  --select FILE             File with instance IDs to select
  --n-limit N               Limit instances (0 = all)                   [default: 0]

Output:
  --output-dir PATH         Base output directory                      [default: ./eval_outputs]

Skip Stages:
  --skip-infer              Skip inference, only run evaluation
  --skip-eval               Skip evaluation, only run inference
  --skip-summary            Skip final pass@k summary
  --docker-build-only       Only build Docker image, then exit

Examples:
  # Rust eval with local Dockerfile
  ./run_custom_eval.sh \
    --llm-config .llm_config/claude.json \
    --dataset benchmarks/multiswebench/data/task_instances_rust.jsonl \
    --dockerfile clap-rs_clap-691ef58dfb7d8f0fcdfd12dd09df3a38d9e95d47.Dockerfile \
    --lang rust

  # pass@8 with ECR (use 8 workers for stability)
  ./run_custom_eval.sh \
    --llm-config .llm_config/claude.json \
    --dataset benchmarks/multiswebench/data/task_instances_rust.jsonl \
    --ecr-prefix <account>.dkr.ecr.<region>.amazonaws.com/repo \
    --lang rust -k 8 --num-workers 8

  # Resume from run 3
  ./run_custom_eval.sh \
    --llm-config .llm_config/claude.json \
    --dataset benchmarks/multiswebench/data/task_instances_rust.jsonl \
    --dockerfile clap-rs_clap-691ef58dfb7d8f0fcdfd12dd09df3a38d9e95d47.Dockerfile \
    --lang rust -k 8 --start-run 3

EOF
    exit 1
}

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --llm-config)       LLM_CONFIG="$2";       shift 2 ;;
        --dataset)          DATASET="$2";           shift 2 ;;
        --lang)             LANG="$2";              shift 2 ;;
        --split)            SPLIT="$2";             shift 2 ;;
        --dataset-tag)      DATASET_TAG="$2";       shift 2 ;;
        -k|--num-runs)      K="$2";                shift 2 ;;
        --start-run)        START_RUN="$2";         shift 2 ;;
        --max-iter)         MAX_ITER="$2";          shift 2 ;;
        --conversation-timeout) CONVERSATION_TIMEOUT="$2"; shift 2 ;;
        --num-workers)      NUM_WORKERS="$2";       shift 2 ;;
        --max-retries)      MAX_RETRIES="$2";       shift 2 ;;
        --workspace)        WORKSPACE="$2";         shift 2 ;;
        --select)           SELECT_FILE="$2";       shift 2 ;;
        --n-limit)          N_LIMIT="$2";           shift 2 ;;
        --output-dir)       OUTPUT_BASE="$2";       shift 2 ;;
        --dockerfile)       DOCKERFILE="$2";        shift 2 ;;
        --ecr-prefix)       ECR_PREFIX="$2";        shift 2 ;;
        --image-tag)        IMAGE_TAG="$2";         shift 2 ;;
        --skip-infer)       SKIP_INFER=true;        shift ;;
        --skip-eval)        SKIP_EVAL=true;         shift ;;
        --skip-summary)     SKIP_SUMMARY=true;      shift ;;
        --docker-build-only) DOCKER_BUILD_ONLY=true; shift ;;
        -h|--help)          usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ -z "$LLM_CONFIG" ]]; then echo "ERROR: --llm-config is required"; usage; fi
if [[ ! -f "$LLM_CONFIG" ]]; then echo "ERROR: LLM config not found: $LLM_CONFIG"; exit 1; fi
if [[ -z "$DATASET" ]]; then echo "ERROR: --dataset is required"; usage; fi
if [[ ! -f "$DATASET" ]]; then echo "ERROR: Dataset file not found: $DATASET"; exit 1; fi
if [[ -n "$DOCKERFILE" && ! -f "$DOCKERFILE" ]]; then
    echo "ERROR: Dockerfile not found: $DOCKERFILE"; exit 1
fi

# Validate numeric arguments
validate_positive_int "--num-runs (-k)" "$K"
validate_positive_int "--start-run" "$START_RUN"
validate_positive_int "--max-iter" "$MAX_ITER"
validate_positive_int "--num-workers" "$NUM_WORKERS"
validate_non_negative_int "--max-retries" "$MAX_RETRIES"
validate_non_negative_int "--n-limit" "$N_LIMIT"

# Warn about high worker counts
if [[ "$NUM_WORKERS" -gt 100 ]]; then
    echo "WARNING: High worker count ($NUM_WORKERS) may cause resource exhaustion."
    echo "         Consider using --num-workers 8-16 for stability."
    echo "         Continuing in 5 seconds... (Ctrl+C to abort)"
    sleep 5
fi

# ── Resolve paths ────────────────────────────────────────────────────────────
DATASET="$(cd "$(dirname "$DATASET")" && pwd)/$(basename "$DATASET")"
LLM_CONFIG="$(cd "$(dirname "$LLM_CONFIG")" && pwd)/$(basename "$LLM_CONFIG")"
[[ -n "$DOCKERFILE" ]] && DOCKERFILE="$(cd "$(dirname "$DOCKERFILE")" && pwd)/$(basename "$DOCKERFILE")"

# ── Extract model name ───────────────────────────────────────────────────────
# Use environment variables to avoid command injection from paths with special characters
MODEL_NAME=$(LLM_CONFIG_PATH="$LLM_CONFIG" python3 -c "
import json, re, os
config_path = os.environ['LLM_CONFIG_PATH']
cfg = json.load(open(config_path))
# Check both 'model' and 'model_canonical_name' for known model families
for field in ('model', 'model_canonical_name'):
    text = cfg.get(field, '')
    m = re.search(r'(claude[^:]*|gpt[^:]*|gemini[^:]*|llama[^:]*)', text)
    if m:
        print(m.group(1))
        break
else:
    print(cfg['model'].split('/')[-1])
" 2>/dev/null || echo "model")

case "$MODEL_NAME" in
    *claude*)  MODEL_SHORT="claude" ;;
    *gpt*)     MODEL_SHORT="gpt" ;;
    *gemini*)  MODEL_SHORT="gemini" ;;
    *llama*)   MODEL_SHORT="llama" ;;
    *)         MODEL_SHORT="$MODEL_NAME" ;;
esac

# ── Parse dataset to extract instance info ───────────────────────────────────
# Use environment variables to avoid command injection from paths with special characters
read -r DS_ORG DS_REPO DS_NUMBER DS_BASE_SHA <<< "$(DATASET_PATH="$DATASET" python3 -c "
import json, os
dataset_path = os.environ['DATASET_PATH']
with open(dataset_path) as f:
    d = json.loads(f.readline())
    print(d.get('org',''), d.get('repo',''), d.get('number',''), d.get('base',{}).get('sha',''))
")"

EXPECTED_IMAGE_TAG="${IMAGE_TAG:-pr-${DS_NUMBER}}"
DS_ORG_LC="${DS_ORG,,}"
DS_REPO_LC="${DS_REPO,,}"
if [[ -z "$DATASET_TAG" ]]; then
    DATASET_TAG="${DS_ORG}__${DS_REPO}-${DS_NUMBER}"
fi

# Directory layout: eval_outputs/<instance_id>/<model>/run_<N>/
RUN_BASE="${OUTPUT_BASE}/${DATASET_TAG}/${MODEL_SHORT}"
SUMMARY_FILE="${RUN_BASE}/pass_at_${K}_summary.json"
LOG_FILE="${RUN_BASE}/runner.log"
mkdir -p "$RUN_BASE"

# ── Shared repo pre-clone (avoids redundant per-run clones) ──────────────────
# Extracts all unique org/repo pairs from the dataset and clones each one.
SHARED_REPOS_DIR="${OUTPUT_BASE}/.shared_repos"
mkdir -p "$SHARED_REPOS_DIR"

while IFS='/' read -r _clone_org _clone_repo; do
    [[ -z "$_clone_org" || -z "$_clone_repo" ]] && continue
    _clone_path="${SHARED_REPOS_DIR}/${_clone_org}/${_clone_repo}"
    if [ ! -d "$_clone_path/.git" ]; then
        mkdir -p "$(dirname "$_clone_path")"
        echo "Pre-cloning shared repo: ${_clone_org}/${_clone_repo}..."
        git clone "https://github.com/${_clone_org}/${_clone_repo}.git" "$_clone_path" || \
            echo "WARNING: Failed to clone ${_clone_org}/${_clone_repo}"
    fi
done < <(DATASET_PATH="$DATASET" python3 -c "
import json, os
repos = set()
with open(os.environ['DATASET_PATH']) as f:
    for line in f:
        d = json.loads(line)
        repos.add(f\"{d['org']}/{d['repo']}\")
for r in sorted(repos):
    print(r)
")

# ── Logging ──────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log "═══════════════════════════════════════════════════════════════"
log "  Multi-SWE-bench Custom Eval Runner"
log "═══════════════════════════════════════════════════════════════"
log "Dataset     : $DATASET"
log "Instance ID : $DATASET_TAG"
log "Language    : $LANG"
log "Model       : $MODEL_SHORT ($MODEL_NAME)"
log "Instance    : ${DS_ORG}/${DS_REPO}#${DS_NUMBER} (${DS_BASE_SHA:0:12})"
log "Runs        : $START_RUN -> $K"
log "Max iter    : $MAX_ITER"
log "Conv timeout: $CONVERSATION_TIMEOUT"
log "Workers     : $NUM_WORKERS"
log "Workspace   : $WORKSPACE"
log "Output base : $RUN_BASE"
if [[ -n "$DOCKERFILE" ]]; then
    log "Image src   : Dockerfile ($DOCKERFILE)"
fi
if [[ -n "$ECR_PREFIX" ]]; then
    log "Image src   : ECR ($ECR_PREFIX)"
fi
log "Image tag   : $EXPECTED_IMAGE_TAG"
log "═══════════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────────────
# Apply patches to multi-swe-bench (for old commit handling in Go repos)
# ─────────────────────────────────────────────────────────────────────────────
PATCH_SCRIPT="${SCRIPT_DIR}/patches/patch_multi_swe_bench.py"
if [[ -f "$PATCH_SCRIPT" ]]; then
    log "Applying multi-swe-bench patches..."
    if uv run python "$PATCH_SCRIPT" >> "$LOG_FILE" 2>&1; then
        log "Patches applied successfully."
    else
        log "WARNING: Patch script failed. Continuing anyway..."
    fi
fi

IMAGE_ARCH="arm64"
export DOCKER_PLATFORM="linux/${IMAGE_ARCH}"
export DOCKER_DEFAULT_PLATFORM="linux/${IMAGE_ARCH}"
log "Set DOCKER_PLATFORM=$DOCKER_PLATFORM DOCKER_DEFAULT_PLATFORM=$DOCKER_DEFAULT_PLATFORM (hard-coded arm64)"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0: Build / Tag Docker Image
# ─────────────────────────────────────────────────────────────────────────────
# The harness expects: {EVAL_DOCKER_IMAGE_PREFIX}/{org}_m_{repo}:{tag}
# e.g. mswebench/clap-rs_m_clap:pr-570

EARLY_INSTANCE_COUNT=$(wc -l < "$DATASET")
IS_MULTI_INSTANCE=false
if [[ "$EARLY_INSTANCE_COUNT" -gt 1 ]]; then
    IS_MULTI_INSTANCE=true
fi

HARNESS_IMAGE_NAME="mswebench/${DS_ORG_LC}_m_${DS_REPO_LC}:${EXPECTED_IMAGE_TAG}"

build_or_tag_image() {
    log "── Phase 0: Docker Image Setup ──"
    log "Harness expects image: $HARNESS_IMAGE_NAME"

    if [[ -n "$ECR_PREFIX" ]]; then
        ECR_IMAGE="${ECR_PREFIX}/${DS_ORG_LC}_m_${DS_REPO_LC}:${EXPECTED_IMAGE_TAG}"
        log "Attempting ECR pull: $ECR_IMAGE"

        local _ecr_err
        if _ecr_err=$(docker pull --platform linux/arm64 "$ECR_IMAGE" 2>&1); then
            log "ECR pull successful"
            docker tag "$ECR_IMAGE" "$HARNESS_IMAGE_NAME"
            log "Tagged as: $HARNESS_IMAGE_NAME"

            # Post-pull architecture validation
            PULLED_ARCH=$(docker image inspect "$HARNESS_IMAGE_NAME" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
            if [[ "$PULLED_ARCH" != "arm64" && "$PULLED_ARCH" != "aarch64" ]]; then
                log "WARNING: Pulled image architecture is '$PULLED_ARCH', expected arm64 — removing and falling back"
                docker rmi "$HARNESS_IMAGE_NAME" "$ECR_IMAGE" 2>/dev/null || true
            else
                log "Architecture validated: $PULLED_ARCH"
                # Also tag as envagent/ so the eval harness skips building bare images
                local ENVAGENT_IMAGE_NAME="envagent/${DS_ORG_LC}_m_${DS_REPO_LC}:${EXPECTED_IMAGE_TAG}"
                docker tag "$ECR_IMAGE" "$ENVAGENT_IMAGE_NAME"
                log "Tagged as: $ENVAGENT_IMAGE_NAME"
                export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
                return 0
            fi
        else
            log "WARNING: ECR pull failed for $ECR_IMAGE"
            log "  Docker error: ${_ecr_err}"
            if [[ -n "$DOCKERFILE" ]]; then
                log "Falling back to Dockerfile build..."
            else
                log "Falling back to Docker Hub pull..."
            fi
        fi
    fi

    if [[ -n "$DOCKERFILE" ]]; then
        log "Building image from Dockerfile: $DOCKERFILE"
        log "Target image: $HARNESS_IMAGE_NAME"

        local build_log="${RUN_BASE}/docker_build.log"
        # Use Dockerfile's directory as build context to avoid sending entire SCRIPT_DIR
        local dockerfile_dir
        dockerfile_dir="$(dirname "$DOCKERFILE")"
        log "Build context: $dockerfile_dir"
        
        if docker build \
            -f "$DOCKERFILE" \
            -t "$HARNESS_IMAGE_NAME" \
            --platform "linux/arm64" \
            --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$dockerfile_dir" 2>&1 | tee "$build_log"; then
            log "Docker build successful: $HARNESS_IMAGE_NAME"
            export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
            return 0
        else
            log "ERROR: Docker build failed. See $build_log"
            log "Falling back to Docker Hub pull..."
        fi
    fi

    # Final fallback: pull directly from Docker Hub (enforce arm64 platform)
    log "Attempting Docker Hub pull: $HARNESS_IMAGE_NAME (platform linux/arm64)"
    local _hub_err
    if _hub_err=$(docker pull --platform linux/arm64 "$HARNESS_IMAGE_NAME" 2>&1); then
        local HUB_ARCH
        HUB_ARCH=$(docker image inspect "$HARNESS_IMAGE_NAME" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
        if [[ "$HUB_ARCH" != "arm64" && "$HUB_ARCH" != "aarch64" ]]; then
            log "WARNING: Docker Hub image architecture is '$HUB_ARCH', expected arm64 — removing"
            docker rmi "$HARNESS_IMAGE_NAME" 2>/dev/null || true
        else
            log "Docker Hub pull successful: $HARNESS_IMAGE_NAME (arch: $HUB_ARCH)"
            export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
            return 0
        fi
    else
        log "ERROR: Docker Hub pull also failed for $HARNESS_IMAGE_NAME"
        log "  Docker error: ${_hub_err}"
    fi

    log "ERROR: No image source available (ECR, Dockerfile, and Docker Hub all failed)"
    return 1
}

# Check if image already exists locally — validate architecture if cached
if docker image inspect "$HARNESS_IMAGE_NAME" >/dev/null 2>&1; then
    EXISTING_ARCH=$(docker image inspect "$HARNESS_IMAGE_NAME" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
    if [[ "$EXISTING_ARCH" != "arm64" && "$EXISTING_ARCH" != "aarch64" ]]; then
        log "Cached image $HARNESS_IMAGE_NAME has architecture '$EXISTING_ARCH' (expected arm64) — removing"
        docker rmi "$HARNESS_IMAGE_NAME" 2>/dev/null || true
        if ! build_or_tag_image; then
            if [[ "$IS_MULTI_INSTANCE" == true ]]; then
                log "WARNING: Could not obtain Docker image for first instance after removing wrong-arch cache — multi-instance pre-pull will retry all instances individually"
            else
                log "FATAL: Could not obtain Docker image after removing wrong-arch cache"
                exit 1
            fi
        fi
    else
        log "Image already exists locally: $HARNESS_IMAGE_NAME (arch: $EXISTING_ARCH)"
        log "Skipping build/pull (delete image to force rebuild)"
        export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
    fi
else
    if ! build_or_tag_image; then
        if [[ "$IS_MULTI_INSTANCE" == true ]]; then
            log "WARNING: Could not obtain Docker image for first instance — multi-instance pre-pull will retry all instances individually"
        else
            log "FATAL: Could not obtain Docker image"
            exit 1
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Pre-build the agent-server image so the harness can skip its own build.
#
# The harness calls `docker buildx build` to layer the agent-server on top of
# our BASE_IMAGE. With docker-container buildx drivers (e.g. velora-multiarch),
# buildkit runs in isolation and cannot see local images. Rather than fighting
# Docker's builder/context model, we pre-build the image here using a builder
# that CAN see local images, then tell the harness to skip via env var.
# ─────────────────────────────────────────────────────────────────────────────
SDK_SHORT_SHA=$(cd "$SCRIPT_DIR/vendor/software-agent-sdk" && git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
CUSTOM_TAG="${DS_ORG_LC}_m_${DS_REPO_LC}-${EXPECTED_IMAGE_TAG}"
AGENT_SERVER_IMAGE="ghcr.io/openhands/eval-agent-server:${SDK_SHORT_SHA}-${CUSTOM_TAG}-source-minimal"

if docker image inspect "$AGENT_SERVER_IMAGE" >/dev/null 2>&1; then
    log "Agent-server image already exists: $AGENT_SERVER_IMAGE"
    log "Skipping pre-build"
elif [[ "$IS_MULTI_INSTANCE" == true ]]; then
    log "Multi-instance mode: skipping Phase 0 agent-server pre-build for first instance"
    log "Multi-instance pre-build will handle all instances individually"
else
    log "Pre-building agent-server image: $AGENT_SERVER_IMAGE"
    log "Base image: $HARNESS_IMAGE_NAME"

    DOCKER_CONTEXT=$(docker context show 2>/dev/null || echo "default")
    AGENT_DOCKERFILE="$SCRIPT_DIR/vendor/software-agent-sdk/openhands-agent-server/openhands/agent_server/docker/Dockerfile"
    AGENT_SDK_ROOT="$SCRIPT_DIR/vendor/software-agent-sdk"

    if [[ ! -f "$AGENT_DOCKERFILE" ]]; then
        log "ERROR: Agent-server Dockerfile not found: $AGENT_DOCKERFILE"
        exit 1
    fi

    LITELLM_PATCH="$SCRIPT_DIR/patches/patch_litellm_vertex_express.py"
    if [[ -f "$LITELLM_PATCH" ]] && ! grep -q "patch_litellm_vertex_express" "$AGENT_DOCKERFILE"; then
        cp "$LITELLM_PATCH" "$AGENT_SDK_ROOT/patch_litellm_vertex_express.py"
        sed -i '/uv sync --frozen --no-editable/a COPY --chown=${USERNAME}:${USERNAME} patch_litellm_vertex_express.py /tmp/\nRUN /agent-server/.venv/bin/python /tmp/patch_litellm_vertex_express.py >/dev/null 2>\&1 \&\& rm /tmp/patch_litellm_vertex_express.py' "$AGENT_DOCKERFILE"
    fi

    # Always fix file permissions inside the base image so the openhands user
    # (UID 10001) can read all testbed files.  Base images may have restrictive
    # permissions on build artifacts (e.g. Cargo .lock files with mode 600),
    # and the testbed may live at /testbed, /home/<project>, or /app.
    BASE_IMAGE_USER=$(docker image inspect "$HARNESS_IMAGE_NAME" --format '{{.Config.User}}' 2>/dev/null || echo "")
    log "Base image user: '${BASE_IMAGE_USER:-root (default)}'; patching Dockerfile to fix testbed permissions"
    PATCHED_DOCKERFILE=$(mktemp /tmp/agent-server-Dockerfile.XXXXXX)
    awk '
    /^FROM \$\{BASE_IMAGE\} AS base-image-minimal/ {
        print; print "USER root"; in_minimal=1; next
    }
    in_minimal && /^USER \$\{USERNAME\}/ {
        print "RUN chmod -R a+rX /home/ /testbed/ /app/ 2>/dev/null || true"
        in_minimal=0
    }
    {print}
    ' "$AGENT_DOCKERFILE" > "$PATCHED_DOCKERFILE"
    AGENT_DOCKERFILE="$PATCHED_DOCKERFILE"

    PREBUILD_LOG="${RUN_BASE}/agent_server_build.log"
    # Hard-coded arm64 platform
    PREBUILD_ARCH="arm64"
    log "Building with BUILDX_BUILDER=$DOCKER_CONTEXT (docker driver), platform=linux/${PREBUILD_ARCH}..."

    # When building for arm64, use the ECR URL with platform to get arm64 base image
    if [[ "$PREBUILD_ARCH" == "arm64" && -n "$ECR_PREFIX" ]]; then
        BUILD_BASE_IMAGE="${ECR_PREFIX}/${DS_ORG_LC}_m_${DS_REPO_LC}:${EXPECTED_IMAGE_TAG}"
    else
        BUILD_BASE_IMAGE="$HARNESS_IMAGE_NAME"
    fi

    _prebuild_ok=false
    for _prebuild_try in 1 2 3; do
        if BUILDX_BUILDER="$DOCKER_CONTEXT" docker buildx build \
            --file "$AGENT_DOCKERFILE" \
            --target source-minimal \
            --build-arg "BASE_IMAGE=$BUILD_BASE_IMAGE" \
            --platform "linux/${PREBUILD_ARCH}" \
            --load \
            --tag "$AGENT_SERVER_IMAGE" \
            --build-arg BUILDKIT_INLINE_CACHE=1 \
            "$AGENT_SDK_ROOT" 2>&1 | tee "$PREBUILD_LOG"; then
            log "Agent-server image built successfully: $AGENT_SERVER_IMAGE (attempt ${_prebuild_try})"
            _prebuild_ok=true
            break
        else
            log "WARNING: Agent-server pre-build failed (attempt ${_prebuild_try}/3)"
            if [[ $_prebuild_try -lt 3 ]]; then
                log "Resetting BuildKit and retrying in $((${_prebuild_try} * 10))s..."
                docker buildx prune --all --force >/dev/null 2>&1 || true
                docker buildx inspect --bootstrap >/dev/null 2>&1 || true
                sleep $((${_prebuild_try} * 10))
            fi
        fi
    done
    if [[ "$_prebuild_ok" != true ]]; then
        log "ERROR: Agent-server pre-build failed after 3 attempts. See $PREBUILD_LOG"
        [[ -n "$PATCHED_DOCKERFILE" ]] && rm -f "$PATCHED_DOCKERFILE"
        exit 1
    fi

    [[ -n "$PATCHED_DOCKERFILE" ]] && rm -f "$PATCHED_DOCKERFILE"
fi

# Tell the Python harness to skip its own docker buildx build for the agent-server
# image.  Phase 0 above already built/confirmed it locally.  The harness's
# image_exists() only checks the *remote* registry (ghcr.io), so it would
# incorrectly try to rebuild via `docker buildx build --platform linux/amd64`,
# which fails because buildx cannot resolve the locally-tagged base image.
export MULTI_SWE_BENCH_SKIP_BUILD=1

if [[ "$DOCKER_BUILD_ONLY" == true ]]; then
    log "Docker build complete (--docker-build-only). Exiting."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Ensure dataset is in the standard data directory
# ─────────────────────────────────────────────────────────────────────────────
DATA_DIR="${SCRIPT_DIR}/benchmarks/multiswebench/data"
mkdir -p "$DATA_DIR"
DS_BASENAME="$(basename "$DATASET")"
CANONICAL_DATASET="${DATA_DIR}/${DS_BASENAME}"
if [[ "$DATASET" != "$CANONICAL_DATASET" ]]; then
    cp -f "$DATASET" "$CANONICAL_DATASET"
    log "Dataset copied to: $CANONICAL_DATASET"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build fix_patch_run_cmd based on language
# ─────────────────────────────────────────────────────────────────────────────
build_fix_cmd() {
    local lang="$1"
    local repo="${2:-}"
    case "$lang" in
        java)
            cat <<'CMD'
bash -c "apt-get update ; apt-get install -y patch ; sed -i -e 's|^if.*git.*apply.*|patch --batch --fuzz=5 -p1 -i /home/test.patch ; patch --batch --fuzz=5 -p1 -i /home/fix.patch|' -e '/echo.*git apply/d' -e '/^[[:space:]]*exit 1/d' -e '/^fi$/d' /home/fix-run.sh ; OLD_VER=$(sed -n 's/^old_version=//p' /home/prepare.sh | tr -d '\"') ; NEW_VER=$(sed -n 's/^new_version=//p' /home/prepare.sh | tr -d '\"') ; RELEASE_VER=$(echo $OLD_VER | sed 's/-SNAPSHOT//') ; if [ -n \"$NEW_VER\" ] && [ -n \"$RELEASE_VER\" ]; then find /home -name pom.xml -exec sed -i \"s/$NEW_VER/$RELEASE_VER/g\" {} + ; fi ; find /root/.m2/repository -name *.lastUpdated -delete 2>/dev/null ; find /root/.m2/repository -name _remote.repositories -delete 2>/dev/null ; find /root/.m2/repository -name resolver-status.properties -delete 2>/dev/null ; sed -i 's@mvn @mvn -U -Dsurefire.timeout=120 @g' /home/fix-run.sh ; chmod +x /home/*.sh ; /home/fix-run.sh"
CMD
            ;;
        *)
            # Repos whose harness fix-run.sh already uses fault-tolerant `patch`
            # commands natively don't need the sed override. Return empty string
            # so the built-in fix-run.sh is used as-is.
            case "$repo" in
                strapi)
                    echo ""
                    ;;
                *)
                    cat <<'CMD'
bash -c "apt-get update ; apt-get install -y patch ; sed -i -e 's|^if.*git.*apply.*|patch --batch --fuzz=5 -p1 -i /home/test.patch ; patch --batch --fuzz=5 -p1 -i /home/fix.patch|' -e 's|^git apply.*|patch --batch --fuzz=5 -p1 -i /home/test.patch ; patch --batch --fuzz=5 -p1 -i /home/fix.patch|' -e 's|^set -e|set +e|' -e '/echo.*git apply/d' -e '/^[[:space:]]*exit 1/d' -e '/^fi$/d' /home/fix-run.sh ; if grep -q 'make check' /home/fix-run.sh 2>/dev/null; then sed -i 's|make check -j \([0-9]*\)|make -C src -j \1|g; s|make check|make -C src|g' /home/fix-run.sh ; sed -i \"s|patch --batch --fuzz=5 -p1 -i /home/test.patch|patch --batch --fuzz=5 -p1 -i /home/test.patch --exclude='*.cpp' --exclude='*.h' --exclude='*.c'|g\" /home/fix-run.sh ; fi ; if command -v node >/dev/null 2>&1 && [ -f /home/*/package.json ]; then cd /home/*/ 2>/dev/null ; if [ -d node_modules/esm ]; then sed -i 's|\"tap |\"tap --no-esm |g' package.json 2>/dev/null ; fi ; if ! ls node_modules/.bin/tap >/dev/null 2>&1; then npm install --ignore-scripts --legacy-peer-deps 2>/dev/null ; fi ; cd / ; fi ; if command -v python3 >/dev/null 2>&1 && ! python3 -m pytest --version >/dev/null 2>&1; then pip install pytest 2>/dev/null || pip3 install pytest 2>/dev/null || true ; fi ; chmod +x /home/*.sh ; /home/fix-run.sh"
CMD
                    ;;
            esac
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-validate shared repository for eval image building
# Ensures the shared clone exists, is clean, and has all remote commits.
# Must run ONCE before dispatching eval workers to prevent clone races.
# ─────────────────────────────────────────────────────────────────────────────
pre_validate_shared_repo() {
    local shared_repo_dir="${OUTPUT_BASE}/.shared_repos"

    log "[pre-validate] Ensuring all shared repos are ready..."

    # Iterate over every unique org/repo in the dataset
    while IFS='/' read -r _pv_org _pv_repo; do
        [[ -z "$_pv_org" || -z "$_pv_repo" ]] && continue
        local repo_path="${shared_repo_dir}/${_pv_org}/${_pv_repo}"

        if [[ -d "${repo_path}/.git" ]]; then
            log "[pre-validate] Cleaning ${_pv_org}/${_pv_repo}..."
            git -C "$repo_path" reset --hard HEAD >/dev/null 2>&1 || true
            git -C "$repo_path" clean -fd >/dev/null 2>&1 || true

            # Pre-fetch all refs so every PR base commit is locally available.
            # Prevents concurrent check_commit_hashes() from racing to fetch.
            log "[pre-validate] Fetching all refs for ${_pv_org}/${_pv_repo}..."
            git -C "$repo_path" fetch --all --quiet 2>/dev/null || true
        else
            log "[pre-validate] Cloning missing repo: ${_pv_org}/${_pv_repo}..."
            mkdir -p "$(dirname "$repo_path")"
            git clone "https://github.com/${_pv_org}/${_pv_repo}.git" "$repo_path" || \
                log "[pre-validate] WARNING: Failed to clone ${_pv_org}/${_pv_repo}"
        fi
    done < <(DATASET_PATH="$CANONICAL_DATASET" python3 -c "
import json, os
repos = set()
with open(os.environ['DATASET_PATH']) as f:
    for line in f:
        d = json.loads(line)
        repos.add(f\"{d['org']}/{d['repo']}\")
for r in sorted(repos):
    print(r)
")

    log "[pre-validate] All shared repos ready."
}

# ─────────────────────────────────────────────────────────────────────────────
# Generate eval config.json for a run
# ─────────────────────────────────────────────────────────────────────────────
generate_eval_config() {
    local run_dir="$1"
    local output_jsonl="$2"
    local dataset_file="$3"
    local ds_repo
    ds_repo=$(DATASET_PATH="$dataset_file" python3 -c "import json,os; print(json.loads(open(os.environ['DATASET_PATH']).readline()).get('repo',''))" 2>/dev/null || echo "")
    local fix_cmd
    fix_cmd=$(build_fix_cmd "$LANG" "$ds_repo")
    local converted="${run_dir}/output_converted.jsonl"

    cd "$SCRIPT_DIR"
    # Use environment variables to avoid command injection
    INPUT_JSONL="$output_jsonl" OUTPUT_CONVERTED="$converted" \
    uv run python -c "
import os
from benchmarks.multiswebench.scripts.eval.convert import convert_to_eval_format
convert_to_eval_format(os.environ['INPUT_JSONL'], os.environ['OUTPUT_CONVERTED'])
"

    mkdir -p "${run_dir}/eval_files/dataset"
    mkdir -p "${run_dir}/eval_files/workdir"
    mkdir -p "${run_dir}/eval_files/repos"
    mkdir -p "${run_dir}/eval_files/logs"

    # Use environment variables to avoid command injection from paths
    EVAL_RUN_DIR="$run_dir" \
    EVAL_CONVERTED="$converted" \
    EVAL_DATASET="$dataset_file" \
    EVAL_FIX_CMD="$fix_cmd" \
    EVAL_OUTPUT_BASE="$OUTPUT_BASE" \
    python3 -c "
import json, os

run_dir = os.environ['EVAL_RUN_DIR']
converted = os.environ['EVAL_CONVERTED']
dataset_file = os.environ['EVAL_DATASET']
fix_cmd = os.environ['EVAL_FIX_CMD']
output_base = os.environ['EVAL_OUTPUT_BASE']

config = {
    'mode': 'evaluation',
    'workdir': f'{run_dir}/eval_files/workdir',
    'patch_files': [converted],
    'dataset_files': [dataset_file],
    'force_build': False,
    'output_dir': f'{run_dir}/eval_files/dataset',
    'specifics': [],
    'skips': [],
    'repo_dir': f'{output_base}/.shared_repos',
    'need_clone': False,
    'global_env': [],
    'clear_env': True,
    'stop_on_error': False,
    'max_workers': 8,
    'max_workers_build_image': 8,
    'max_workers_run_instance': 8,
    'log_dir': f'{run_dir}/eval_files/logs',
    'log_level': 'DEBUG',
    'fix_patch_run_cmd': fix_cmd,
}
with open(f'{run_dir}/config.json', 'w') as f:
    json.dump(config, f, indent=4)
"
}

# ─────────────────────────────────────────────────────────────────────────────
# RUN LOOP
#
# Single-instance dataset  → original behaviour (num-workers parallelises
#                             retries/attempts within the one instance).
# Multi-instance dataset   → per-instance output dirs:
#                               eval_outputs/<instance_id>/<model>/run_<N>/
#                             NUM_WORKERS controls how many instances run in
#                             parallel; each run_infer call uses --num-workers 1.
# ─────────────────────────────────────────────────────────────────────────────
FAILED_RUNS=0
SUCCESSFUL_RUNS=0

# Count instances in the canonical dataset
INSTANCE_COUNT=$(wc -l < "$CANONICAL_DATASET")
log "Dataset contains $INSTANCE_COUNT instance(s)."

# DEPRECATED: kept for backward compat — called as fallback by _flatten_official_output_dir
# ── Helper: find best nested output.jsonl, validate JSON, copy to top-level ──
_copy_best_output_jsonl() {
    local run_dir="$1"
    local dest="$2"
    local inst_id="${3:-?}"
    local run_num="${4:-?}"

    # Find non-empty nested output.jsonl; prefer eval_outputs__ paths over __home__ paths
    local best=""
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if [[ "$candidate" != *"/__home__"* ]]; then
            best="$candidate"
            break
        fi
    done < <(find "$run_dir" -mindepth 2 -name "output.jsonl" \
        -not -path "*/eval_files/*" -size +0c 2>/dev/null | sort)

    # Fallback to __home__ paths if no new-convention path found
    if [[ -z "$best" ]]; then
        best=$(find "$run_dir" -mindepth 2 -name "output.jsonl" \
            -not -path "*/eval_files/*" -size +0c 2>/dev/null | sort | head -1 || true)
    fi

    [[ -z "$best" ]] && return 1

    # Validate: must contain at least one valid JSON line
    if ! python3 -c "
import json, sys
count = 0
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if line.strip():
                json.loads(line.strip())
                count += 1
    sys.exit(0 if count > 0 else 1)
except Exception:
    sys.exit(1)
" "$best" 2>/dev/null; then
        return 1
    fi

    cp "$best" "$dest" 2>/dev/null || return 1
    return 0
}

_flatten_official_output_dir() {
    local run_dir="$1"
    local inst_id="${2:-}"
    local run_num="${3:-}"
    local label="[${inst_id:-?}][Run ${run_num:-?}]"

    # Check for nested structure FIRST — it is authoritative (from current run).
    # Only skip flattening if there is no nested structure at all.
    local nested_meta
    nested_meta=$(find "$run_dir" -name "metadata.json" \
        -not -path "*/eval_files/*" -mindepth 2 2>/dev/null | head -1)

    if [[ -z "$nested_meta" ]]; then
        # No nested structure — either already flat or incomplete run.
        if [[ -f "${run_dir}/metadata.json" ]]; then
            return 0
        fi
        _copy_best_output_jsonl "$run_dir" "${run_dir}/output.jsonl" "$inst_id" "$run_num" || true
        return 0
    fi

    local nested_dir
    nested_dir=$(dirname "$nested_meta")
    log "${label} Flattening official output: $(basename "$nested_dir") → run level"

    # Ensure all pending writes are flushed before moving files.
    sync

    # Use force-overwrite (not -n) so fresh output replaces stale files
    # left behind by previously killed/failed runs.
    for item in "$nested_dir"/*; do
        [[ -e "$item" ]] || continue
        local base_name
        base_name=$(basename "$item")

        if [[ -d "$item" && -d "${run_dir}/${base_name}" ]]; then
            cp -a "$item"/. "${run_dir}/${base_name}/" 2>/dev/null || true
            rm -rf "$item"
        else
            if ! mv -f "$item" "${run_dir}/" 2>/dev/null; then
                # Retry once after a short delay (race with file finalisation)
                sleep 1
                if ! mv -f "$item" "${run_dir}/"; then
                    log "${label} WARNING: Failed to move $(basename "$item") during flatten"
                fi
            fi
        fi
    done

    # Verify the critical output.jsonl was actually moved
    if [[ -f "${nested_dir}/output.jsonl" && ! -f "${run_dir}/output.jsonl" ]]; then
        log "${label} WARNING: output.jsonl still in nested dir after flatten, retrying cp"
        cp -f "${nested_dir}/output.jsonl" "${run_dir}/output.jsonl" || \
            log "${label} ERROR: Failed to copy output.jsonl from nested dir"
    fi

    local skeleton="$nested_dir"
    while [[ "$skeleton" != "$run_dir" && "$skeleton" != "/" ]]; do
        rmdir "$skeleton" 2>/dev/null || break
        skeleton=$(dirname "$skeleton")
    done
}

# ── Helper: run one instance through inference + evaluation for run index i ──
run_one_instance() {
    set +euo pipefail  # Don't let minor failures abort the whole instance
    local inst_jsonl="$1"   # path to single-line JSONL for this instance
    local inst_id="$2"      # e.g. cli__cli-7693
    local i="$3"            # run index (1..K)
    local inst_run_base="$4" # OUTPUT_BASE/<inst_id>/<model>

    local RUN_DIR="${inst_run_base}/run_${i}"
    mkdir -p "$RUN_DIR"

    local OUTPUT_JSONL="${RUN_DIR}/output.jsonl"
    local RUN_FAILED=false

    # ── INFERENCE ──────────────────────────────────────────────────────────
    if [[ "$SKIP_INFER" == false ]]; then
        local INFER_CMD=(
            uv run python -m benchmarks.multiswebench.run_infer
            "$LLM_CONFIG"
            --dataset "$inst_jsonl"
            --split "$SPLIT"
            --lang "$LANG"
            --workspace "$WORKSPACE"
            --max-iterations "$MAX_ITER"
            --conversation-timeout "$CONVERSATION_TIMEOUT"
            --num-workers 1
            --max-retries "$MAX_RETRIES"
            --max-attempts 1
            --output-dir "$RUN_DIR"
        )

        [[ -n "$SELECT_FILE" ]] && INFER_CMD+=(--select "$SELECT_FILE")

        export LANGUAGE="$LANG"
        export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
        export EVAL_ECR_IMAGE_PREFIX="${ECR_PREFIX}"

        local INFER_LOG="${RUN_DIR}/infer.log"
        log "[${inst_id}][Run ${i}] Starting inference..."

        local INFER_EXIT_CODE=0
        "${INFER_CMD[@]}" >> "$INFER_LOG" 2>&1 || INFER_EXIT_CODE=$?

        if [[ "$INFER_EXIT_CODE" -eq 0 ]]; then
            log "[${inst_id}][Run ${i}] Inference completed successfully."
        else
            log "[${inst_id}][Run ${i}] WARNING: Inference exited with code $INFER_EXIT_CODE"
            RUN_FAILED=true
        fi

        _flatten_official_output_dir "$RUN_DIR" "$inst_id" "$i"
    else
        if [[ ! -f "$OUTPUT_JSONL" ]]; then
            _flatten_official_output_dir "$RUN_DIR" "$inst_id" "$i"
        fi
    fi

    if [[ ! -f "$OUTPUT_JSONL" ]]; then
        log "[${inst_id}][Run ${i}] ERROR: No output.jsonl found. Skipping evaluation."
        return 1
    fi

    # ── EVALUATION ─────────────────────────────────────────────────────────
    if [[ "$SKIP_EVAL" == false ]]; then
        log "[${inst_id}][Run ${i}] Starting evaluation..."

        if ! generate_eval_config "$RUN_DIR" "$OUTPUT_JSONL" "$inst_jsonl"; then
            log "[${inst_id}][Run ${i}] ERROR: Failed to generate eval config"
            RUN_FAILED=true
        else
            cd "$SCRIPT_DIR"
            local EVAL_CMD=(
                uv run python -m multi_swe_bench.harness.run_evaluation
                --config "${RUN_DIR}/config.json"
                --mode evaluation
            )

            local EVAL_LOG="${RUN_DIR}/eval.log"
            local EVAL_EXIT_CODE=0
            "${EVAL_CMD[@]}" >> "$EVAL_LOG" 2>&1 || EVAL_EXIT_CODE=$?

            if [[ "$EVAL_EXIT_CODE" -ne 0 ]]; then
                log "[${inst_id}][Run ${i}] WARNING: Evaluation exited with code $EVAL_EXIT_CODE"
                RUN_FAILED=true
            fi
        fi

        local FINAL_REPORT="${RUN_DIR}/eval_files/dataset/final_report.json"
        local REPORT_OUT="${RUN_DIR}/output.report.json"
        if [[ -f "$FINAL_REPORT" ]]; then
            cp "$FINAL_REPORT" "$REPORT_OUT"
        else
            log "[${inst_id}][Run ${i}] WARNING: final_report.json not found"
            RUN_FAILED=true
        fi
    fi

    if [[ "$RUN_FAILED" == true ]]; then
        return 1
    fi
    return 0
}

# ── Helper: run INFERENCE only for one run ────────────────────────────────────
run_one_infer() {
    set +euo pipefail
    local inst_jsonl="$1"
    local inst_id="$2"
    local i="$3"
    local inst_run_base="$4"

    local RUN_DIR="${inst_run_base}/run_${i}"
    mkdir -p "$RUN_DIR"
    local OUTPUT_JSONL="${RUN_DIR}/output.jsonl"

    # Resume: skip if output exists AND is valid JSON
    if [[ -s "$OUTPUT_JSONL" ]]; then
        if python3 -c "
import json, sys
count = 0
try:
    with open('${OUTPUT_JSONL}') as f:
        for line in f:
            if line.strip():
                json.loads(line.strip())
                count += 1
    sys.exit(0 if count > 0 else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
            log "[${inst_id}][Run ${i}] Inference already done (valid JSON), skipping."
            return 0
        else
            log "[${inst_id}][Run ${i}] WARNING: output.jsonl is invalid/truncated. Removing and re-running."
            rm -f "$OUTPUT_JSONL"
        fi
    fi

    if [[ "$SKIP_INFER" == false ]]; then
        # ── Pre-inference: remove stale all-error critic files from old paths ──
        # Old runs created critic files under __home__... paths. If those exist
        # with only errors and no valid nested output.jsonl, delete them so
        # iterative.py doesn't skip inference due to "already processed" logic.
        while IFS= read -r -d '' stale_critic; do
            pre_all_errors=$(python3 -c "
import json, sys
try:
    lines = [l for l in open('${stale_critic}').read().splitlines() if l.strip()]
    if not lines: sys.exit(1)
    parsed = [json.loads(l) for l in lines]
    if all(bool(d.get('error','')) for d in parsed): print('yes')
except Exception: sys.exit(1)
" 2>/dev/null || true)
            if [[ "$pre_all_errors" == "yes" ]]; then
                log "[${inst_id}][Run ${i}] Pre-removing stale error-critic: $(basename $(dirname $stale_critic))/$(basename $stale_critic)"
                rm -f "$stale_critic"
            fi
        done < <(find "$RUN_DIR" -name "output.critic_attempt_*.jsonl" -print0 2>/dev/null)

        local INFER_CMD=(
            uv run python -m benchmarks.multiswebench.run_infer
            "$LLM_CONFIG"
            --dataset "$inst_jsonl"
            --split "$SPLIT"
            --lang "$LANG"
            --workspace "$WORKSPACE"
            --max-iterations "$MAX_ITER"
            --conversation-timeout "$CONVERSATION_TIMEOUT"
            --num-workers 1
            --max-retries "$MAX_RETRIES"
            --max-attempts 1
            --output-dir "$RUN_DIR"
        )
        [[ -n "$SELECT_FILE" ]] && INFER_CMD+=(--select "$SELECT_FILE")

        export LANGUAGE="$LANG"
        export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
        export EVAL_ECR_IMAGE_PREFIX="${ECR_PREFIX}"

        local INFER_LOG="${RUN_DIR}/infer.log"
        log "[${inst_id}][Run ${i}] Starting inference..."

        local INFER_EXIT_CODE=0
        "${INFER_CMD[@]}" >> "$INFER_LOG" 2>&1 || INFER_EXIT_CODE=$?

        if [[ "$INFER_EXIT_CODE" -ne 0 ]]; then
            log "[${inst_id}][Run ${i}] WARNING: Inference exited with code $INFER_EXIT_CODE"
        fi

        _flatten_official_output_dir "$RUN_DIR" "$inst_id" "$i"
    else
        if [[ ! -f "$OUTPUT_JSONL" ]]; then
            _flatten_official_output_dir "$RUN_DIR" "$inst_id" "$i"
        fi
    fi

    # ── Stale error-critic cleanup ──────────────────────────────────────────
    # If output.jsonl is still missing/empty after inference, check for critic
    # files that contain only errors (buildx crash, container health timeout, etc).
    # These block the next invocation because iterative.py sees the critic file
    # exists and skips launching the Docker container, producing 0-byte output
    # forever. Deleting them forces a clean retry next time.
    if [[ ! -s "$OUTPUT_JSONL" ]]; then
        while IFS= read -r -d '' critic_file; do
            # Check if every entry in the critic file has an error field set
            all_errors=$(python3 -c "
import json, sys
try:
    lines = [l for l in open('${critic_file}').read().splitlines() if l.strip()]
    if not lines:
        sys.exit(1)
    parsed = [json.loads(l) for l in lines]
    # all entries must have a non-empty error field
    if all(bool(d.get('error','')) for d in parsed):
        print('yes')
except Exception:
    sys.exit(1)
" 2>/dev/null || true)
            if [[ "$all_errors" == "yes" ]]; then
                log "[${inst_id}][Run ${i}] Removing stale error-critic (will retry): $(basename $(dirname $critic_file))/$(basename $critic_file)"
                rm -f "$critic_file"
            fi
        done < <(find "$RUN_DIR" -name "output.critic_attempt_*.jsonl" -print0 2>/dev/null)

        # Remove 0-byte nested output.jsonl files (produced by aggregate_results when all entries have errors)
        while IFS= read -r -d '' zero_out; do
            log "[${inst_id}][Run ${i}] Removing 0-byte nested output.jsonl: $(basename $(dirname $zero_out))"
            rm -f "$zero_out"
        done < <(find "$RUN_DIR" -mindepth 2 -name "output.jsonl" \
            -not -path "*/eval_files/*" -size 0 -print0 2>/dev/null)
    fi

    [[ -f "$OUTPUT_JSONL" ]]  # return 0 if output exists, 1 otherwise
}

# ── Helper: run EVALUATION only for one run ───────────────────────────────────
run_one_eval() {
    set +euo pipefail
    local inst_id="$1"
    local i="$2"
    local inst_run_base="$3"
    local inst_jsonl="$4"

    local RUN_DIR="${inst_run_base}/run_${i}"
    local OUTPUT_JSONL="${RUN_DIR}/output.jsonl"

    if [[ ! -f "$OUTPUT_JSONL" ]]; then
        log "[${inst_id}][Run ${i}] ERROR: No output.jsonl found. Skipping evaluation."
        return 1
    fi

    # Resume: skip if evaluation already completed
    local REPORT_OUT="${RUN_DIR}/output.report.json"
    if [[ -f "$REPORT_OUT" ]]; then
        log "[${inst_id}][Run ${i}] Evaluation already done, skipping."
        return 0
    fi

    if [[ "$SKIP_EVAL" == false ]]; then
        log "[${inst_id}][Run ${i}] Starting evaluation..."

        if ! generate_eval_config "$RUN_DIR" "$OUTPUT_JSONL" "$inst_jsonl"; then
            log "[${inst_id}][Run ${i}] ERROR: Failed to generate eval config"
            return 1
        fi

        cd "$SCRIPT_DIR"
        local EVAL_CMD=(
            uv run python -m multi_swe_bench.harness.run_evaluation
            --config "${RUN_DIR}/config.json"
            --mode evaluation
        )

        local EVAL_LOG="${RUN_DIR}/eval.log"
        local EVAL_EXIT_CODE=0
        "${EVAL_CMD[@]}" >> "$EVAL_LOG" 2>&1 || EVAL_EXIT_CODE=$?

        if [[ "$EVAL_EXIT_CODE" -ne 0 ]]; then
            log "[${inst_id}][Run ${i}] WARNING: Evaluation exited with code $EVAL_EXIT_CODE"
            return 1
        fi

        local FINAL_REPORT="${RUN_DIR}/eval_files/dataset/final_report.json"
        local REPORT_OUT="${RUN_DIR}/output.report.json"
        if [[ -f "$FINAL_REPORT" ]]; then
            cp "$FINAL_REPORT" "$REPORT_OUT"
        else
            log "[${inst_id}][Run ${i}] WARNING: final_report.json not found"
            return 1
        fi
    fi
    return 0
}

# ── Helper: process all K runs for one instance (called in background) ────────
run_instance_all_runs() {
    set +euo pipefail
    local inst_jsonl="$1"
    local inst_id="$2"
    local inst_run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
    mkdir -p "$inst_run_base"

    local inst_failed=0
    local inst_ok=0

    # ── PHASE 1: Inference for all K runs ────────────────────────────────────
    # Run START_RUN first (this builds the docker image).
    # Then launch START_RUN+1..K in parallel with MULTI_SWE_BENCH_SKIP_BUILD=1
    # (they reuse the already-built image).
    run_one_infer "$inst_jsonl" "$inst_id" "$START_RUN" "$inst_run_base"

    # Before launching runs 2-K with SKIP_BUILD=1, verify run_1 built the agent_server image.
    local _skip_build_ok=true
    if [[ "$K" -gt "$START_RUN" && ! -s "${inst_run_base}/run_${START_RUN}/output.jsonl" ]]; then
        local _sdk_sha _pr_num _inst_org _inst_repo _expected_img
        _sdk_sha=$(cd "$SCRIPT_DIR/vendor/software-agent-sdk" && git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
        read -r _pr_num _inst_org _inst_repo <<< "$(python3 -c "import json; d=json.load(open('$inst_jsonl')); print(d.get('number',''), d.get('org',''), d.get('repo',''))" 2>/dev/null || echo "")"
        if [[ -n "$_pr_num" && -n "$_inst_org" && -n "$_inst_repo" ]]; then
            _inst_org_lc=$(echo "$_inst_org" | tr '[:upper:]' '[:lower:]')
            _inst_repo_lc=$(echo "$_inst_repo" | tr '[:upper:]' '[:lower:]')
            _expected_img="ghcr.io/openhands/eval-agent-server:${_sdk_sha}-${_inst_org_lc}_m_${_inst_repo_lc}-pr-${_pr_num}-source-minimal"
            if ! docker image inspect "$_expected_img" >/dev/null 2>&1; then
                log "[${inst_id}] WARNING: run_1 failed to build agent_server image. Skipping runs 2-${K}."
                _skip_build_ok=false
            fi
        fi
    fi

    local infer_pids=()
    if [[ "$K" -gt "$START_RUN" && "$_skip_build_ok" == true ]]; then
        for i in $(seq $((START_RUN + 1)) "$K"); do
            (
                set +euo pipefail
                export MULTI_SWE_BENCH_SKIP_BUILD=1
                run_one_infer "$inst_jsonl" "$inst_id" "$i" "$inst_run_base"
            ) &
            infer_pids+=($!)
        done
        for pid in "${infer_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    fi

    log "[${inst_id}] All inferences complete. Starting evaluations..."

    # ── PHASE 2: Evaluation for all runs (after all inferences done) ─────────
    for i in $(seq "$START_RUN" "$K"); do
        if run_one_eval "$inst_id" "$i" "$inst_run_base" "$inst_jsonl"; then
            inst_ok=$((inst_ok + 1))
        else
            inst_failed=$((inst_failed + 1))
        fi
    done

    log "[${inst_id}] Done — ${inst_ok} OK, ${inst_failed} failed out of $((K - START_RUN + 1)) runs."
    [[ "$inst_failed" -eq 0 ]]
}

if [[ "$INSTANCE_COUNT" -eq 1 ]] && false; then
    # ── SINGLE-INSTANCE: original behaviour (DISABLED — always use two-phase parallel) ──
    for i in $(seq "$START_RUN" "$K"); do
        RUN_DIR="${RUN_BASE}/run_${i}"
        mkdir -p "$RUN_DIR"

        log ""
        log "─────────────────────────────────────────────────────────────"
        log "  Run ${i} / ${K}"
        log "  Directory: ${RUN_DIR}"
        log "─────────────────────────────────────────────────────────────"

        OUTPUT_JSONL="${RUN_DIR}/output.jsonl"
        RUN_FAILED=false

        if [[ "$SKIP_INFER" == false ]]; then
            log "[Run ${i}] Starting inference..."
            cd "$SCRIPT_DIR"

            INFER_CMD=(
                uv run python -m benchmarks.multiswebench.run_infer
                "$LLM_CONFIG"
                --dataset "$CANONICAL_DATASET"
                --split "$SPLIT"
                --lang "$LANG"
                --workspace "$WORKSPACE"
                --max-iterations "$MAX_ITER"
                --conversation-timeout "$CONVERSATION_TIMEOUT"
                --num-workers "$NUM_WORKERS"
                --max-retries "$MAX_RETRIES"
                --max-attempts 1
                --output-dir "$RUN_DIR"
            )

            [[ -n "$SELECT_FILE" ]] && INFER_CMD+=(--select "$SELECT_FILE")
            [[ "$N_LIMIT" -ne 0 ]] && INFER_CMD+=(--n-limit "$N_LIMIT")

            export LANGUAGE="$LANG"
            export EVAL_DOCKER_IMAGE_PREFIX="mswebench"
            export EVAL_ECR_IMAGE_PREFIX="${ECR_PREFIX}"

            INFER_LOG="${RUN_DIR}/infer.log"
            log "[Run ${i}] Command: ${INFER_CMD[*]}"

            INFER_EXIT_CODE=0
            "${INFER_CMD[@]}" 2>&1 | tee "$INFER_LOG" || INFER_EXIT_CODE=$?

            if [[ "$INFER_EXIT_CODE" -eq 0 ]]; then
                log "[Run ${i}] Inference completed successfully."
            else
                log "[Run ${i}] WARNING: Inference exited with code $INFER_EXIT_CODE"
                RUN_FAILED=true
            fi

            _flatten_official_output_dir "$RUN_DIR" "" "$i"
        else
            log "[Run ${i}] Skipping inference (--skip-infer)"
            if [[ ! -f "$OUTPUT_JSONL" ]]; then
                _flatten_official_output_dir "$RUN_DIR" "" "$i"
            fi
        fi

        if [[ ! -f "$OUTPUT_JSONL" ]]; then
            log "[Run ${i}] ERROR: No output.jsonl found. Skipping evaluation."
            FAILED_RUNS=$((FAILED_RUNS + 1))
            continue
        fi

        if [[ "$SKIP_EVAL" == false ]]; then
            log "[Run ${i}] Starting evaluation..."

            if ! generate_eval_config "$RUN_DIR" "$OUTPUT_JSONL" "$CANONICAL_DATASET"; then
                log "[Run ${i}] ERROR: Failed to generate eval config"
                RUN_FAILED=true
            else
                cd "$SCRIPT_DIR"
                EVAL_CMD=(
                    uv run python -m multi_swe_bench.harness.run_evaluation
                    --config "${RUN_DIR}/config.json"
                    --mode evaluation
                )

                EVAL_LOG="${RUN_DIR}/eval.log"
                EVAL_EXIT_CODE=0
                "${EVAL_CMD[@]}" 2>&1 | tee "$EVAL_LOG" || EVAL_EXIT_CODE=$?

                if [[ "$EVAL_EXIT_CODE" -eq 0 ]]; then
                    log "[Run ${i}] Evaluation completed successfully."
                else
                    log "[Run ${i}] WARNING: Evaluation exited with code $EVAL_EXIT_CODE"
                    RUN_FAILED=true
                fi
            fi

            FINAL_REPORT="${RUN_DIR}/eval_files/dataset/final_report.json"
            REPORT_OUT="${RUN_DIR}/output.report.json"
            if [[ -f "$FINAL_REPORT" ]]; then
                cp "$FINAL_REPORT" "$REPORT_OUT"
                log "[Run ${i}] Report: $REPORT_OUT"
            else
                log "[Run ${i}] WARNING: final_report.json not found"
                RUN_FAILED=true
            fi
        else
            log "[Run ${i}] Skipping evaluation (--skip-eval)"
        fi

        if [[ "$RUN_FAILED" == true ]]; then
            FAILED_RUNS=$((FAILED_RUNS + 1))
        else
            SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + 1))
        fi

        log "[Run ${i}] Done. (Status: $([ "$RUN_FAILED" == true ] && echo "FAILED" || echo "OK"))"
    done

else
    # ── MULTI-INSTANCE: per-instance output dirs, parallelised ───────────────
    log "Multi-instance mode: running up to $NUM_WORKERS instances in parallel."
    log "Output structure: eval_outputs/<instance_id>/${MODEL_SHORT}/run_<N>/"

    # Store per-instance JSONL files inside OUTPUT_BASE so they persist for the
    # lifetime of the run (avoid /tmp cleanup races with long-running agents).
    INST_JSONL_DIR="${OUTPUT_BASE}/.instance_jsonls"
    mkdir -p "$INST_JSONL_DIR"

    # Build list of (inst_id, inst_jsonl) pairs.
    # Skip instances with empty resolved_issues — the formatter will produce an
    # empty file for them, causing run_infer to fail with KeyError immediately.
    declare -a INST_IDS=()
    declare -a INST_JSONLS=()
    SKIPPED_INSTANCES=0

    while IFS= read -r line; do
        result=$(echo "$line" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
inst_id = d.get('instance_id', '')
ri = d.get('resolved_issues', None)
# Skip if no instance_id or resolved_issues is empty/null
if not inst_id or not ri:
    print('')
else:
    print(inst_id)
")
        if [[ -z "$result" ]]; then
            SKIPPED_INSTANCES=$((SKIPPED_INSTANCES + 1))
            continue
        fi
        inst_jsonl="${INST_JSONL_DIR}/${result}.jsonl"
        echo "$line" > "$inst_jsonl"
        INST_IDS+=("$result")
        INST_JSONLS+=("$inst_jsonl")
    done < "$CANONICAL_DATASET"

    TOTAL_INSTANCES=${#INST_IDS[@]}
    log "Skipped $SKIPPED_INSTANCES instances with empty resolved_issues."

    # Apply --n-limit in multi-instance mode
    if [[ "$N_LIMIT" -ne 0 && "$TOTAL_INSTANCES" -gt "$N_LIMIT" ]]; then
        log "Applying --n-limit $N_LIMIT: using first $N_LIMIT of $TOTAL_INSTANCES instances."
        INST_IDS=("${INST_IDS[@]:0:$N_LIMIT}")
        INST_JSONLS=("${INST_JSONLS[@]:0:$N_LIMIT}")
        TOTAL_INSTANCES=$N_LIMIT
    fi

    # ── PRE-PULL: fetch all ECR base images before dispatching workers ──────────
    if [[ -n "${ECR_PREFIX:-}" ]]; then
        log "Pre-pulling ${TOTAL_INSTANCES} ECR base images (24 parallel)..."
        PREPULL_PIDS=()
        PREPULL_SLOTS=64
        PREPULL_FIFO=$(mktemp -u /tmp/prepull_sem.XXXXXX)
        mkfifo "$PREPULL_FIFO"
        for ((t=0; t<PREPULL_SLOTS; t++)); do echo "x" >> "$PREPULL_FIFO"; done &
        exec 8<>"$PREPULL_FIFO"
        rm -f "$PREPULL_FIFO"

        PREPULL_FAIL_FILE="${INST_JSONL_DIR}/.prepull_fails"
        : > "$PREPULL_FAIL_FILE"

        for idx in "${!INST_IDS[@]}"; do
            inst_jsonl="${INST_JSONLS[$idx]}"
            local_inst_id="${INST_IDS[$idx]}"
            # Extract org, repo, and pr number to form correct per-instance image name
            read -r inst_org inst_repo pr_num <<< "$(python3 -c "import json; d=json.load(open('${inst_jsonl}')); print(d.get('org',''), d.get('repo',''), d.get('number',''))" 2>/dev/null || true)"
            if [[ -z "$pr_num" || -z "$inst_org" || -z "$inst_repo" ]]; then continue; fi
            local_image="mswebench/${inst_org,,}_m_${inst_repo,,}:pr-${pr_num}"
            ecr_image="${ECR_PREFIX}/${inst_org,,}_m_${inst_repo,,}:pr-${pr_num}"

            read -u 8 _tok
            (
                set +euo pipefail
                _needs_pull=false
                if docker image inspect "$local_image" >/dev/null 2>&1; then
                    _cached_arch=$(docker image inspect "$local_image" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
                    if [[ "$_cached_arch" != "arm64" && "$_cached_arch" != "aarch64" ]]; then
                        log "[pre-pull] Cached $local_image has arch '$_cached_arch' — removing"
                        docker rmi "$local_image" 2>/dev/null || true
                        _needs_pull=true
                    fi
                else
                    _needs_pull=true
                fi
                if [[ "$_needs_pull" == true ]]; then
                    if _pp_err=$(docker pull --platform linux/arm64 "$ecr_image" 2>&1); then
                        docker tag "$ecr_image" "$local_image" >/dev/null 2>&1 || true
                        log "[pre-pull] Pulled $local_image"
                    else
                        log "[pre-pull] WARNING: Could not pull $ecr_image — skipping instance $local_inst_id"
                        log "[pre-pull]   Docker error: ${_pp_err}"
                        echo "$local_inst_id" >> "$PREPULL_FAIL_FILE"
                    fi
                fi
                echo "x" >&8
            ) &
            PREPULL_PIDS+=($!)
        done
        for pid in "${PREPULL_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
        exec 8>&-
        log "Pre-pull complete."
    fi

    # ── PRE-BUILD: build agent-server images for ALL instances ─────────────
    # Phase 0 only builds the agent-server image for the FIRST instance in the
    # dataset.  In multi-instance mode every PR needs its own agent-server image
    # (different base image).  Build them all here with correct ARM64 platform
    # so the Python harness can skip its own (amd64-defaulting) build.
    if [[ "$SKIP_INFER" == false ]]; then
        log "Pre-building agent-server images for ${TOTAL_INSTANCES} instances (8 parallel)..."

        DOCKER_CONTEXT=$(docker context show 2>/dev/null || echo "default")
        AGENT_DOCKERFILE="$SCRIPT_DIR/vendor/software-agent-sdk/openhands-agent-server/openhands/agent_server/docker/Dockerfile"
        AGENT_SDK_ROOT="$SCRIPT_DIR/vendor/software-agent-sdk"

        # Prepare patched Dockerfile (same logic as Phase 0)
        _MULTI_PATCHED_DF=$(mktemp /tmp/agent-server-Dockerfile-multi.XXXXXX)
        awk '
        /^FROM \$\{BASE_IMAGE\} AS base-image-minimal/ {
            print; print "USER root"; in_minimal=1; next
        }
        in_minimal && /^USER \$\{USERNAME\}/ {
            print "RUN chmod -R a+rX /home/ /testbed/ /app/ 2>/dev/null || true"
            in_minimal=0
        }
        {print}
        ' "$AGENT_DOCKERFILE" > "$_MULTI_PATCHED_DF"

        # Apply LiteLLM patch if needed
        LITELLM_PATCH="$SCRIPT_DIR/patches/patch_litellm_vertex_express.py"
        if [[ -f "$LITELLM_PATCH" ]] && ! grep -q "patch_litellm_vertex_express" "$_MULTI_PATCHED_DF"; then
            cp "$LITELLM_PATCH" "$AGENT_SDK_ROOT/patch_litellm_vertex_express.py"
            sed -i '/uv sync --frozen --no-editable/a COPY --chown=${USERNAME}:${USERNAME} patch_litellm_vertex_express.py /tmp/\nRUN /agent-server/.venv/bin/python /tmp/patch_litellm_vertex_express.py >/dev/null 2>\&1 \&\& rm /tmp/patch_litellm_vertex_express.py' "$_MULTI_PATCHED_DF"
        fi

        # Hard-coded arm64 platform
        PREBUILD_ARCH="arm64"

        # Build images in parallel (8 at a time to avoid Docker resource exhaustion)
        ABUILD_SLOTS=8
        ABUILD_FIFO=$(mktemp -u /tmp/abuild_sem.XXXXXX)
        mkfifo "$ABUILD_FIFO"
        exec 7<>"$ABUILD_FIFO"
        rm -f "$ABUILD_FIFO"
        for ((t=0; t<ABUILD_SLOTS; t++)); do echo "x" >&7; done

        ABUILD_OK=0
        ABUILD_SKIP=0
        ABUILD_FAIL=0
        declare -a ABUILD_PIDS=()

        for idx in "${!INST_IDS[@]}"; do
            inst_id="${INST_IDS[$idx]}"
            inst_jsonl="${INST_JSONLS[$idx]}"

            read -r inst_org inst_repo pr_num <<< "$(python3 -c "import json; d=json.load(open('${inst_jsonl}')); print(d.get('org',''), d.get('repo',''), d.get('number',''))" 2>/dev/null || true)"
            [[ -z "$pr_num" ]] && continue

            inst_org_lc=$(echo "$inst_org" | tr '[:upper:]' '[:lower:]')
            inst_repo_lc=$(echo "$inst_repo" | tr '[:upper:]' '[:lower:]')
            inst_custom_tag="${inst_org_lc}_m_${inst_repo_lc}-pr-${pr_num}"
            inst_agent_image="ghcr.io/openhands/eval-agent-server:${SDK_SHORT_SHA}-${inst_custom_tag}-source-minimal"
            inst_base_image="mswebench/${inst_org_lc}_m_${inst_repo_lc}:pr-${pr_num}"

            # Skip if already built
            if docker image inspect "$inst_agent_image" >/dev/null 2>&1; then
                ABUILD_SKIP=$((ABUILD_SKIP + 1))
                continue
            fi

            # For ARM64, use ECR URL as base (has correct manifest)
            if [[ "$PREBUILD_ARCH" == "arm64" && -n "$ECR_PREFIX" ]]; then
                inst_build_base="${ECR_PREFIX}/${inst_org_lc}_m_${inst_repo_lc}:pr-${pr_num}"
            else
                inst_build_base="$inst_base_image"
            fi

            read -u 7 _tok

            (
                set +euo pipefail
                if BUILDX_BUILDER="$DOCKER_CONTEXT" docker buildx build \
                    --file "$_MULTI_PATCHED_DF" \
                    --target source-minimal \
                    --build-arg "BASE_IMAGE=$inst_build_base" \
                    --platform "linux/${PREBUILD_ARCH}" \
                    --load \
                    --tag "$inst_agent_image" \
                    --build-arg BUILDKIT_INLINE_CACHE=1 \
                    "$AGENT_SDK_ROOT" >/dev/null 2>&1; then
                    log "[pre-build] Built agent-server: ${inst_id}"
                else
                    log "[pre-build] FAILED: ${inst_id}"
                fi
                echo "x" >&7
            ) &
            ABUILD_PIDS+=($!)
        done

        for pid in "${ABUILD_PIDS[@]}"; do
            if wait "$pid" 2>/dev/null; then
                ABUILD_OK=$((ABUILD_OK + 1))
            else
                ABUILD_FAIL=$((ABUILD_FAIL + 1))
            fi
        done
        exec 7>&-
        rm -f "$_MULTI_PATCHED_DF"
        log "Pre-build complete: ${ABUILD_OK} built, ${ABUILD_SKIP} skipped (exist), ${ABUILD_FAIL} failed."
    fi

    # ── PRE-VALIDATE: ensure shared repo is ready before any eval ────────────
    if [[ "$SKIP_EVAL" == false ]]; then
        pre_validate_shared_repo
    fi

    # Export functions and variables needed by background subshells
    export -f run_one_instance run_one_infer run_one_eval run_instance_all_runs generate_eval_config build_fix_cmd log pre_validate_shared_repo _reap_dead_containers
    export SCRIPT_DIR LLM_CONFIG SPLIT LANG WORKSPACE MAX_ITER MAX_RETRIES CONVERSATION_TIMEOUT
    export K START_RUN SKIP_INFER SKIP_EVAL OUTPUT_BASE MODEL_SHORT ECR_PREFIX
    export SELECT_FILE LANGUAGE EVAL_DOCKER_IMAGE_PREFIX EVAL_ECR_IMAGE_PREFIX
    export DOCKER_PLATFORM

    if [[ "$SKIP_INFER" == true && "$SKIP_EVAL" == false ]]; then
        # ── TWO-PHASE EVAL-ONLY DISPATCH ─────────────────────────────────────
        # Phase A builds Docker images (one eval per instance) with controlled
        # parallelism.  Phase B runs the remaining evaluations (runs 2-K) at
        # full parallelism since all images already exist.
        # ──────────────────────────────────────────────────────────────────────

        PHASE_A_WORKERS=$(( NUM_WORKERS < 96 ? NUM_WORKERS : 96 ))
        PHASE_B_WORKERS=$NUM_WORKERS

        log ""
        log "═══════════════════════════════════════════════════════════════"
        log "  Two-phase eval-only mode"
        log "  Phase A: ${TOTAL_INSTANCES} image builds (max ${PHASE_A_WORKERS} parallel)"
        log "  Phase B: remaining evals, runs $((START_RUN+1))-${K} (max ${PHASE_B_WORKERS} parallel)"
        log "═══════════════════════════════════════════════════════════════"

        # ── Phase A-1: Build base Docker image via first valid instance ───────
        # The first eval builds both the shared base image (mswebench/cli_m_cli:base)
        # and its PR image.  Running this single-threaded ensures no race on the
        # base image — all Phase A-2 workers will find it already in Docker.

        _first_idx=""
        for idx in "${!INST_IDS[@]}"; do
            inst_id="${INST_IDS[$idx]}"
            if [[ -f "${PREPULL_FAIL_FILE:-}" ]] && grep -qxF "$inst_id" "${PREPULL_FAIL_FILE}" 2>/dev/null; then
                continue
            fi
            _first_idx=$idx
            break
        done

        PA_OK=0
        PA_FAIL=0

        if [[ -n "$_first_idx" ]]; then
            inst_id="${INST_IDS[$_first_idx]}"
            inst_jsonl="${INST_JSONLS[$_first_idx]}"
            inst_run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
            mkdir -p "$inst_run_base"

            log "Phase A-1: Building base image via ${inst_id}/run_${START_RUN}..."
            if run_one_eval "$inst_id" "$START_RUN" "$inst_run_base" "$inst_jsonl"; then
                PA_OK=$((PA_OK + 1))
            else
                PA_FAIL=$((PA_FAIL + 1))
            fi
            log "Phase A-1: Complete."
        fi

        # ── Phase A-2: Build remaining PR images (limited parallelism) ────────
        log "Phase A-2: Building PR images for remaining instances (max ${PHASE_A_WORKERS} parallel)..."

        PA_FIFO=$(mktemp -u /tmp/eval_phaseA_sem.XXXXXX)
        mkfifo "$PA_FIFO"
        exec 8<>"$PA_FIFO"
        rm -f "$PA_FIFO"
        for ((t=0; t<PHASE_A_WORKERS; t++)); do echo "token" >&8; done

        declare -a PA_PIDS=()

        for idx in "${!INST_IDS[@]}"; do
            [[ -n "$_first_idx" && "$idx" -eq "$_first_idx" ]] && continue  # done in A-1

            inst_id="${INST_IDS[$idx]}"
            inst_jsonl="${INST_JSONLS[$idx]}"

            if [[ -f "${PREPULL_FAIL_FILE:-}" ]] && grep -qxF "$inst_id" "${PREPULL_FAIL_FILE}" 2>/dev/null; then
                continue
            fi

            read -u 8 token

            (
                set +euo pipefail
                _run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
                mkdir -p "$_run_base"
                run_one_eval "$inst_id" "$START_RUN" "$_run_base" "$inst_jsonl"
                rc=$?
                echo "token" >&8
                exit $rc
            ) &
            PA_PIDS+=($!)
        done

        for pid in "${PA_PIDS[@]}"; do
            if wait "$pid" 2>/dev/null; then
                PA_OK=$((PA_OK + 1))
            else
                PA_FAIL=$((PA_FAIL + 1))
            fi
        done
        exec 8>&-

        log "Phase A complete: $PA_OK OK, $PA_FAIL failed (image builds)."
        SUCCESSFUL_RUNS=$PA_OK
        FAILED_RUNS=$PA_FAIL

        # ── Phase B: Run remaining evaluations (runs START_RUN+1 .. K) ────────
        if [[ "$K" -gt "$START_RUN" ]]; then
            REMAINING_RUNS=$(( (K - START_RUN) * TOTAL_INSTANCES ))
            log ""
            log "Phase B: Running $REMAINING_RUNS remaining evaluations (max ${PHASE_B_WORKERS} parallel)..."

            PB_FIFO=$(mktemp -u /tmp/eval_phaseB_sem.XXXXXX)
            mkfifo "$PB_FIFO"
            exec 9<>"$PB_FIFO"
            rm -f "$PB_FIFO"
            for ((t=0; t<PHASE_B_WORKERS; t++)); do echo "token" >&9; done

            declare -a PB_PIDS=()
            PB_DISPATCHED=0

            for idx in "${!INST_IDS[@]}"; do
                inst_id="${INST_IDS[$idx]}"
                inst_jsonl="${INST_JSONLS[$idx]}"

                if [[ -f "${PREPULL_FAIL_FILE:-}" ]] && grep -qxF "$inst_id" "${PREPULL_FAIL_FILE}" 2>/dev/null; then
                    continue
                fi

                for i in $(seq $((START_RUN + 1)) "$K"); do
                    read -u 9 token
                    PB_DISPATCHED=$((PB_DISPATCHED + 1))

                    (
                        set +euo pipefail
                        _run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
                        run_one_eval "$inst_id" "$i" "$_run_base" "$inst_jsonl"
                        rc=$?
                        echo "token" >&9
                        exit $rc
                    ) &
                    PB_PIDS+=($!)
                done
            done

            PB_OK=0
            PB_FAIL=0
            for pid in "${PB_PIDS[@]}"; do
                if wait "$pid" 2>/dev/null; then
                    PB_OK=$((PB_OK + 1))
                else
                    PB_FAIL=$((PB_FAIL + 1))
                fi
            done
            exec 9>&-

            log "Phase B complete: $PB_OK OK, $PB_FAIL failed."
            SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + PB_OK))
            FAILED_RUNS=$((FAILED_RUNS + PB_FAIL))
        fi

        TOTAL_EVAL_RUNS=$(( (K - START_RUN + 1) * TOTAL_INSTANCES ))
        log ""
        log "Two-phase eval complete: $SUCCESSFUL_RUNS OK, $FAILED_RUNS failed out of $TOTAL_EVAL_RUNS eval runs."

    elif [[ "$SKIP_INFER" == false && "$SKIP_EVAL" == false ]]; then
        # ── TWO-PHASE INFER-THEN-EVAL DISPATCH ──────────────────────────────
        # Phase 1 uses NUM_WORKERS for inference (each instance spawns K-1
        # parallel containers, so effective container count is NUM_WORKERS×(K-1)).
        # Phase 2 uses EVAL_WORKERS for evaluation (single container per job).
        EVAL_WORKERS=$(( NUM_WORKERS * (K > 1 ? K - 1 : 3) ))
        [[ "$EVAL_WORKERS" -gt 64 ]] && EVAL_WORKERS=64

        log ""
        log "═══════════════════════════════════════════════════════════════"
        log "  Two-phase infer-then-eval mode"
        log "  Phase 1 (Inference): ${NUM_WORKERS} workers, K=${K}"
        log "  Phase 2 (Evaluation): ${EVAL_WORKERS} workers"
        log "═══════════════════════════════════════════════════════════════"

        # ── Phase 1: Inference for all instances ─────────────────────────────
        log "Phase 1: Starting inference..."
        P1_FIFO=$(mktemp -u /tmp/eval_p1_sem.XXXXXX)
        mkfifo "$P1_FIFO"
        exec 7<>"$P1_FIFO"
        rm -f "$P1_FIFO"
        for ((t=0; t<NUM_WORKERS; t++)); do echo "token" >&7; done

        declare -a P1_PIDS=()
        P1_DISPATCHED=0

        for idx in "${!INST_IDS[@]}"; do
            inst_id="${INST_IDS[$idx]}"
            inst_jsonl="${INST_JSONLS[$idx]}"

            if [[ -f "${PREPULL_FAIL_FILE:-}" ]] && grep -qxF "$inst_id" "${PREPULL_FAIL_FILE}" 2>/dev/null; then
                log "Skipping $inst_id (ECR image not available)"
                SKIPPED_INSTANCES=$((SKIPPED_INSTANCES + 1))
                continue
            fi

            read -u 7 token
            P1_DISPATCHED=$((P1_DISPATCHED + 1))
            log "Phase 1: Inference ${inst_id} (${P1_DISPATCHED}/${TOTAL_INSTANCES})..."

            (
                set +euo pipefail
                _run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
                mkdir -p "$_run_base"

                run_one_infer "$inst_jsonl" "$inst_id" "$START_RUN" "$_run_base"

                _skip_build_ok=true
                if [[ "$K" -gt "$START_RUN" && ! -s "${_run_base}/run_${START_RUN}/output.jsonl" ]]; then
                    _sdk_sha=$(cd "$SCRIPT_DIR/vendor/software-agent-sdk" && git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
                    read -r _pr_num _inst_org _inst_repo <<< "$(python3 -c "import json; d=json.load(open('${inst_jsonl}')); print(d.get('number',''), d.get('org',''), d.get('repo',''))" 2>/dev/null || echo "")"
                    if [[ -n "$_pr_num" && -n "$_inst_org" && -n "$_inst_repo" ]]; then
                        _inst_org_lc=$(echo "$_inst_org" | tr '[:upper:]' '[:lower:]')
                        _inst_repo_lc=$(echo "$_inst_repo" | tr '[:upper:]' '[:lower:]')
                        _expected_img="ghcr.io/openhands/eval-agent-server:${_sdk_sha}-${_inst_org_lc}_m_${_inst_repo_lc}-pr-${_pr_num}-source-minimal"
                        if ! docker image inspect "$_expected_img" >/dev/null 2>&1; then
                            log "[${inst_id}] WARNING: run_1 failed. Skipping runs 2-${K}."
                            _skip_build_ok=false
                        fi
                    fi
                fi

                _infer_pids=()
                if [[ "$K" -gt "$START_RUN" && "$_skip_build_ok" == true ]]; then
                    for i in $(seq $((START_RUN + 1)) "$K"); do
                        (
                            set +euo pipefail
export MULTI_SWE_BENCH_SKIP_BUILD=1
export EVAL_DOCKER_IMAGE_PREFIX="${EVAL_DOCKER_IMAGE_PREFIX:-mswebench}"
                            run_one_infer "$inst_jsonl" "$inst_id" "$i" "$_run_base"
                        ) &
                        _infer_pids+=($!)
                    done
                    for pid in "${_infer_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
                fi

                echo "token" >&7
            ) &
            P1_PIDS+=($!)
        done

        log "Phase 1: All dispatched. Waiting for inference..."
        for pid in "${P1_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
        exec 7>&- 2>/dev/null || true
        set +e
        _reap_dead_containers
        set -e
        log "Phase 1: Inference complete."

        # ── Phase 2: Evaluation for all instances × all runs ─────────────────
        log ""
        log "Phase 2: Dispatching evaluations (${EVAL_WORKERS} workers)..."

        P2_FIFO=$(mktemp -u /tmp/eval_p2_sem.XXXXXX)
        mkfifo "$P2_FIFO"
        exec 8<>"$P2_FIFO"
        rm -f "$P2_FIFO"
        for ((t=0; t<EVAL_WORKERS; t++)); do echo "token" >&8; done

        declare -a P2_PIDS=()

        for idx in "${!INST_IDS[@]}"; do
            inst_id="${INST_IDS[$idx]}"
            inst_jsonl="${INST_JSONLS[$idx]}"

            if [[ -f "${PREPULL_FAIL_FILE:-}" ]] && grep -qxF "$inst_id" "${PREPULL_FAIL_FILE}" 2>/dev/null; then
                continue
            fi

            for i in $(seq "$START_RUN" "$K"); do
                read -u 8 token
                (
                    set +euo pipefail
                    _run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
                    run_one_eval "$inst_id" "$i" "$_run_base" "$inst_jsonl"
                    rc=$?
                    echo "token" >&8
                    exit $rc
                ) &
                P2_PIDS+=($!)
            done
        done

        log "Phase 2: All dispatched. Waiting..."
        for pid in "${P2_PIDS[@]}"; do
            if wait "$pid" 2>/dev/null; then
                SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + 1))
            else
                FAILED_RUNS=$((FAILED_RUNS + 1))
            fi
        done
        exec 8>&-

        TOTAL_EVAL_RUNS=$(( (K - START_RUN + 1) * (TOTAL_INSTANCES - SKIPPED_INSTANCES) ))
        log ""
        log "Two-phase complete: $SUCCESSFUL_RUNS OK, $FAILED_RUNS failed out of $TOTAL_EVAL_RUNS eval runs."

    else
        # ── STANDARD DISPATCH (infer-only or skip-both) ──────────────────────
        log "Dispatching $TOTAL_INSTANCES instances (max $NUM_WORKERS parallel)..."

        # Use a FIFO-based semaphore so the parent process correctly tracks slots.
        # Each background job writes to the FIFO when it completes, freeing a slot.
        FIFO=$(mktemp -u /tmp/eval_sem.XXXXXX)
        mkfifo "$FIFO"
        exec 9<>"$FIFO"
        rm -f "$FIFO"
        for ((t=0; t<NUM_WORKERS; t++)); do echo "token" >&9; done

        declare -a ALL_PIDS=()
        DISPATCHED=0

        for idx in "${!INST_IDS[@]}"; do
            inst_id="${INST_IDS[$idx]}"
            inst_jsonl="${INST_JSONLS[$idx]}"

            # Skip instances whose ECR image couldn't be pulled
            if [[ -f "${PREPULL_FAIL_FILE:-}" ]] && grep -qxF "$inst_id" "${PREPULL_FAIL_FILE}" 2>/dev/null; then
                log "Skipping $inst_id (ECR image not available)"
                SKIPPED_INSTANCES=$((SKIPPED_INSTANCES + 1))
                continue
            fi

            # Block until a token is available (a slot is free)
            read -u 9 token

            DISPATCHED=$((DISPATCHED + 1))
            log "Launching instance ${inst_id} (${DISPATCHED}/${TOTAL_INSTANCES})..."

            # Run in background subshell; disable inherit_errexit so set -e in parent
            # doesn't propagate failures inside the subshell as unhandled errors.
            (
                set +euo pipefail
                run_instance_all_runs "$inst_jsonl" "$inst_id"
                rc=$?
                echo "token" >&9
                exit $rc
            ) &
            ALL_PIDS+=($!)
        done

        # Wait for all jobs and collect results
        log "All instances dispatched. Waiting for completion..."
        for pid in "${ALL_PIDS[@]}"; do
            if wait "$pid"; then
                SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + 1))
            else
                FAILED_RUNS=$((FAILED_RUNS + 1))
            fi
        done
        exec 9>&-

        log "Instance run complete: $SUCCESSFUL_RUNS succeeded, $FAILED_RUNS failed out of $TOTAL_INSTANCES."
    fi
fi

log ""
if [[ "$INSTANCE_COUNT" -eq 1 ]]; then
    log "Run Summary: $SUCCESSFUL_RUNS successful, $FAILED_RUNS failed out of $((K - START_RUN + 1)) runs"
else
    log "Instance Summary: $SUCCESSFUL_RUNS succeeded, $FAILED_RUNS failed out of $TOTAL_INSTANCES instances"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASS@K SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_SUMMARY" == false ]]; then
    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "  Generating pass@${K} summary"
    log "═══════════════════════════════════════════════════════════════"

    cd "$SCRIPT_DIR"

    # Write the summary script to a temp file so it can be reused for both
    # single-instance and multi-instance modes without duplicating 350 lines.
    _SUMMARY_PY=$(mktemp /tmp/pass_at_k_summary.XXXXXX.py)
    cat > "$_SUMMARY_PY" <<'PYSCRIPT'
import json, os, re, glob, sys
from collections import defaultdict, OrderedDict

run_base = sys.argv[1]
k = int(sys.argv[2])
lang = sys.argv[3]
model = sys.argv[4]
dataset_tag = sys.argv[5]
summary_file = sys.argv[6]

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions to extract timing metrics
# ─────────────────────────────────────────────────────────────────────────────

def find_output_jsonl(run_dir):
    """Find the actual output.jsonl with metrics (in the nested directory structure)."""
    pattern = os.path.join(run_dir, "**", "output.jsonl")
    matches = glob.glob(pattern, recursive=True)
    # Prefer the one NOT in eval_files
    for m in matches:
        if "eval_files" not in m:
            return m
    return matches[0] if matches else None

def find_instance_log(run_dir):
    """Find the instance log file that contains elapsed time."""
    pattern = os.path.join(run_dir, "**", "logs", "instance_*.log")
    matches = glob.glob(pattern, recursive=True)
    return matches[0] if matches else None

def extract_metrics_from_output(output_jsonl_path):
    """Extract API time, cost, and token metrics from output.jsonl."""
    metrics_data = {
        "api_time_seconds": 0.0,
        "api_calls": 0,
        "accumulated_cost": 0.0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
    }
    
    if not output_jsonl_path or not os.path.exists(output_jsonl_path):
        return metrics_data
    
    try:
        with open(output_jsonl_path, 'r') as f:
            for line in f:
                data = json.loads(line.strip())
                metrics = data.get("metrics", {})
                
                # Sum up response latencies to get total API time
                response_latencies = metrics.get("response_latencies", [])
                api_time = sum(l.get("latency", 0) for l in response_latencies)
                metrics_data["api_time_seconds"] += api_time
                metrics_data["api_calls"] += len(response_latencies)
                
                # Get accumulated cost
                metrics_data["accumulated_cost"] += metrics.get("accumulated_cost", 0)
                
                # Get token usage
                token_usage = metrics.get("accumulated_token_usage", {})
                metrics_data["prompt_tokens"] += token_usage.get("prompt_tokens", 0)
                metrics_data["completion_tokens"] += token_usage.get("completion_tokens", 0)
                metrics_data["cache_read_tokens"] += token_usage.get("cache_read_tokens", 0)
                metrics_data["cache_write_tokens"] += token_usage.get("cache_write_tokens", 0)
    except Exception as e:
        print(f"  [WARN] Error reading metrics from {output_jsonl_path}: {e}")
    
    return metrics_data

def extract_compute_time_from_log(log_path):
    """Extract total elapsed (compute) time from instance log."""
    if not log_path or not os.path.exists(log_path):
        return 0.0
    
    try:
        with open(log_path, 'r') as f:
            content = f.read()
            # Look for pattern: "elapsed: 766.1s" or similar
            match = re.search(r'elapsed:\s*([\d.]+)s', content)
            if match:
                return float(match.group(1))
    except Exception as e:
        print(f"  [WARN] Error reading compute time from {log_path}: {e}")
    
    return 0.0

# ─────────────────────────────────────────────────────────────────────────────
# Collect resolved/unresolved ids and timing metrics from each run
# ─────────────────────────────────────────────────────────────────────────────

run_resolved = OrderedDict()   # run_idx -> set of resolved ids
run_unresolved = OrderedDict() # run_idx -> set of unresolved ids
run_summaries = []
run_metrics = OrderedDict()    # run_idx -> timing metrics dict
all_instance_ids = set()

for run_idx in range(1, k + 1):
    run_dir = os.path.join(run_base, f"run_{run_idx}")
    rp = os.path.join(run_dir, "output.report.json")
    
    # Initialize metrics for this run
    run_metrics[run_idx] = {
        "compute_time_seconds": 0.0,
        "api_time_seconds": 0.0,
        "tool_execution_time_seconds": 0.0,
        "api_calls": 0,
        "accumulated_cost": 0.0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
    }
    
    if not os.path.exists(rp):
        print(f"  [WARN] run_{run_idx}/output.report.json missing")
        run_summaries.append({"run": run_idx, "status": "missing"})
        run_resolved[run_idx] = set()
        run_unresolved[run_idx] = set()
        continue

    with open(rp) as f:
        report = json.load(f)

    r_ids = set(report.get("resolved_ids", []))
    u_ids = set(report.get("unresolved_ids", []))
    resolved_count = report.get("resolved_instances", len(r_ids))
    total_count = report.get("total_instances", len(r_ids) + len(u_ids))

    run_resolved[run_idx] = r_ids
    run_unresolved[run_idx] = u_ids
    all_instance_ids.update(r_ids)
    all_instance_ids.update(u_ids)

    # Extract timing metrics
    output_jsonl = find_output_jsonl(run_dir)
    instance_log = find_instance_log(run_dir)
    
    output_metrics = extract_metrics_from_output(output_jsonl)
    compute_time = extract_compute_time_from_log(instance_log)
    
    api_time = output_metrics["api_time_seconds"]
    tool_time = max(0, compute_time - api_time)  # Compute - API = Tool execution
    
    run_metrics[run_idx] = {
        "compute_time_seconds": round(compute_time, 2),
        "api_time_seconds": round(api_time, 2),
        "tool_execution_time_seconds": round(tool_time, 2),
        "api_calls": output_metrics["api_calls"],
        "accumulated_cost": round(output_metrics["accumulated_cost"], 4),
        "prompt_tokens": output_metrics["prompt_tokens"],
        "completion_tokens": output_metrics["completion_tokens"],
        "cache_read_tokens": output_metrics["cache_read_tokens"],
        "cache_write_tokens": output_metrics["cache_write_tokens"],
    }

    run_summaries.append({
        "run": run_idx, "status": "ok",
        "resolved": resolved_count, "total": total_count,
        **run_metrics[run_idx],
    })
    print(f"  run_{run_idx}: {resolved_count}/{total_count} resolved")

all_instance_ids = sorted(all_instance_ids)
active_runs = [idx for idx in range(1, k + 1) if idx in run_resolved]

# Build per-instance results across runs
instance_results = {}
for iid in all_instance_ids:
    per_run = {}
    for run_idx in active_runs:
        if iid in run_resolved[run_idx]:
            per_run[run_idx] = True
        elif iid in run_unresolved[run_idx]:
            per_run[run_idx] = False
        else:
            per_run[run_idx] = None
    instance_results[iid] = per_run

passed = sum(1 for iid, runs in instance_results.items() if any(v is True for v in runs.values()))
total_i = len(all_instance_ids)
pass_k = passed / total_i if total_i > 0 else 0.0

# ─────────────────────────────────────────────────────────────────────────────
# Calculate aggregate timing metrics
# ─────────────────────────────────────────────────────────────────────────────

total_compute_time = sum(run_metrics[r]["compute_time_seconds"] for r in active_runs)
total_api_time = sum(run_metrics[r]["api_time_seconds"] for r in active_runs)
total_tool_time = sum(run_metrics[r]["tool_execution_time_seconds"] for r in active_runs)
total_api_calls = sum(run_metrics[r]["api_calls"] for r in active_runs)
total_cost = sum(run_metrics[r]["accumulated_cost"] for r in active_runs)
total_prompt_tokens = sum(run_metrics[r]["prompt_tokens"] for r in active_runs)
total_completion_tokens = sum(run_metrics[r]["completion_tokens"] for r in active_runs)

avg_compute_time = total_compute_time / len(active_runs) if active_runs else 0
avg_api_time = total_api_time / len(active_runs) if active_runs else 0
avg_tool_time = total_tool_time / len(active_runs) if active_runs else 0
avg_cost = total_cost / len(active_runs) if active_runs else 0

# ─────────────────────────────────────────────────────────────────────────────
# Print tabular report
# ─────────────────────────────────────────────────────────────────────────────

header_runs = [f"Run {r}" for r in active_runs]
id_width = max((len(iid) for iid in all_instance_ids), default=12)
id_width = max(id_width, len("Instance"))
col_width = max(7, max((len(h) for h in header_runs), default=7))
any_width = max(7, len("Any Pass"))

sep = "-" * id_width + "-+-" + ("-+-".join("-" * col_width for _ in active_runs)) + "-+-" + "-" * any_width
header = f"{'Instance':<{id_width}} | " + " | ".join(f"{h:^{col_width}}" for h in header_runs) + f" | {'Any Pass':^{any_width}}"

print(f"\n{'='*len(sep)}")
print(f"  Per-Instance Results: {dataset_tag} / {model}")
print(f"{'='*len(sep)}")
print(header)
print(sep)

for iid in all_instance_ids:
    runs = instance_results[iid]
    any_pass = any(v is True for v in runs.values())
    cells = []
    for run_idx in active_runs:
        v = runs.get(run_idx)
        if v is True:
            cells.append(f"{'PASS':^{col_width}}")
        elif v is False:
            cells.append(f"{'FAIL':^{col_width}}")
        else:
            cells.append(f"{'--':^{col_width}}")
    any_cell = f"{'YES':^{any_width}}" if any_pass else f"{'NO':^{any_width}}"
    print(f"{iid:<{id_width}} | " + " | ".join(cells) + f" | {any_cell}")

print(sep)

# Summary row
summary_cells = []
for run_idx in active_runs:
    run_pass = sum(1 for iid in all_instance_ids if instance_results[iid].get(run_idx) is True)
    summary_cells.append(f"{run_pass}/{total_i}".center(col_width))
print(f"{'TOTAL':<{id_width}} | " + " | ".join(summary_cells) + f" | {passed}/{total_i}".center(any_width + 3))

# ─────────────────────────────────────────────────────────────────────────────
# Print timing metrics summary
# ─────────────────────────────────────────────────────────────────────────────

def format_time(seconds):
    """Format seconds into human-readable string."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    elif seconds < 3600:
        return f"{seconds/60:.1f}m"
    else:
        return f"{seconds/3600:.1f}h"

print(f"\n{'='*80}")
print(f"  TIMING & COST METRICS")
print(f"{'='*80}")
print(f"\n  Per-Run Breakdown:")
print(f"  {'Run':<8} {'Compute Time':>14} {'API Time':>12} {'Tool Time':>12} {'API Calls':>10} {'Cost':>10}")
print(f"  {'-'*8} {'-'*14} {'-'*12} {'-'*12} {'-'*10} {'-'*10}")

for run_idx in active_runs:
    m = run_metrics[run_idx]
    print(f"  Run {run_idx:<4} {format_time(m['compute_time_seconds']):>14} "
          f"{format_time(m['api_time_seconds']):>12} "
          f"{format_time(m['tool_execution_time_seconds']):>12} "
          f"{m['api_calls']:>10} "
          f"${m['accumulated_cost']:>9.2f}")

print(f"  {'-'*8} {'-'*14} {'-'*12} {'-'*12} {'-'*10} {'-'*10}")
print(f"  {'TOTAL':<8} {format_time(total_compute_time):>14} "
      f"{format_time(total_api_time):>12} "
      f"{format_time(total_tool_time):>12} "
      f"{total_api_calls:>10} "
      f"${total_cost:>9.2f}")
print(f"  {'AVERAGE':<8} {format_time(avg_compute_time):>14} "
      f"{format_time(avg_api_time):>12} "
      f"{format_time(avg_tool_time):>12} "
      f"{total_api_calls // len(active_runs) if active_runs else 0:>10} "
      f"${avg_cost:>9.2f}")

print(f"\n  Token Usage (Total across all runs):")
print(f"    Prompt tokens:     {total_prompt_tokens:>12,}")
print(f"    Completion tokens: {total_completion_tokens:>12,}")

# Calculate API time percentage
api_pct = (total_api_time / total_compute_time * 100) if total_compute_time > 0 else 0
tool_pct = (total_tool_time / total_compute_time * 100) if total_compute_time > 0 else 0

print(f"\n  Time Distribution:")
print(f"    API Time:          {api_pct:>6.1f}% (waiting for LLM responses)")
print(f"    Tool Execution:    {tool_pct:>6.1f}% (running commands, file ops, etc.)")

print(f"\n{'='*60}")
print(f"  pass@{k} = {pass_k:.4f}  ({passed}/{total_i})")
print(f"  Dataset: {dataset_tag}  Model: {model}")
print(f"{'='*60}")

# ─────────────────────────────────────────────────────────────────────────────
# Write JSON summary with per-instance detail and timing metrics
# ─────────────────────────────────────────────────────────────────────────────

summary = {
    "metric": f"pass@{k}", "k": k, "language": lang, "model": model,
    "dataset": dataset_tag, "total_instances": total_i,
    "instances_with_any_pass": passed, "pass_at_k": round(pass_k, 4),
    
    # Aggregate timing metrics
    "timing_metrics": {
        "total": {
            "compute_time_seconds": round(total_compute_time, 2),
            "api_time_seconds": round(total_api_time, 2),
            "tool_execution_time_seconds": round(total_tool_time, 2),
            "api_calls": total_api_calls,
            "accumulated_cost_usd": round(total_cost, 4),
            "prompt_tokens": total_prompt_tokens,
            "completion_tokens": total_completion_tokens,
        },
        "average_per_run": {
            "compute_time_seconds": round(avg_compute_time, 2),
            "api_time_seconds": round(avg_api_time, 2),
            "tool_execution_time_seconds": round(avg_tool_time, 2),
            "accumulated_cost_usd": round(avg_cost, 4),
        },
        "time_distribution": {
            "api_time_percent": round(api_pct, 1),
            "tool_execution_percent": round(tool_pct, 1),
        },
    },
    
    "per_run": run_summaries,
    "per_instance": {
        iid: {
            f"run_{r}": ("PASS" if instance_results[iid].get(r) is True
                         else "FAIL" if instance_results[iid].get(r) is False
                         else "MISSING")
            for r in active_runs
        }
        for iid in all_instance_ids
    },
}
with open(summary_file, "w") as f:
    json.dump(summary, f, indent=2)

print(f"\n  Summary saved to: {summary_file}")
PYSCRIPT

    if [[ "$INSTANCE_COUNT" -eq 1 ]]; then
        python3 "$_SUMMARY_PY" "$RUN_BASE" "$K" "$LANG" "$MODEL_SHORT" "$DATASET_TAG" "$SUMMARY_FILE"
        log "pass@${K} summary: $SUMMARY_FILE"
    else
        log "Generating per-instance pass@${K} summaries for ${#INST_IDS[@]} instances..."
        _summary_ok=0
        _summary_fail=0
        for idx in "${!INST_IDS[@]}"; do
            inst_id="${INST_IDS[$idx]}"
            inst_run_base="${OUTPUT_BASE}/${inst_id}/${MODEL_SHORT}"
            inst_summary="${inst_run_base}/pass_at_${K}_summary.json"
            if python3 "$_SUMMARY_PY" "$inst_run_base" "$K" "$LANG" "$MODEL_SHORT" "$inst_id" "$inst_summary" >> "$LOG_FILE" 2>&1; then
                log "  [${inst_id}] pass@${K} summary: ${inst_summary}"
                _summary_ok=$((_summary_ok + 1))
            else
                log "  [${inst_id}] WARNING: Summary generation failed"
                _summary_fail=$((_summary_fail + 1))
            fi
        done
        log "Summary generation complete: ${_summary_ok} OK, ${_summary_fail} failed."
    fi
    rm -f "$_SUMMARY_PY"
fi

log ""
log "═══════════════════════════════════════════════════════════════"
log "  All done! Results in: ${RUN_BASE}/"
log "═══════════════════════════════════════════════════════════════"
