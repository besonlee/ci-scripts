#!/usr/bin/env bash
# CMS 前端 Release Tag 腳本（bo + customer）
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

# ─── Repo 定義 ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_BO="http://gitlab.mootech.asia/mttw-dev/cms-bo-frontend.git"
REPO_CUSTOMER="http://gitlab.mootech.asia/mttw-dev/cms-customer-frontend.git"
DIR_BO="$SCRIPT_DIR/cms-bo-frontend"
DIR_CUSTOMER="$SCRIPT_DIR/cms-customer-frontend"

# ─── 預設值 ──────────────────────────────────────────────────
TAG_VERSION=""
DRY_RUN=false
DO_UAT=false
DO_MASTER=false
REPO_TARGET=""   # 空 = 兩個；bo / customer = 單一

# ─── 說明 ────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}用法:${RESET}
  $0 -u|-m|-um [-t <version>] [options]

${BOLD}合版目標（至少選一）:${RESET}
  -u              合併 develop → uat（bo + customer）
  -m              合併 uat → master 並建立 git tag（-t 省略則自動 patch +1）
  -um / -u -m     兩步驟都執行（完整 release）

${BOLD}選填:${RESET}
  -t <version>    版本 tag，例如: v1.2.3（-m 時省略則自動遞增）
  -r <repo>       指定單一 repo：bo 或 customer（省略則兩個都跑）
  -n              Dry run：只印出指令，不實際執行
  -h              顯示此說明

${BOLD}Repos:${RESET}
  bo       →  $REPO_BO
  customer →  $REPO_CUSTOMER

${BOLD}範例:${RESET}
  $0 -u                     # 只合 develop → uat（兩個前端 repo）
  $0 -u -r bo               # 只合 develop → uat（只有 bo）
  $0 -m                     # 只合 uat → master + tag（自動遞增版號）
  $0 -m -t v1.2.3           # 只合 uat → master + 指定版號
  $0 -m -r customer         # 只跑 customer repo
  $0 -um                    # 完整 release（develop → uat → master → tag）
  $0 -um -r bo -t v1.2.3    # 完整 release，只跑 bo，指定版號
  $0 -um -n                 # dry run
EOF
    exit 0
}

# ─── 解析參數 ────────────────────────────────────────────────
while getopts "t:r:umnh" opt; do
    case "$opt" in
        t) TAG_VERSION="$OPTARG" ;;
        r) REPO_TARGET="$OPTARG" ;;
        u) DO_UAT=true ;;
        m) DO_MASTER=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

if ! $DO_UAT && ! $DO_MASTER; then
    error "請指定合版目標：-u（合到 uat）、-m（合到 master）或 -um（兩者）"
fi

case "$REPO_TARGET" in
    bo|customer|"") ;;
    *) error "無效的 repo：$REPO_TARGET（可用: bo, customer）" ;;
esac

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
echo -e "${BOLD}║   CMS Frontend Release Tag       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════╝${RESET}"
$DO_UAT    && info "步驟:      develop → uat"
$DO_MASTER && info "步驟:      uat → master + tag"
$DO_MASTER && info "版本 tag:  ${TAG_VERSION:-"(自動遞增)"}"
info "目標 repo: ${REPO_TARGET:-"bo + customer"}"
$DRY_RUN && warn "DRY-RUN 模式，不會實際執行"

