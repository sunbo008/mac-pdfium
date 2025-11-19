# 版本记录

记录 mac-pdfium 项目的重大功能实现与改进。

## 📋 版本列表

### [v1.0 - 图片替换](v1.0-image-replacement/) (2025-11-19) ⭐ 最新
**功能**: AP-Form 图片动态替换  
**状态**: ✅ 已发布 | **质量**: 93/100  
**亮点**: 
- 多种替换模式（全局/条件/映射）
- 独立开关控制
- PNG/JPEG 支持
- 完整的 OpenSpec 流程

**快速访问**:
- [功能概览](v1.0-image-replacement/README.md) ⭐ 先看这个
- [使用指南](v1.0-image-replacement/docs/usage-guide.md)
- [变更日志](v1.0-image-replacement/CHANGELOG.md)
- [代码审核](v1.0-image-replacement/reviews/code-review-2025-11-19.md)

---

## 📂 目录结构

每个版本包含：
```
v{版本号}-{功能简称}/
├── README.md           # 版本概览（入口）
├── CHANGELOG.md        # 详细变更记录
├── reviews/           # 代码审核报告
└── docs/              # 技术文档
```

## 📝 命名规范

- **版本号**: `v{major}.{minor}[-{patch}]` 如 `v1.0`, `v1.1`
- **目录名**: `v{版本号}-{功能简称}` 如 `v1.0-image-replacement`
- **关键文档**: 大写 `README.md`, `CHANGELOG.md`
- **普通文档**: 小写 `usage-guide.md`, `code-review-2025-11-19.md`

## ⭐ 质量标准

发布版本必须满足：
- ✅ 代码审核 ≥ 90 分
- ✅ 功能测试通过
- ✅ 文档完整（README + CHANGELOG + 使用指南）
- ✅ OpenSpec 合规

## 🔗 相关资源

- [OpenSpec 文档](../openspec/)
- [项目文档](../docs/)
- [贡献指南](../CONTRIBUTING.md)

