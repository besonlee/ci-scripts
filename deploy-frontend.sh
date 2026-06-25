#!/usr/bin/env bash
# CMS 前端 Docker 打包推送腳本
# 用法: ./deploy-frontend.sh -e <env> [-s <service>] [-b <branch>]

set -euo pipefail

# ─── 顏色輸出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ─── Repo 定義 ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_BO="http://gitlab.mootech.asia/mttw-dev/cms-bo-frontend.git"
REPO_CUSTOMER="http://gitlab.mootech.asia/mttw-dev/cms-customer-frontend.git"

# ─── 預設值 ──────────────────────────────────────────────────
ENV=""
SERVICES=()
BRANCH=""
DRY_RUN=false
SHA_TAG=false

# ─── 說明 ────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}用法:${RESET}
  $0 -e <env> [options]

${BOLD}必填:${RESET}
  -e <env>        環境: dev | uat | prod

${BOLD}選填:${RESET}
  -s <service>    服務: bo | customer | all（預設: all）
                  可多次指定，例如: -s bo -s customer
  -b <branch>     覆蓋分支（預設: dev→develop, uat→uat, prod→master）
  -t              同時推送 Git SHA tag（僅 dev/uat 有效，預設不推）
  -n              Dry run：只印出指令，不實際執行
  -h              顯示此說明

${BOLD}Prod 流程:${RESET}
  請先執行 ./tag-release-frontend.sh -um 完成合版與打 tag，
  再執行 ./deploy-frontend.sh -e prod，會自動取用最新 tag 作為 image tag。

${BOLD}環境對應 Registry:${RESET}
  dev  →  192.168.111.88:5001
  uat  →  registry.mootech.asia/mttw-dev/docker-images
  prod →  registry.mootech.asia/mttw-dev/docker-images  (image 名稱加 -prod)

${BOLD}前端 Repos:${RESET}
  bo       →  $REPO_BO
  customer →  $REPO_CUSTOMER

${BOLD}範例:${RESET}
  $0 -e dev -s all
  $0 -e uat -s bo
  $0 -e prod -s all
  $0 -e dev -b feature/xxx
  $0 -e dev -n                             # dry run
EOF
    exit 0
}

# ─── 解析參數 ────────────────────────────────────────────────
while getopts "e:s:b:tnh" opt; do
    case "$opt" in
        e) ENV="$OPTARG" ;;
        s) SERVICES+=("$OPTARG") ;;
        b) BRANCH="$OPTARG" ;;
        t) SHA_TAG=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─── 驗證 ────────────────────────────────────────────────────
[[ -z "$ENV" ]] && error "必須指定環境 -e dev|uat|prod"
[[ "$ENV" != "dev" && "$ENV" != "uat" && "$ENV" != "prod" ]] && error "環境必須是 dev、uat 或 prod，收到: $ENV"

if [[ -z "$BRANCH" ]]; then
    case "$ENV" in
        dev)  BRANCH="develop" ;;
        uat)  BRANCH="uat" ;;
        prod) BRANCH="master" ;;
    esac
fi

