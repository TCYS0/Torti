#!/bin/bash
# 生成一个用于试玩的 SVN 仓库：trunk / branches / tags + 本地改动
set -euo pipefail

ROOT="${1:-/tmp/svntest}"
REPO="$ROOT/repo"
WC="$ROOT/wc"

rm -rf "$ROOT"
mkdir -p "$ROOT/src/trunk/lib" "$ROOT/src/branches" "$ROOT/src/tags"

printf 'print("hello")\n' > "$ROOT/src/trunk/main.py"
printf '# readme\n' > "$ROOT/src/trunk/README.md"
printf 'def util():\n    pass\n' > "$ROOT/src/trunk/lib/util.py"

svnadmin create "$REPO"
svn import "$ROOT/src" "file://$REPO" -m "初始导入" >/dev/null
svn checkout "file://$REPO/trunk" "$WC" >/dev/null

cd "$WC"
printf 'print("hello v2")\n' > main.py
svn commit -m "初始化主干" >/dev/null

svn copy "file://$REPO/trunk" "file://$REPO/branches/feature-login" -m "创建登录分支" >/dev/null
printf 'login\n' > login.py
svn add login.py >/dev/null
svn commit -m "添加登录模块" >/dev/null

svn rm README.md >/dev/null
printf 'login v2\n' > login.py
svn commit -m "调整登录逻辑，移除 README" >/dev/null

svn copy "file://$REPO/trunk" "file://$REPO/tags/v1.0" -m "打标签 v1.0" >/dev/null

printf 'x\n' > extra.py
svn add extra.py >/dev/null
svn commit -m "新增 extra" >/dev/null
svn update >/dev/null

# 留一点本地改动，方便看状态徽章
printf 'unversioned\n' > NEW.txt
printf 'print("local edit")\n' > main.py

echo "✓ 演示仓库已生成"
echo "  仓库:   file://$REPO"
echo "  工作副本: $WC"
echo "  历史:"
svn log -q "file://$REPO" | sed 's/^/    /'