# ─── 處理單一 repo ───────────────────────────────────────────
process_repo() {
    local REPO_URL="$1"
    local SOURCE_DIR="$2"
    local REPO_NAME
    REPO_NAME="$(basename "$REPO_URL" .git)"

    # ─── Clone / Fetch ───────────────────────────────────────
    if [[ ! -d "$SOURCE_DIR/.git" ]]; then
        if [[ ! -d "$SOURCE_DIR" ]]; then
            step "Clone $REPO_NAME"
            run git clone "$REPO_URL" "$SOURCE_DIR"
            success "Clone 完成"
        else
            error "$SOURCE_DIR 已存在但不是 git repo，請移除後重試"
        fi
    fi

    step "Fetch $REPO_NAME"
    run git -C "$SOURCE_DIR" fetch origin
    success "Fetch 完成"

    # ─── 版號決定（DO_MASTER 時，先於 merge 以便 message 使用）─
    if $DO_MASTER; then
        local LATEST_TAG LATEST_VER INPUT_VER LOWER MAJOR MINOR PATCH
        LATEST_TAG=$(git -C "$SOURCE_DIR" tag --sort=-version:refname | head -1)
        if [[ -z "$TAG_VERSION" ]]; then
            if [[ -z "$LATEST_TAG" ]]; then
                error "$REPO_NAME 尚無任何 tag，請使用 -t <version> 指定初始版號"
            fi
            LATEST_VER="${LATEST_TAG#v}"
            IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_VER"
            PATCH=$(( PATCH + 1 ))
            TAG_VERSION="v${MAJOR}.${MINOR}.${PATCH}"
            info "自動遞增版號: $LATEST_TAG → $TAG_VERSION ($REPO_NAME)"
        elif [[ -n "$LATEST_TAG" ]]; then
            LATEST_VER="${LATEST_TAG#v}"
            INPUT_VER="${TAG_VERSION#v}"
            LOWER=$(printf "%s\n%s" "$LATEST_VER" "$INPUT_VER" | sort -V | head -1)
            if [[ "$LOWER" != "$LATEST_VER" || "$INPUT_VER" == "$LATEST_VER" ]]; then
                error "版號 $TAG_VERSION 不合法（$REPO_NAME），目前最新 tag 為 $LATEST_TAG，新版號必須更大"
            fi
            info "版號檢查通過: $LATEST_TAG → $TAG_VERSION ($REPO_NAME)"
        else
            info "尚無既有 tag，直接建立 $TAG_VERSION"
        fi
    fi

    # ─── 合併 develop → uat ──────────────────────────────────
    if $DO_UAT; then
        step "合併 develop → uat ($REPO_NAME)"
        run git -C "$SOURCE_DIR" checkout uat
        run git -C "$SOURCE_DIR" pull origin uat
        local MERGE_MSG="Merge branch 'develop' into uat"
        $DO_MASTER && MERGE_MSG="$MERGE_MSG for release $TAG_VERSION"
        run git -C "$SOURCE_DIR" merge --no-ff origin/develop -m "$MERGE_MSG"
        run git -C "$SOURCE_DIR" push origin uat
        success "develop 已合併至 uat 並推送"
    fi

    # ─── 合併 uat → master + tag ─────────────────────────────
    if $DO_MASTER; then
        step "合併 uat → master ($REPO_NAME)"
        run git -C "$SOURCE_DIR" checkout master
        run git -C "$SOURCE_DIR" pull origin master
        run git -C "$SOURCE_DIR" merge --no-ff origin/uat -m "Merge branch 'uat' into master for release $TAG_VERSION"
        run git -C "$SOURCE_DIR" push origin master
        success "uat 已合併至 master 並推送"

        step "建立 git tag: $TAG_VERSION ($REPO_NAME)"
        run git -C "$SOURCE_DIR" tag "$TAG_VERSION"
        run git -C "$SOURCE_DIR" push origin "$TAG_VERSION"
        success "Git tag 已建立並推送: $TAG_VERSION"
    fi
}

# ─── 執行 repo ───────────────────────────────────────────────
case "$REPO_TARGET" in
    bo)       process_repo "$REPO_BO"       "$DIR_BO" ;;
    customer) process_repo "$REPO_CUSTOMER" "$DIR_CUSTOMER" ;;
    *)        process_repo "$REPO_BO"       "$DIR_BO"
              process_repo "$REPO_CUSTOMER" "$DIR_CUSTOMER" ;;
esac

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║         完成！                   ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════╝${RESET}"
$DO_MASTER && info "下一步: ./deploy-frontend.sh -e prod -s all"
