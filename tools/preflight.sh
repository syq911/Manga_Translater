#!/usr/bin/env bash
# 推送前预检：把「编译器/校验器才能发现的问题」尽量在本地挡掉，省一轮 CI。
#
# 用法：bash tools/preflight.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  PY=python
fi

echo "=== 1/6 工程文件完整性 ==="
"$PY" tools/check_project.py

echo
echo "=== 2/6 导入完整性与跨模块访问权限 ==="
"$PY" tools/check_imports.py

echo
echo "=== 3/6 Swift 结构体检 ==="
"$PY" tools/check_swift_syntax.py

echo
echo "=== 4/6 文档与测试夹具同步 ==="
"$PY" tools/check_docs_sync.py

echo
echo "=== 5/6 Python 脚本语法 ==="
"$PY" -m py_compile \
  .github/scripts/build_altstore_source.py \
  tools/check_project.py \
  tools/check_imports.py \
  tools/check_swift_syntax.py \
  tools/check_docs_sync.py \
  tools/check_redlines.py
echo "OK"

echo
echo "=== 6/6 敏感信息与红线扫描 ==="
"$PY" tools/check_redlines.py

echo
echo "✅ 预检全部通过"
