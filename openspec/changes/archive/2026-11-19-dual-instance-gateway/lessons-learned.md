# 归档经验记录：dual-instance-gateway

归档时间：2026-11-19。全流程：Phase 1 方案设计 → Phase 2 双评审（3 轮 + 用户裁决）→ Phase 3 四任务实现（T1 机制回退 / T2 双实例配置 / T3 脚本双实例化 / T4 文档）+ tester 验证 + reviewer 审查（评分 A）→ 建议项修复 + 终审复核（评分 A）。本变更是网关架构重构：单实例网关拆为「AI 出口实例（7890，MATCH→美国组）+ 通用出口实例（7891，CN 直连 + HK 兜底）」，同步撤销两个已归档机制（AI 域名同步、域名→国家分流）。

## 技术决策

- **多用户共享网关的用户隔离问题 → 域名判断下沉客户端 PAC**：网关侧域名规则全局生效，任何用户级 AI 域名列表必然对所有用户生效，用户隔离无法靠「域名同步」实现。最终方案：网关只提供两个端口（AI 出口 7890 / 通用出口 7891），插件 PAC 按用户自己的域名列表选择端口——网关完全不需要知道用户域名。这是撤销 plugin-domain-sync、country-routing-gateway 两个能力的根本原因。
- **AI 出口组 `AI-US-STICKY` 的 exclude-filter 刻意不含「中国」**：美国落地节点常带「中国优化/回国优化」字样，排除「中国」会误杀目标节点；组定义以 design 决策 3 为准，不照抄旧 `AI-STICKY`。
- **旧端口 10800 过渡用 mihomo `listeners` 入站段**（非正式入口），插件侧切换完成后即移除；过渡监听不得写 `proxy` 字段。
- **撤销的机制用 REMOVED spec 记录 Reason+Migration**：两个已归档 spec 各留一条「能力退役」存根 requirement（含回退原因与迁移路径），spec 非空以满足 openspec 验证，重新引入须以新变更显式提案。

## 踩坑记录

- **mihomo 语法陷阱**：顶层没有 `ports` 字段（Surge 语法），多端口监听用 `listeners` 段；mihomo 对未知字段静默忽略不报错，写错会「能启动但过渡监听失效」。
- **docker compose 陷阱**：服务改名后 `up -d` 不会删除旧容器（仅 orphan 警告），旧容器占用端口导致新实例绑定失败崩溃循环；升级必须显式 `down` + `up --remove-orphans`。compose env 强校验 `${VAR:?...}` 对 `down` 命令同样生效，补 `.env` 必须在 `down` 之前。
- **nginx envsubst 陷阱**：默认替换模板内所有 `${...}`，PAC JS 代码不得出现 `${}` 字面量（注入点除外）。
- **NO_PROXY 细节**：大小写双导出（Node/Python 只认小写 `no_proxy`，curl 系认大写）；CIDR 段仅 curl≥7.86/libcurl 系识别，Node/Python 系不识别，关键内网主机须同时列出主机名/IP 字面量。
- **回退与基线**：工作区从未 commit 导致多变更产物混流，审查只能靠 mtime 判定归属；多变更连续开发时每个变更完成即应固化基线。
- **openspec 1.5.0 归档三坑**（本次归档实测）：① 改名 requirement 须在 delta 中加 `## RENAMED Requirements`（FROM/TO），且 MODIFIED 必须引用新名，否则报 header not found；② 一个 spec 的 requirements 全部 REMOVED 后重建为空 spec，验证报「Spec must have at least one requirement」并整体中止——须为退役 spec 补一条 ADDED 存根 requirement（含 SHALL/MUST + 至少一个 scenario）；③ RENAMED 后的 requirement 会被 1.5.0 追加到 spec 末尾而非保持原位，归档后需手动恢复顺序并跑 `openspec validate --specs` 复核。

## 改进建议

- **涉及机制撤销的变更，delta 与存根一起写**：若预计清空某个 spec，proposal 阶段就应规划「REMOVED 全部 + ADDED 退役存根」的组合，避免归档时才撞上验证器。
- **docker compose 升级操作写入 DEPLOY.md 硬性步骤**：`down` → 补 `.env` → `up --remove-orphans` 的次序约束必须文档化，否则下一次服务改名/端口调整仍会踩旧容器占端口。
- **配置类变更建议以「最终文件断言」验收**：mihomo 静默忽略未知字段的特性意味着「能启动」≠「配置正确」，验证必须以 verify.sh 对两实例的组非空/出口连通性断言收口。
