#!/usr/bin/env python3
"""
ZirconOS Aero 版权合规审计工具
扫描所有代码文件，检查是否存在版权风险内容
"""

import os
import re
import sys
from pathlib import Path

# 禁止出现的风险关键词
RISK_KEYWORDS = [
    "Microsoft Windows source code",
    "Windows leak",
    "WRK confidential",
    "反编译", "逆向工程", "decompile", "reverse engineer",
    "微软专有代码", "Microsoft proprietary"
]

# 允许的许可证列表
ALLOWED_LICENSES = [
    "GNU LESSER GENERAL PUBLIC LICENSE", "LGPL",
    "MIT", "BSD", "Apache", "GPL",
    "Microsoft Limited Public License",  # WRK允许的许可证
    "ZirconOS Aero License"
]

# 要扫描的目录
SCAN_DIRS = ["src", "boot", "sdk", "tests", "tools"]
# 要排除的目录（缓存、构建输出等）
EXCLUDE_DIRS = [".zig-cache", "build", "out", "target", "__pycache__"]
# 要扫描的文件后缀
SCAN_EXTENSIONS = [".c", ".h", ".zig", ".cpp", ".hpp", ".py", ".rs", ".go"]

def scan_file(file_path: Path) -> list:
    """扫描单个文件，返回风险列表"""
    risks = []
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        # 检查风险关键词
        for keyword in RISK_KEYWORDS:
            if re.search(keyword, content, re.IGNORECASE):
                risks.append(f"风险关键词: {keyword}")
        
        # 检查是否有许可证声明（如果是代码文件）
        if file_path.suffix in SCAN_EXTENSIONS and len(content) > 100:
            content_lower = content.lower()
            has_license = False
            # 检查LGPL许可证（处理跨换行的情况）
            if re.search(r"gnu.*lesser.*general.*public.*license", content_lower, re.DOTALL) or "lgpl" in content_lower:
                has_license = True
            else:
                # 检查其他许可证
                has_license = any(license.lower() in content_lower for license in ALLOWED_LICENSES if license != "GNU LESSER GENERAL PUBLIC LICENSE" and license != "LGPL")
            
            if not has_license:
                risks.append("缺少许可证声明")
    
    except Exception as e:
        risks.append(f"读取文件失败: {str(e)}")
    
    return risks

def main():
    print("ZirconOS Aero 版权合规审计工具")
    print("=" * 50)
    
    all_risks = []
    total_files = 0
    
    for dir_path in SCAN_DIRS:
        dir_full = Path(dir_path)
        if not dir_full.exists():
            continue
        
        for root, _, files in os.walk(dir_full):
            # 跳过排除目录
            if any(exclude in root for exclude in EXCLUDE_DIRS):
                continue
            
            for file in files:
                file_path = Path(root) / file
                if file_path.suffix not in SCAN_EXTENSIONS:
                    continue
                
                # 跳过不存在的文件（可能是软链接失效或已删除）
                if not file_path.exists():
                    continue
                
                total_files += 1
                risks = scan_file(file_path)
                if risks:
                    all_risks.append((file_path, risks))
    
    # 输出结果
    print(f"扫描完成，共扫描 {total_files} 个文件")
    print(f"发现 {len(all_risks)} 个存在风险的文件")
    print("=" * 50)
    
    for file_path, risks in all_risks:
        print(f"\n文件: {file_path}")
        for risk in risks:
            print(f"  - {risk}")
    
    if all_risks:
        print("\n审计未通过，请修复以上风险后再提交代码")
        sys.exit(1)
    else:
        print("\n审计通过，无版权风险")
        sys.exit(0)

if __name__ == "__main__":
    main()