[[ ${#SERVICES[@]} -eq 0 ]] && SERVICES=("all")

# ─── Registry 設定 ───────────────────────────────────────────
if [[ "$ENV" == "dev" ]]; then
    REGISTRY="192.168.111.88:5001"
    IMAGE_SUFFIX=""
elif [[ "$ENV" == "uat" ]]; then
    REGISTRY="registry.mootech.asia/mttw-dev/docker-images"
    IMAGE_SUFFIX=""
else
    REGISTRY="registry.mootech.asia/mttw-dev/docker-images"
    IMAGE_SUFFIX="-prod"
fi

# ─── 執行或 dry-run 包裝 ─────────────────────────────────────
run() {
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${RESET} $*"
    else
        "$@"
    fi
}

# ─── 摘要輸出 ────────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   CMS Frontend Deploy Script     ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════╝${RESET}"
info "環境:      $ENV"
info "Registry:  $REGISTRY"
info "Branch:    $BRANCH"
info "服務:      ${SERVICES[*]}"
$SHA_TAG && info "SHA Tag:   啟用（-t）"
$DRY_RUN && warn "DRY-RUN 模式，不會實際執行"

# ─── Build helpers ───────────────────────────────────────────
# TAG_VERSION / GIT_SHA 由各 build 函式在呼叫前設定
TAG_VERSION=""
GIT_SHA=""

sync_repo() {
    local REPO_URL="$1"
    local SOURCE_DIR="$2"
    local REPO_NAME
    REPO_NAME="$(basename "$REPO_URL" .git)"

    step "取得原始碼: $REPO_NAME"
    if [[ ! -d "$SOURCE_DIR" ]]; then
        info "目錄不存在，執行 clone: $REPO_URL → $SOURCE_DIR"
        run git clone --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR"
        success "Clone 完成"
    elif [[ -d "$SOURCE_DIR/.git" ]]; then
        info "切換至 branch: $BRANCH"
        run git -C "$SOURCE_DIR" fetch origin
        run git -C "$SOURCE_DIR" checkout "$BRANCH"
        run git -C "$SOURCE_DIR" pull origin "$BRANCH"
        success "原始碼更新完成"
    else
        error "$SOURCE_DIR 已存在但不是 git repo，請移除後重試"
    fi
}

build_and_push() {
    local SERVICE_NAME="$1"
    local APP_DIR="$2"
    shift 2
    local BASE_TAGS=("$@")
    local TAGS=("${BASE_TAGS[@]}")

    # prod 環境同時帶版本 tag 一起 build
    if [[ -n "$TAG_VERSION" ]]; then
        for TAG in "${BASE_TAGS[@]}"; do
            TAGS+=("${TAG%:*}:${TAG_VERSION}")
        done
    fi

    # 加入 git sha tag（prod 不加；dev/uat 需明確指定 -t 才推）
    if [[ "$ENV" != "prod" ]] && $SHA_TAG; then
        for TAG in "${BASE_TAGS[@]}"; do
            TAGS+=("${TAG%:*}:${GIT_SHA}")
        done
    fi

    step "Build $SERVICE_NAME"
    [[ ! -d "$APP_DIR" ]] && error "目錄不存在: $APP_DIR"

    local TAG_ARGS=()
    for TAG in "${TAGS[@]}"; do
        TAG_ARGS+=("-t" "$TAG")
    done

    run docker buildx build \
        --platform linux/amd64 \
        --load \
        "${TAG_ARGS[@]}" \
        "$APP_DIR"

    for TAG in "${TAGS[@]}"; do
        run docker push "$TAG"
        success "已推送: $TAG"
    done
}

build_bo() {
    local SOURCE_DIR="$SCRIPT_DIR/cms-bo-frontend"
    sync_repo "$REPO_BO" "$SOURCE_DIR"

    TAG_VERSION=""
    if [[ "$ENV" == "prod" ]]; then
        TAG_VERSION=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
        [[ -z "$TAG_VERSION" ]] && error "cms-bo-frontend 找不到任何 git tag，請先執行 ./tag-release-frontend.sh -m"
        info "使用最新 tag: $TAG_VERSION"
    fi

    GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    info "Git SHA:   $GIT_SHA"

    build_and_push "BO Frontend" \
        "$SOURCE_DIR" \
        "$REGISTRY/cms-bo-frontend${IMAGE_SUFFIX}:latest"
}

build_customer() {
    local SOURCE_DIR="$SCRIPT_DIR/cms-customer-frontend"
    sync_repo "$REPO_CUSTOMER" "$SOURCE_DIR"

    TAG_VERSION=""
    if [[ "$ENV" == "prod" ]]; then
        TAG_VERSION=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
        [[ -z "$TAG_VERSION" ]] && error "cms-customer-frontend 找不到任何 git tag，請先執行 ./tag-release-frontend.sh -m"
        info "使用最新 tag: $TAG_VERSION"
    fi

    GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    info "Git SHA:   $GIT_SHA"

    build_and_push "Customer Frontend" \
        "$SOURCE_DIR" \
        "$REGISTRY/cms-customer-frontend${IMAGE_SUFFIX}:latest"
}

# ─── 執行 Build ──────────────────────────────────────────────
FAILED=()

build_service() {
    local SVC="$1"
    case "$SVC" in
        bo)       build_bo ;;
        customer) build_customer ;;
        all)
            build_bo
            build_customer
            ;;
        *) error "未知服務: $SVC，可選: bo | customer | all" ;;
    esac
}

for SVC in "${SERVICES[@]}"; do
    if ! build_service "$SVC"; then
        FAILED+=("$SVC")
    fi
done

# ─── 結果摘要 ────────────────────────────────────────────────
echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "以下服務失敗: ${FAILED[*]}"
else
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║   Frontend Deploy 全部完成！     ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════╝${RESET}"
fi

# player Orange
# docker buildx build --platform linux/amd64 --load \
# -t registry.mootech.asia/mttw-dev/docker-images/cms-player-web-prod-orange:latest \
# -t registry.mootech.asia/mttw-dev/docker-images/cms-player-web-prod-orange:v0.0.1-orange \
#   .

# docker push registry.mootech.asia/mttw-dev/docker-images/cms-player-web-prod-orange:latest
# docker push registry.mootech.asia/mttw-dev/docker-images/cms-player-web-prod-orange:v0.0.1-orange
