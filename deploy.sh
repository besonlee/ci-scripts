#!/usr/bin/env bash
# CMS 多服務 Docker 打包推送腳本
# 用法: ./deploy.sh -e <env> [-s <service>] [-d <source_dir>] [-b <branch>]

set -euo pipefail

# ─── 顏色輸出 ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ─── 預設值 ──────────────────────────────────────────────────
ENV=""
SERVICES=()
REPO_URL="http://gitlab.mootech.asia/mttw-dev/cms-main-backend.git"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)/cms-main-backend"
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
  -s <service>    服務: bo | player | partner | wallet | all（預設: all）
                  可多次指定，例如: -s bo -s player
  -d <dir>        原始碼目錄（預設: 腳本目錄/cms-main-backend）
                  若目錄不存在則自動 clone，已存在則 pull
  -b <branch>     覆蓋分支（預設: dev→develop, uat→uat, prod→master）
  -t              同時推送 Git SHA tag（僅 dev/uat 有效，預設不推）
  -n              Dry run：只印出指令，不實際執行
  -h              顯示此說明

${BOLD}Prod 流程:${RESET}
  請先執行 ./tag-release.sh -t <version> 完成合併與打 tag，
  再執行 ./deploy.sh -e prod，會自動取用最新 tag 作為 image tag。

${BOLD}環境對應 Registry:${RESET}
  dev  →  192.168.111.88:5001
  uat  →  registry.mootech.asia/mttw-dev/docker-images
  prod →  registry.mootech.asia/mttw-dev/docker-images  (image 名稱加 -prod)

${BOLD}範例:${RESET}
  $0 -e dev -s all
  $0 -e uat -s bo -s wallet
  $0 -e prod -s all
  $0 -e dev -b feature/xxx
  $0 -e dev -n                             # dry run
EOF
    exit 0
}

# ─── 解析參數 ────────────────────────────────────────────────
while getopts "e:s:d:b:tnh" opt; do
    case "$opt" in
        e) ENV="$OPTARG" ;;
        s) SERVICES+=("$OPTARG") ;;
        d) SOURCE_DIR="$OPTARG" ;;
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

# 依環境自動設定預設分支
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
echo -e "\n${BOLD}╔══════════════════════════════╗${RESET}"
echo -e "${BOLD}║     CMS Deploy Script        ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════╝${RESET}"
info "環境:      $ENV"
info "Registry:  $REGISTRY"
info "Repo:      $REPO_URL"
info "Branch:    $BRANCH"
info "原始碼:    $SOURCE_DIR"
info "服務:      ${SERVICES[*]}"
$SHA_TAG && info "SHA Tag:   啟用（-t）"
$DRY_RUN && warn "DRY-RUN 模式，不會實際執行"

# ─── Git clone / pull ────────────────────────────────────────
step "取得原始碼 (git)"
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

# prod 自動取最新 tag 作為 image 版本
TAG_VERSION=""
if [[ "$ENV" == "prod" ]]; then
    TAG_VERSION=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
    [[ -z "$TAG_VERSION" ]] && error "找不到任何 git tag，請先執行 ./tag-release.sh -t <version>"
    info "使用最新 tag:  $TAG_VERSION"
fi

GIT_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
info "Git SHA:   $GIT_SHA"

# ─── Test helper ─────────────────────────────────────────────
run_go_tests() {
    local APP_NAME="$1"
    local APP_DIR="$2"
    step "Test $APP_NAME"
    [[ ! -d "$APP_DIR" ]] && error "目錄不存在: $APP_DIR"
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${RESET} (cd \"$APP_DIR\" && go test -v ./test)"
    else
        (cd "$APP_DIR" && go test -v ./test) || error "$APP_NAME 測試失敗，中止部署"
    fi
    success "$APP_NAME 測試通過"
}

# ─── Build helpers ───────────────────────────────────────────
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
        --build-arg "VERSION=$TAG_VERSION" \
        "${TAG_ARGS[@]}" \
        "$APP_DIR"

    for TAG in "${TAGS[@]}"; do
        run docker push "$TAG"
        success "已推送: $TAG"
    done
}

build_bo() {
    run_go_tests "Bo API" "$SOURCE_DIR/apps/bo"
    build_and_push "Bo API" \
        "$SOURCE_DIR/apps/bo" \
        "$REGISTRY/cms-bo-api${IMAGE_SUFFIX}:latest"
}

build_player() {
    run_go_tests "Player API" "$SOURCE_DIR/apps/player"
    build_and_push "Player API" \
        "$SOURCE_DIR/apps/player" \
        "$REGISTRY/cms-player-api${IMAGE_SUFFIX}:latest"
}

build_partner() {
    run_go_tests "Partner API" "$SOURCE_DIR/apps/partner"
    build_and_push "Partner API" \
        "$SOURCE_DIR/apps/partner" \
        "$REGISTRY/cms-partner-api${IMAGE_SUFFIX}:latest"
}

build_wallet() {
    run_go_tests "Wallet API + Worker" "$SOURCE_DIR/apps/wallet"
    build_and_push "Wallet API + Worker" \
        "$SOURCE_DIR/apps/wallet" \
        "$REGISTRY/cms-wallet-api${IMAGE_SUFFIX}:latest" \
        "$REGISTRY/cms-worker-api${IMAGE_SUFFIX}:latest"
}

# ─── 執行 Build ──────────────────────────────────────────────
FAILED=()

build_service() {
    local SVC="$1"
    case "$SVC" in
        bo)      build_bo ;;
        player)  build_player ;;
        partner) build_partner ;;
        wallet)  build_wallet ;;
        all)
            build_bo
            build_player
            build_partner
            build_wallet
            ;;
        *) error "未知服務: $SVC，可選: bo | player | partner | wallet | all" ;;
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
    echo -e "${GREEN}${BOLD}╔══════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║     Deploy 全部完成！        ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════╝${RESET}"
fi
