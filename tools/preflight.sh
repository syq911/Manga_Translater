#!/usr/bin/env bash
# 推送前预检：把「编译器/校验器才能发现的问题」尽量在本地挡掉，省一轮 CI。
#
# 用法：bash tools/preflight.sh
#
# 每一项都对应一类**真实踩过**的问题，修完就把规则固化进来（见各脚本头部注释）。
set -euo pipefail

cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  PY=python
fi

echo "=== 1/14 工程文件完整性 ==="
"$PY" tools/check_project.py

echo
echo "=== 2/14 导入完整性与跨模块访问权限 ==="
"$PY" tools/check_imports.py

echo
echo "=== 3/14 Swift 结构体检 ==="
"$PY" tools/check_swift_syntax.py

echo
echo "=== 4/14 文档与测试夹具同步 ==="
"$PY" tools/check_docs_sync.py

echo
echo "=== 5/14 构造调用与 init 签名一致性 ==="
"$PY" tools/check_api_usage.py

echo
echo "=== 6/14 Python 脚本语法 ==="
"$PY" -m py_compile \
  .github/scripts/build_altstore_source.py \
  tools/check_project.py \
  tools/check_imports.py \
  tools/check_swift_syntax.py \
  tools/check_docs_sync.py \
  tools/check_api_usage.py \
  tools/check_localization.py \
  tools/check_demo_repo.py \
  tools/check_member_receiver.py \
  tools/check_redlines.py \
  tools/check_hardcoded_copy.py \
  tools/check_legal_sync.py \
  tools/check_altstore_source.py \
  tools/make_ocr_fixture.py \
  tools/make_demo_repo.py \
  tools/make_screenshots.py \
  tools/build_website.py
echo "OK"

echo
echo "=== 7/14 本地化一致性（App 表 + 包层表）==="
"$PY" tools/check_localization.py

echo
echo "=== 8/14 用户可见文案扫描（不得硬编码中文）==="
"$PY" tools/check_hardcoded_copy.py

echo
echo "=== 9/14 法务文案与 App 内置副本同步 ==="
"$PY" tools/check_legal_sync.py

echo
echo "=== 10/14 自测仓库语料与夹具一致性 ==="
"$PY" tools/check_demo_repo.py

echo
echo "=== 11/14 官网生成与校验 ==="
"$PY" tools/build_website.py

echo
echo "=== 12/14 AltStore 源清单（用合成发布数据离线跑一遍）==="
"$PY" tools/check_altstore_source.py

echo
echo "=== 13/14 成员接收者（成员名对、接收者错）==="
"$PY" tools/check_member_receiver.py

echo
echo "=== 14/14 敏感信息与红线扫描 ==="
"$PY" tools/check_redlines.py

echo
echo "✅ 预检全部通过"
