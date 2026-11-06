#!/usr/bin/env bash
# 打包函数部署 zip（WSL / Linux）
# 用法：cd serverless && bash build_function.sh
# 产物：function.zip（zip 根目录直接是 main.py，可直接上传 veFaaS）
set -e
cd "$(dirname "$0")"

echo "[1/3] pip install -t deps -r requirements.txt"
rm -rf deps stage function.zip
pip install -t ./deps -r requirements.txt

echo "[2/3] assembling stage folder"
mkdir -p stage
cp -r deps/. stage/
cp main.py requirements.txt stage/
cp -r fonts stage/fonts

echo "[3/3] zipping"
(cd stage && zip -rq ../function.zip .)

size=$(du -h function.zip | cut -f1)
echo "Done: function.zip ($size)"
