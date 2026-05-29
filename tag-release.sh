#!/usr/bin/env bash
# CMS Release Tag 腳本
# 流程: develop → uat → master → git tag

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
REPO_URL="http://gitlab.mootech.asia/mttw-dev/cms-main-backend.git"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)/cms-main-backend"
TAG_VERSION=""
DRY_RUN=false
DO_UAT=false
DO_MASTER=false

# ─── 說明 ────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}用法:${RESET}
  $0 -u|-m|-um [-t <version>] [options]

${BOLD}合版目標（至少選一）:${RESET}
  -u              合併 develop → uat
  -m              合併 uat → master 並建立 git tag
  -um / -u -m     兩步驟都執行（完整 release）

${BOLD}選填:${RESET}
  -t <version>    版本 tag，例如: v1.2.3（-m 時省略則自動 patch +1）
  -d <dir>        原始碼目錄（預設: 腳本目錄/cms-main-backend）
  -n              Dry run：只印出指令，不實際執行
  -h              顯示此說明

${BOLD}範例:${RESET}
  $0 -u              # 只合 develop → uat
  $0 -m              # 只合 uat → master + tag（自動遞增版號）
  $0 -m -t v1.2.3    # 只合 uat → master + 指定版號
  $0 -um             # 完整 release（develop → uat → master → tag）
  $0 -um -n          # dry run
EOF
    exit 0
}

# ─── 解析參數 ────────────────────────────────────────────────
while getopts "t:d:umnh" opt; do
    case "$opt" in
        t) TAG_VERSION="$OPTARG" ;;
        d) SOURCE_DIR="$OPTARG" ;;
        u) DO_UAT=true ;;
        m) DO_MASTER=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 至少要選一個目標
if ! $DO_UAT && ! $DO_MASTER; then
    error "請指定合版目標：-u（合到 uat）、-m（合到 master）或 -um（兩者）"
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
echo -e "${BOLD}║     CMS Release Tag          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════╝${RESET}"
$DO_UAT    && info "步驟:      develop → uat"
$DO_MASTER && info "步驟:      uat → master + tag"
$DO_MASTER && info "版本 tag:  ${TAG_VERSION:-"(自動遞增)"}"
info "原始碼:    $SOURCE_DIR"
$DRY_RUN && warn "DRY-RUN 模式，不會實際執行"

# ─── 確認 repo 存在 ──────────────────────────────────────────
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    if [[ ! -d "$SOURCE_DIR" ]]; then
        step "Clone repo"
        run git clone "$REPO_URL" "$SOURCE_DIR"
        success "Clone 完成"
    else
        error "$SOURCE_DIR 已存在但不是 git repo，請移除後重試"
    fi
fi

# ─── Fetch ───────────────────────────────────────────────────
step "Fetch origin"
run git -C "$SOURCE_DIR" fetch origin
success "Fetch 完成"

# ─── 版號決定（只有 -m 才需要）──────────────────────────────
if $DO_MASTER; then
    LATEST_TAG=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
    if [[ -z "$TAG_VERSION" ]]; then
        if [[ -z "$LATEST_TAG" ]]; then
            error "repo 尚無任何 tag，無法自動遞增，請使用 -t <version> 指定初始版號"
        fi
        LATEST_VER="${LATEST_TAG#v}"
        IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_VER"
        PATCH=$(( PATCH + 1 ))
        TAG_VERSION="v${MAJOR}.${MINOR}.${PATCH}"
        info "自動遞增版號: $LATEST_TAG → $TAG_VERSION"
    elif [[ -n "$LATEST_TAG" ]]; then
        LATEST_VER="${LATEST_TAG#v}"
        INPUT_VER="${TAG_VERSION#v}"
        LOWER=$(printf "%s\n%s" "$LATEST_VER" "$INPUT_VER" | sort -V | head -1)
        if [[ "$LOWER" != "$LATEST_VER" || "$INPUT_VER" == "$LATEST_VER" ]]; then
            error "版號 $TAG_VERSION 不合法，目前最新 tag 為 $LATEST_TAG，新版號必須更大"
        fi
        info "版號檢查通過: $LATEST_TAG → $TAG_VERSION"
    else
        info "尚無既有 tag，直接建立 $TAG_VERSION"
    fi
fi

# ─── 合併 develop → uat ──────────────────────────────────────
if $DO_UAT; then
    step "合併 develop → uat"
    run git -C "$SOURCE_DIR" checkout uat
    run git -C "$SOURCE_DIR" pull origin uat
    MERGE_MSG="Merge branch 'develop' into uat"
    $DO_MASTER && MERGE_MSG="$MERGE_MSG for release $TAG_VERSION"
    run git -C "$SOURCE_DIR" merge --no-ff origin/develop -m "$MERGE_MSG"
    run git -C "$SOURCE_DIR" push origin uat
    success "develop 已合併至 uat 並推送"
fi

# ─── 合併 uat → master ───────────────────────────────────────
if $DO_MASTER; then
    step "合併 uat → master"
    run git -C "$SOURCE_DIR" checkout master
    run git -C "$SOURCE_DIR" pull origin master
    run git -C "$SOURCE_DIR" merge --no-ff origin/uat -m "Merge branch 'uat' into master for release $TAG_VERSION"
    run git -C "$SOURCE_DIR" push origin master
    success "uat 已合併至 master 並推送"

    step "建立 git tag: $TAG_VERSION"
    run git -C "$SOURCE_DIR" tag "$TAG_VERSION"
    run git -C "$SOURCE_DIR" push origin "$TAG_VERSION"
    success "Git tag 已建立並推送: $TAG_VERSION"
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║         完成！               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════╝${RESET}"
$DO_MASTER && info "下一步: ./deploy.sh -e prod -s all"
