#!/bin/bash
# Copyright 2024 The PDFium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# 独立编译和测试日志模块的脚本

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR="${SCRIPT_DIR}/build_logger_test"

echo "=========================================="
echo "Logger Module Standalone Build Script"
echo "=========================================="

# 清理旧的构建
if [ -d "${BUILD_DIR}" ]; then
  echo "Cleaning old build directory..."
  rm -rf "${BUILD_DIR}"
fi

# 创建构建目录
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

echo "Compiling logger module..."

# 编译日志模块和测试程序
c++ -std=c++17 \
  -I"${SCRIPT_DIR}/../.." \
  -o logger_test \
  "${SCRIPT_DIR}/logger.cpp" \
  "${SCRIPT_DIR}/logger_test.cpp" \
  -Wall -Wextra

if [ $? -eq 0 ]; then
  echo "✓ Compilation successful!"
  echo ""
  echo "Running test..."
  echo "=========================================="
  ./logger_test
  echo "=========================================="
  echo ""
  echo "Test completed!"
  echo "Log file created at: /tmp/debug.log"
  echo ""
  echo "To view the log:"
  echo "  cat /tmp/debug.log"
  echo ""
  echo "To clean up:"
  echo "  rm -rf ${BUILD_DIR}"
  echo "  rm /tmp/debug.log*"
else
  echo "✗ Compilation failed!"
  exit 1
fi

