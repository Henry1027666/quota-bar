#!/bin/zsh
# Quota Bar 发布脚本：构建 release → 打包 .app → 压缩 zip → git tag → 推送 →
# 通过 GitHub REST API 创建 Release 并上传 zip（不依赖 gh CLI）。
#
# 用法: ./release.sh <版本号>   例如 ./release.sh 0.2.0
# 前置: git 凭据助手（osxkeychain）里已存有 GitHub token；
#       若 github.com 直连不通，自动尝试 127.0.0.1:7890 本地代理。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

if [[ $# -lt 1 ]]; then
    echo "用法: ./release.sh <版本号>   例如 ./release.sh 0.2.0" >&2
    exit 1
fi
VERSION="$1"
TAG="v$VERSION"
APP_DIR="$project_dir/.build/QuotaBar.app"
ZIP="$project_dir/.build/QuotaBar-$TAG-macOS.zip"
REPO="Henry1027666/quota-bar"

# 网络：github.com 直连不通时回退本地代理
GIT_PROXY_ARGS=()
CURL_PROXY_ARGS=()
if ! curl -sS -o /dev/null --max-time 8 https://github.com 2>/dev/null; then
    if curl -sS -o /dev/null --max-time 8 -x http://127.0.0.1:7890 https://github.com 2>/dev/null; then
        echo "==> github.com 直连不通，使用本地代理 127.0.0.1:7890"
        GIT_PROXY_ARGS=(-c http.proxy=http://127.0.0.1:7890)
        CURL_PROXY_ARGS=(-x http://127.0.0.1:7890)
    else
        echo "github.com 不可达（直连与代理均失败）" >&2
        exit 1
    fi
fi

# 1. 构建并打包
echo "==> 构建 release"
swift build -c release

echo "==> 组装 .app ($TAG)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$project_dir/.build/release/QuotaBar" "$APP_DIR/Contents/MacOS/QuotaBar"
cp "$project_dir/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$project_dir/Support/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
touch "$APP_DIR"

SIGN_IDENTITY="QuotaBar Development"
echo "==> 签名 ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign -v "$APP_DIR"

echo "==> 压缩 $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

# 2. git tag 并推送
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> tag $TAG 已存在，跳过创建"
else
    echo "==> 创建并推送 tag $TAG"
    git tag -a "$TAG" -m "Quota Bar $TAG"
    git "${GIT_PROXY_ARGS[@]}" push origin "$TAG"
fi

# 3. GitHub Release（REST API，token 取自 git 凭据助手）
TOKEN=$(printf "protocol=https\nhost=github.com\n" | git credential fill 2>/dev/null | sed -n 's/^password=//p')
if [[ -z "$TOKEN" ]]; then
    echo "未找到 GitHub 凭据（git credential fill 为空）" >&2
    exit 1
fi

API="https://api.github.com/repos/$REPO/releases"
EXISTING=$(curl -sS --max-time 30 "${CURL_PROXY_ARGS[@]}" \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/tags/$TAG")
UPLOAD_URL=$(print -r -- "$EXISTING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('upload_url','').split('{')[0])" 2>/dev/null)

if [[ -z "$UPLOAD_URL" ]]; then
    echo "==> 创建 Release $TAG"
    RESP=$(curl -sS --max-time 30 "${CURL_PROXY_ARGS[@]}" -X POST \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
        "$API" \
        -d "{\"tag_name\":\"$TAG\",\"name\":\"Quota Bar $TAG\",\"body\":\"macOS 菜单栏额度面板 $TAG\n\n下载解压后将 QuotaBar.app 拖入「应用程序」即可。首次运行如被拦截，右键 → 打开。\",\"draft\":false,\"prerelease\":false}")
    UPLOAD_URL=$(print -r -- "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('upload_url','').split('{')[0])")
fi
[[ -n "$UPLOAD_URL" ]] || { echo "Release 创建失败" >&2; exit 1; }

echo "==> 上传产物 $(basename "$ZIP")"
curl -sS --max-time 300 "${CURL_PROXY_ARGS[@]}" -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/zip" \
    --data-binary @"$ZIP" \
    "$UPLOAD_URL?name=$(basename "$ZIP")" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('完成:', d.get('browser_download_url', d))"
