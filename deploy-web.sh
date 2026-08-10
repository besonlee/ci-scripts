#!/usr/bin/env bash
# CMS 前台前端 Docker 打包推送腳本
# 用法: ./deploy-web.sh -e <env> [-b <branch>]
# 每次執行會固定打包 customer / orange / purple 三個版本（不再分服務選擇）

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
REPO_CUSTOMER="http://gitlab.mootech.asia/mttw-dev/cms-customer-frontend.git"

# ─── 預設值 ──────────────────────────────────────────────────
ENV=""
BRANCH=""
DRY_RUN=false
SHA_TAG=false

# ─── 說明 ────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}用法:${RESET}
  $0 -e <env> [options]

${BOLD}必填:${RESET}
  -e <env>        環境: uat | prod

${BOLD}選填:${RESET}
  -b <branch>     覆蓋分支（預設: uat→theme-purple, prod→master-orange）
  -t              同時推送 Git SHA tag（僅 uat 有效，預設不推）
  -n              Dry run：只印出指令，不實際執行
  -h              顯示此說明

${BOLD}固定打包內容:${RESET}
  每次執行都會打包 customer / orange / purple 三個版本（不分服務選擇）。

${BOLD}Prod 流程:${RESET}
  請先執行 ./tag-web.sh -um 完成合版與打 tag，
  再執行 ./deploy-web.sh -e prod，會自動取用最新 tag 作為 image tag。

${BOLD}環境對應 Registry / 分支:${RESET}
  uat  →  registry.mootech.asia/mttw-dev/docker-images  (branch: theme-purple)
  prod →  registry.mootech.asia/mttw-dev/docker-images  (branch: master-orange, image 名稱加 -prod)

${BOLD}前台 Repo:${RESET}
  customer →  $REPO_CUSTOMER

${BOLD}範例:${RESET}
  $0 -e uat
  $0 -e prod
  $0 -e uat -b feature/xxx
  $0 -e uat -n                             # dry run
EOF
    exit 0
}

# ─── 解析參數 ────────────────────────────────────────────────
while getopts "e:b:tnh" opt; do
    case "$opt" in
        e) ENV="$OPTARG" ;;
        b) BRANCH="$OPTARG" ;;
        t) SHA_TAG=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─── 驗證 ────────────────────────────────────────────────────
[[ -z "$ENV" ]] && error "必須指定環境 -e uat|prod"
[[ "$ENV" != "uat" && "$ENV" != "prod" ]] && error "環境必須是 uat 或 prod，收到: $ENV"

if [[ -z "$BRANCH" ]]; then
    case "$ENV" in
        uat)  BRANCH="theme-purple" ;;
        prod) BRANCH="master-orange" ;;
    esac
fi

# ─── Registry 設定 ───────────────────────────────────────────
if [[ "$ENV" == "uat" ]]; then
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
echo -e "${BOLD}║  CMS Customer Frontend Deploy    ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════╝${RESET}"
info "環境:      $ENV"
info "Registry:  $REGISTRY"
info "Branch:    $BRANCH"
$SHA_TAG && info "SHA Tag:   啟用（-t）"
$DRY_RUN && warn "DRY-RUN 模式，不會實際執行"

# ─── Build helpers ───────────────────────────────────────────
# TAG_VERSION / GIT_SHA 由各 build 函式在呼叫前設定
TAG_VERSION=""
GIT_SHA=""

sync_repo() {
    local REPO_URL="$1"
    local SOURCE_DIR="$2"
    local TARGET_BRANCH="${3:-$BRANCH}"
    local REPO_NAME
    REPO_NAME="$(basename "$REPO_URL" .git)"

    step "取得原始碼: $REPO_NAME"
    if [[ ! -d "$SOURCE_DIR" ]]; then
        info "目錄不存在，執行 clone: $REPO_URL → $SOURCE_DIR"
        run git clone --branch "$TARGET_BRANCH" "$REPO_URL" "$SOURCE_DIR"
        success "Clone 完成"
    elif [[ -d "$SOURCE_DIR/.git" ]]; then
        info "切換至 branch: $TARGET_BRANCH"
        run git -C "$SOURCE_DIR" fetch origin
        run git -C "$SOURCE_DIR" checkout "$TARGET_BRANCH"
        run git -C "$SOURCE_DIR" pull origin "$TARGET_BRANCH"
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

    # 加入 git sha tag（prod 不加；uat 需明確指定 -t 才推）
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

build_customer() {
    local SOURCE_DIR="$SCRIPT_DIR/cms-customer-frontend"
    sync_repo "$REPO_CUSTOMER" "$SOURCE_DIR"

    TAG_VERSION=""
    if [[ "$ENV" == "prod" ]]; then
        TAG_VERSION=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
        [[ -z "$TAG_VERSION" ]] && error "cms-customer-frontend 找不到任何 git tag，請先執行 ./tag-web.sh -m"
        info "使用最新 tag: $TAG_VERSION"
    fi

    GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    info "Git SHA:   $GIT_SHA"

    build_and_push "Customer Frontend" \
        "$SOURCE_DIR" \
        "$REGISTRY/cms-customer-frontend${IMAGE_SUFFIX}:latest"
}

build_customer_orange() {
    local SOURCE_DIR="$SCRIPT_DIR/cms-customer-frontend"
    sync_repo "$REPO_CUSTOMER" "$SOURCE_DIR"

    TAG_VERSION=""
    if [[ "$ENV" == "prod" ]]; then
        TAG_VERSION=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
        [[ -z "$TAG_VERSION" ]] && error "cms-customer-frontend 找不到任何 git tag，請先執行 ./tag-web.sh -m"
        info "使用最新 tag: $TAG_VERSION"
        TAG_VERSION="${TAG_VERSION}-orange"
    fi

    GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    info "Git SHA:   $GIT_SHA"

    build_and_push "Customer Frontend (Orange)" \
        "$SOURCE_DIR" \
        "$REGISTRY/cms-player-web${IMAGE_SUFFIX}-orange:latest"
}

build_customer_purple() {
    local SOURCE_DIR="$SCRIPT_DIR/cms-customer-frontend"
    sync_repo "$REPO_CUSTOMER" "$SOURCE_DIR"

    TAG_VERSION=""
    if [[ "$ENV" == "prod" ]]; then
        TAG_VERSION=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
        [[ -z "$TAG_VERSION" ]] && error "cms-customer-frontend ($BRANCH) 找不到任何 git tag，請先執行 ./tag-web.sh -m"
        info "使用最新 tag: $TAG_VERSION"
    fi

    GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    info "Git SHA:   $GIT_SHA"

    build_and_push "Customer Frontend (Purple)" \
        "$SOURCE_DIR" \
        "$REGISTRY/cms-player-web${IMAGE_SUFFIX}:latest"
}

# ─── 執行 Build（固定打包 customer / orange / purple）────────
FAILED=()

for FN in build_customer build_customer_orange build_customer_purple; do
    if ! "$FN"; then
        FAILED+=("$FN")
    fi
done

# ─── 結果摘要 ────────────────────────────────────────────────
echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "以下服務失敗: ${FAILED[*]}"
else
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║ Customer Frontend Deploy 全部完成！║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════╝${RESET}"
fi
