#!/usr/bin/env python3
"""
批量为代码文件添加LGPL许可证头
"""

import os
import sys
from pathlib import Path

# LGPL许可证头模板
C_STYLE_HEADER = """
// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
"""

PY_STYLE_HEADER = """
# Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
#
# ZirconOS
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
"""

# 文件后缀对应的许可证头
HEADER_MAP = {
    ".zig": C_STYLE_HEADER,
    ".c": C_STYLE_HEADER,
    ".h": C_STYLE_HEADER,
    ".cpp": C_STYLE_HEADER,
    ".hpp": C_STYLE_HEADER,
    ".py": PY_STYLE_HEADER,
}

# 要处理的目录
PROCESS_DIRS = ["src", "boot", "sdk", "tests", "tools"]
# 排除目录
EXCLUDE_DIRS = [".zig-cache", "build", "out", "target", "__pycache__"]

def add_license_header(file_path: Path):
    """为单个文件添加许可证头"""
    suffix = file_path.suffix
    if suffix not in HEADER_MAP:
        return
    
    header = HEADER_MAP[suffix]
    
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        # 检查是否已有许可证
        if "GNU Lesser General Public License" in content or "Copyright (c)" in content:
            return
        
        # 跳过Shebang行
        if content.startswith("#!"):
            lines = content.splitlines(True)
            shebang = lines[0]
            rest = "".join(lines[1:])
            new_content = shebang + header.lstrip() + "\n" + rest
        else:
            new_content = header.lstrip() + "\n" + content
        
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        
        print(f"已添加LGPL许可证头: {file_path}")
    
    except Exception as e:
        print(f"处理文件失败 {file_path}: {str(e)}")

def main():
    print("批量添加LGPL许可证头工具")
    print("=" * 50)
    
    for dir_path in PROCESS_DIRS:
        dir_full = Path(dir_path)
        if not dir_full.exists():
            continue
        
        for root, _, files in os.walk(dir_full):
            # 跳过排除目录
            if any(exclude in root for exclude in EXCLUDE_DIRS):
                continue
            
            for file in files:
                file_path = Path(root) / file
                add_license_header(file_path)
    
    print("\n处理完成!")
    print("=" * 50)
    
    # 运行审计工具验证
    print("正在运行版权审计...")
    os.execvp(sys.executable, [sys.executable, "scripts/devtools/copyright_audit.py"])

if __name__ == "__main__":
    main()