# livemask-ci-cd 仓库结构文档

> 仓库路径: `/Users/sammytan/Developer/LiveMask/livemask-ci-cd`
>
> livemask-ci-cd 是 LiveMask 项目的 CI/CD 自动化仓库, 包含 GitHub Actions 工作流、部署自动化脚本、基础设施即代码、多仓库协调脚本以及完整的本地开发运行时环境。

---

## 目录

- [根目录文件](#根目录文件)
- [.github/ -- GitHub 工作流与配置](#github----github-工作流与配置)
- [scripts/ -- 自动化脚本](#scripts----自动化脚本)
- [infra/ -- 基础设施与 Docker](#infra----基础设施与-docker)
- [templates/ -- 安装脚本模板](#templates----安装脚本模板)
- [docs/ -- 文档](#docs----文档)
- [.claude/ -- Claude Code 技能](#claude----claude-code-技能)
- [.cursor-worker/ -- Cursor Worker 任务分配状态](#cursor-worker----cursor-worker-任务分配状态)

---

## 根目录文件

| 文件 | 说明 |
|------|------|
| `README.md` | 仓库总览, 本地开发运行时说明, 服务端口映射表 |
| `.cursorrules` | Cursor 编辑器规则/约束配置 |
| `.env.example` | 环境变量模板 |
| `.gitmodules` | Git 子模块配置, 管理外部依赖仓库引用 |
| `.gitignore` | Git 忽略规则 |
| `AI_EDITOR_RULES.md` | AI 编辑器行为规则与约束定义 |

---

## .github/ -- GitHub 工作流与配置

### 工作流文件 (17个 YAML)

所有工作流位于 `.github/workflows/` 下。

| 工作流文件 | 用途 |
|-----------|------|
| `app-hysteria2-aar-build.yml` | Hysteria2 Android AAR 构建流水线 |
| `auto-task-assignment.yml` | 自动任务分配工作流, 智能调度 CI 任务 |
| `ci-runner-diagnostics.yml` | CI Runner 健康诊断与日志采集 |
| `dev-runtime-deploy.yml` | 开发运行时环境部署 |
| `issue-close-guard.yml` | Issue 关闭前检查守卫, 防止未完成事项误关 |
| `issue-sync-strict.yml` | Issue 同步守卫, 确保 Issue 状态一致性 |
| `nodeagent-image-publish.yml` | NodeAgent Docker 镜像发布 |
| `production-release.yml` | 生产环境发布流水线 |
| `public-nginx-bootstrap.yml` | 公共 Nginx 初始引导配置 |
| `reusable-cursor-report-dispatch.yml` | 可复用工作流: Cursor 报告分发 |
| `reusable-cursor-worker-continuation.yml` | 可复用工作流: Cursor Worker 延续 |
| `reusable-docker-build.yml` | 可复用工作流: Docker 镜像构建 |
| `reusable-go-build.yml` | 可复用工作流: Go 项目编译 |
| `reusable-trigger-dev-runtime-deploy.yml` | 可复用工作流: 触发开发运行时部署 |
| `webhook-auto-deploy.yml` | Webhook 自动部署触发器 |
| `webhook-notify.yml` | Webhook 通知分发工作流 |
| `workflow-syntax-guard.yml` | 工作流语法校验守卫 |

### 其他 .github 配置

| 文件 | 说明 |
|------|------|
| `CODEOWNERS` | 代码审查所有者配置, 定义各目录/文件的责任人 |
| `copilot-instructions.md` | GitHub Copilot 行为指令配置 |
| `pull_request_template.md` | PR 模板, 规范 PR 提交流程 |

---

## scripts/ -- 自动化脚本

### 根目录脚本 (约 130+ 个 .sh/.py 文件)

脚本文件位于 `scripts/` 根目录下, 按功能分类如下:

#### 核心启动与循环 (7)

| 脚本 | 用途 |
|------|------|
| `claude-loop-startup.sh` | **主入口** -- Claude 自动循环启动, 启动协议核心 |
| `claude-loop-preflight.sh` | 启动前预检, 检查环境就绪状态 |
| `claude-loop-role-engine.sh` | 角色引擎循环, 管理 AI 角色分配 |
| `claude-loop-idle-monitor.sh` | 空闲监控, 检测循环空闲超时 |
| `claude-dev-loop.sh` | 开发模式循环, 用于本地开发迭代 |
| `local-dev.sh` | 本地开发环境启动/停止/状态查询 |
| `runtime.sh` | 完整运行时启动, 与 `local-dev.sh` 配合 |

#### 工作流编排与调度 (5)

| 脚本 | 用途 |
|------|------|
| `autonomous-loop.sh` | 自治闭环主循环, 端到端任务自动化 |
| `autonomy-closed-loop-audit.sh` | 自治闭环审计脚本 |
| `role-engine-flow.yml` | 角色引擎 YAML 流程定义 |
| `target-repo-task-bridge.sh` | 目标仓库任务桥接, 跨仓库任务同步 |
| `worker-harness-config.json` | Worker Harness 配置文件 (JSON) |

#### 本地验证 (4)

| 脚本 | 用途 |
|------|------|
| `local-validate-backend.sh` | 本地后端验证 |
| `local-validate-job-service.sh` | 本地 Job Service 验证 |
| `local-validate-nodeagent.sh` | 本地 NodeAgent 验证 |
| `local-full-smoke.sh` | 本地全量冒烟测试 |

#### 冒烟测试 (Smoke Tests, 约 80+)

| 脚本 | 用途 |
|------|------|
| `smoke.sh` | 冒烟测试主入口 |
| `api-smoke.sh` | API 通用冒烟测试 |
| `connect-smoke.sh` | 连接功能冒烟测试 |
| `node-smoke.sh` | 节点基础功能冒烟测试 |
| `accept-next-task.sh` | 接受下一任务 (工作流入口) |
| `admin-jobs-geoip-smoke.sh` | 管理后台 GeoIP 任务冒烟测试 |
| `admin-nav-ia-smoke.sh` | 管理后台导航 IA 冒烟测试 |
| `admin-nodes-ux-smoke.sh` | 管理后台节点 UX 冒烟测试 |
| `admin-user-detail-smoke.sh` | 管理后台用户详情冒烟测试 |
| `app-android-libbox-runtime-smoke.sh` | Android LibBox 运行时冒烟测试 |
| `app-desktop-vpn-runtime-smoke.sh` | 桌面 VPN 运行时冒烟测试 |
| `app-hysteria2-aar-build-smoke.sh` | Hysteria2 AAR 构建冒烟测试 |
| `app-libbox-config-smoke.sh` | LibBox 配置冒烟测试 |
| `app-libbox-tunnel-runtime-smoke.sh` | LibBox 隧道运行时冒烟测试 |
| `app-release-smoke.sh` | 应用发布冒烟测试 |
| `app-routing-strategy-smoke.sh` | 路由策略冒烟测试 |
| `app-runtime-engine-apply-smoke.sh` | 运行时引擎应用冒烟测试 |
| `app-runtime-governance-smoke.sh` | 运行时治理冒烟测试 |
| `artifact-oss-smoke.sh` | OSS 制品冒烟测试 |
| `auto-task-assignment-smoke.sh` | 自动任务分配冒烟测试 |
| `auto-task-assignment-workflow-smoke.sh` | 自动任务分配工作流冒烟测试 |
| `autonomy-closed-loop-audit-smoke.sh` | 自治闭环审计冒烟测试 |
| `bandwidth-auto-reconnect-smoke.sh` | 带宽自动重连冒烟测试 |
| `billing-smoke.sh` | 计费系统冒烟测试 |
| `c2c-points-market-smoke.sh` | C2C 积分市场冒烟测试 |
| `claude-loop-idle-smoke.sh` | Claude 循环空闲冒烟测试 |
| `claude-loop-resume-smoke.sh` | Claude 循环恢复冒烟测试 |
| `commerce-marketplace-bridge-smoke.sh` | 商城市场桥接冒烟测试 |
| `connection-quality-smoke.sh` | 连接质量冒烟测试 |
| `content-smoke.sh` | 内容系统冒烟测试 |
| `dashboard-smoke.sh` | 仪表盘冒烟测试 |
| `dev-runtime-deploy-scope-smoke.sh` | 开发运行时部署范围冒烟测试 |
| `fleet-load-smoke.sh` | 集群负载冒烟测试 |
| `fleet-scale-dry-run-smoke.sh` | 集群扩容 Dry-Run 冒烟测试 |
| `fleet-scale-postgres-smoke.sh` | 集群扩容 Postgres 冒烟测试 |
| `geoip-credentials-smoke.sh` | GeoIP 凭证冒烟测试 |
| `geoip-smoke.sh` | GeoIP 功能冒烟测试 |
| `growth-revenue-smoke.sh` | 增长营收冒烟测试 |
| `i18n-smoke.sh` | 国际化冒烟测试 |
| `jobs-hardening-smoke.sh` | Job 加固冒烟测试 |
| `jobs-real-data-smoke.sh` | Job 真实数据冒烟测试 |
| `jobs-smoke.sh` | Job 通用冒烟测试 |
| `large-fleet-dry-run-smoke.sh` | 大型集群 Dry-Run 冒烟测试 |
| `log-retention-smoke.sh` | 日志留存冒烟测试 |
| `mailu-smoke.sh` | Mailu 邮件服务冒烟测试 |
| `nat-sharing-smoke.sh` | NAT 共享冒烟测试 |
| `node-status-freshness-smoke.sh` | 节点状态时效性冒烟测试 |
| `nodeagent-config-smoke.sh` | NodeAgent 配置冒烟测试 |
| `nodeagent-control-acl-ip-pool-smoke.sh` | NodeAgent 控制面 ACL IP 池冒烟测试 |
| `nodeagent-control-channel-smoke.sh` | NodeAgent 控制信道冒烟测试 |
| `nodeagent-credential-rotation-smoke.sh` | NodeAgent 凭证轮换冒烟测试 |
| `nodeagent-release-smoke.sh` | NodeAgent 发布冒烟测试 |
| `nodeagent-speedtest-smoke.sh` | NodeAgent 测速冒烟测试 |
| `notification-settings-smoke.sh` | 通知设置冒烟测试 |
| `observability-smoke.sh` | 可观测性冒烟测试 |
| `openapi-drift-smoke.sh` | OpenAPI 漂移冒烟测试 |
| `payment-settings-smoke.sh` | 支付设置冒烟测试 |
| `product-config-smoke.sh` | 产品配置冒烟测试 |
| `protocol-capability-smoke.sh` | 协议能力冒烟测试 |
| `protocol-control-plane-closure-smoke.sh` | 协议控制面关闭冒烟测试 |
| `protocol-endpoint-smoke.sh` | 协议端点冒烟测试 |
| `protocol-parity-smoke.sh` | 协议对等性冒烟测试 |
| `protocol-secret-rotation-ha-smoke.sh` | 协议密钥轮换高可用冒烟测试 |
| `real-data-closed-loop-smoke.sh` | 真实数据闭环冒烟测试 |
| `release-control-smoke.sh` | 发布控制冒烟测试 |
| `role-engine-self-create-smoke.sh` | 角色引擎自创建冒烟测试 |
| `secret-leak-standard-smoke.sh` | 密钥泄露标准冒烟测试 |
| `sentry-config-smoke.sh` | Sentry 配置冒烟测试 |
| `singbox-update-smoke.sh` | Sing-Box 更新冒烟测试 |
| `sponsor-node-kpi-reward-smoke.sh` | 赞助节点 KPI 奖励冒烟测试 |
| `system-settings-smoke.sh` | 系统设置冒烟测试 |
| `target-repo-task-bridge-smoke.sh` | 目标仓库任务桥接冒烟测试 |
| `three-level-reward-smoke.sh` | 三级奖励冒烟测试 |
| `traffic-analytics-v2-smoke.sh` | 流量分析 V2 冒烟测试 |
| `traffic-package-plan-smoke.sh` | 流量套餐计划冒烟测试 |
| `vpn-c2c-closed-loop-smoke.sh` | VPN C2C 闭环冒烟测试 |
| `vpn-device-e2e-preflight-smoke.sh` | VPN 设备端到端预检冒烟测试 |
| `vpn-inbound-ops-smoke.sh` | VPN 入站运维冒烟测试 |
| `vpn-protocol-e2e-acceptance-smoke.sh` | VPN 协议端到端验收冒烟测试 |
| `vpn-protocol-matrix-smoke.sh` | VPN 协议矩阵冒烟测试 |
| `website-i18n-announcement-smoke.sh` | 网站国际化公告冒烟测试 |
| `website-smoke.sh` | 网站通用冒烟测试 |
| `worker-e2e-smoke.sh` | Worker 端到端冒烟测试 |
| `worker-harness-smoke.sh` | Worker Harness 冒烟测试 |

#### 部署与运维 (9)

| 脚本 | 用途 |
|------|------|
| `deploy-service.sh` | 通用服务部署 |
| `deploy-webhook.sh` | Webhook 服务部署 |
| `deploy-mailu.sh` | Mailu 邮件服务部署 |
| `deploy-external-nodeagents.sh` | 外部 NodeAgent 部署 |
| `setup-public-nginx.sh` | 公共 Nginx 配置部署 |
| `forward-hy2-udp-docker.sh` | Hysteria2 UDP Docker 转发 |
| `dev-runtime-status.sh` | 开发运行时状态查询 |
| `local-dev-status.sh` | 本地开发状态查询 |
| `create-staging-smoke-failure-issue.sh` | 创建 Staging 冒烟失败 Issue |

#### CI 运维 (4)

| 脚本 | 用途 |
|------|------|
| `diagnose-ci-runner.sh` | CI Runner 诊断 |
| `restart-ci-runner.sh` | CI Runner 重启 |
| `runner-recovery.sh` | Runner 故障恢复 |
| `register-gh-webhooks.sh` | GitHub Webhook 注册 |

#### 种子数据 (5)

| 脚本 | 用途 |
|------|------|
| `seed-dev-test-data.sh` | 开发测试数据填充 |
| `seed-blog-zh-content.sh` | 博客中文内容填充 |
| `seed-site-config.sh` | 站点配置填充 |
| `seed-site-config.py` | 站点配置填充 (Python 版本) |
| `seed-job-cron-schedules.sh` | Job Cron 调度配置填充 |
| `seed-app-announcements.sh` | 应用公告填充 |

#### 验证与检查 (8)

| 脚本 | 用途 |
|------|------|
| `validate-contract-ownership.sh` | 合约所有权校验 |
| `validate-review-packet.sh` | 审查包校验 |
| `validate-workflow-syntax.sh` | 工作流语法校验 |
| `validate-role-engine-flow.sh` | 角色引擎流程校验 |
| `validate-dev-ref.sh` | 开发引用校验 |
| `flutter-analyze-guard.sh` | Flutter 静态分析守卫 |
| `dev-merge-guard.sh` | 开发分支合并守卫 |
| `issue-close-guard.sh` | Issue 关闭守卫 |
| `issue-sync-strict.sh` | Issue 严格同步守卫 |
| `task-environment-freshness.sh` | 任务环境新鲜度检查 |

#### 工具与辅助 (12)

| 脚本 | 用途 |
|------|------|
| `cleanup-branches.sh` | 清理过期分支 |
| `claude-startup.sh` | Claude 启动辅助 |
| `sync-ai-rules.sh` | 同步 AI 规则文件 |
| `cursor-report-dispatch.sh` | Cursor 报告分发 |
| `protocol-secret-rotation-staging-seed.sh` | 协议密钥轮换 Staging 种子 |
| `runtime-log-audit.sh` | 运行时日志审计 |
| `mvp.sh` | MVP 构建辅助 |
| `align-android-hysteria2-local.sh` | Android Hysteria2 本地对齐 |
| `gh-issue-watch.sh` | GitHub Issue 监控 |
| `prepare-staging-build-context.sh` | 准备 Staging 构建上下文 |
| `apply-branch-protection.sh` | 应用分支保护规则 |
| `target-repo-task-bridge.sh` | 目标仓库任务桥接 |

#### Python 独立脚本 (4)

| 脚本 | 用途 |
|------|------|
| `_lark_send.py` | Lark 飞书消息发送 |
| `auto-task-assignment.py` | 自动任务分配引擎 |
| `engine-dashboard.py` | 引擎仪表盘 |
| `webhook-server.py` | Webhook 服务器 |
| `seed-site-config.py` | 站点配置填充 |

#### 数据文件 (1)

| 文件 | 说明 |
|------|------|
| `api-smoke-cases.tsv` | API 冒烟测试用例表格数据 |
| `role-engine-flow.yml` | 角色引擎流程 YAML 定义 |
| `worker-harness-config.json` | Worker Harness JSON 配置 |

---

### scripts/lib/ -- Shell 库文件 (35个)

| 库文件 | 用途 |
|-------|------|
| `base_service.sh` | 基础服务抽象, 服务启停与生命周期管理 |
| `helpers.sh` | 通用辅助函数集合 |
| `logging.sh` | 日志输出框架, 支持分级日志 |
| `github-ops.sh` | GitHub API 操作封装 (PR、Issue、Check Run) |
| `health-check.sh` | 健康检查工具, 服务可用性探测 |
| `event-bus.sh` | 事件总线, 组件间事件发布/订阅 |
| `claude-brain.sh` | Claude 大脑模块, 决策与推理 |
| `claude-implement.sh` | Claude 实现模块, 代码生成与修改 |
| `claude-memory.sh` | Claude 记忆模块, 短期/长期记忆管理 |
| `claude-qa.sh` | Claude 质量保证模块 |
| `claude-repair.sh` | Claude 修复模块, 错误自动修复 |
| `claude-webhook.sh` | Claude Webhook 处理模块 |
| `deepseek-engine.sh` | DeepSeek 推理引擎集成 |
| `reasoning-engine.sh` | 通用推理引擎 |
| `executor-guard.sh` | 执行器守卫, 并发控制与执行安全 |
| `impl-assist.sh` | 实现辅助, 任务实现引导 |
| `lark-card.sh` | Lark 飞书卡片消息构建 |
| `lark-notify.sh` | Lark 飞书通知发送 |
| `ledger-intelligence.sh` | 账本智能, 成本与资源追踪 |
| `local-compose.sh` | Docker Compose 本地管理 |
| `local-verify.sh` | 本地验证工具 |
| `log-watch.sh` | 日志监控与告警 |
| `memory-fast.sh` | 快速内存存储与检索 |
| `monitor-learn.sh` | 监控学习, 从运行数据中学习 |
| `review-gate.sh` | 审查关卡, 代码审查质量控制 |
| `server-skill.sh` | 服务器技能, 服务端操作封装 |
| `skill-bridge.sh` | 技能桥接, 不同 AI 技能间通信 |
| `sync.sh` | 同步工具, 多仓库同步 |
| `venv.sh` | Python 虚拟环境管理 |
| `verify-completion-gate.sh` | 完成验证关卡, 任务完成度检查 |
| `verify-diff-scope.sh` | DIFF 范围验证, 代码变更范围检查 |
| `worker-harness.sh` | Worker Harness 主模块 |
| `worker-harness-helper.py` | Worker Harness Python 辅助 |
| `qa-verdict.py` | QA 裁决 Python 脚本 |
| `_lark_send.py` | Lark 发送 Python 脚本 |

---

### scripts/lib/py/ -- Python 库文件 (32个)

| 模块 | 用途 |
|------|------|
| `auto_evidence.py` | 自动证据收集, 任务完成证据自动采集 |
| `auto_implement.py` | 自动实现引擎 |
| `cache.py` | 缓存管理, 多级缓存支持 |
| `complete_task.py` | 任务完成处理, 完成报告生成 |
| `context.py` | 上下文管理, AI 会话上下文维护 |
| `context_graph.py` | 上下文关系图, 上下文依赖关系建模 |
| `debug_utils.py` | 调试工具集 |
| `dev_intel.py` | 开发者情报, 开发行为分析 |
| `dispatch.py` | 任务分发引擎, 智能调度 |
| `doc_parser.py` | 文档解析器, 结构化文档提取 |
| `experience.py` | 经验管理, 从历史中学习 |
| `gaps.py` | 差距分析, 识别覆盖缺失 |
| `gates.py` | 质量关卡引擎, 多阶段审核 |
| `gh_cache.py` | GitHub API 缓存层 |
| `knowledge_base.py` | 知识库管理, 持久化知识存储 |
| `lark_send.py` | Lark 飞书消息发送 |
| `ledger.py` | 账本管理, 操作记录追踪 |
| `lock.py` | 分布式锁实现 |
| `log_watch_daemon.py` | 日志监控守护进程 |
| `mvp_submit.py` | MVP 提交辅助 |
| `planner.py` | 任务规划引擎, 步骤分解 |
| `repair.py` | 自动修复引擎, 问题自动修复 |
| `self_heal.py` | 自愈引擎, 系统自动恢复 |
| `self_review.py` | 自审查引擎, AI 自动 Code Review |
| `session.py` | 会话管理 |
| `shared_knowledge.py` | 共享知识库, 团队级知识管理 |
| `tags.py` | 标签管理, 分类与索引 |
| `task.py` | 任务模型与 CRUD |
| `task_intake.py` | 任务接收与解析入口 |
| `task_predictor.py` | 任务预测, 工作量预估 |
| `watchdog.py` | 看门狗, 进程守护与异常恢复 |
| `webhook_consumer.py` | Webhook 消费引擎 |

### scripts/lib/py/supplement/ -- 补充知识文档 (7个)

| 文档 | 说明 |
|------|------|
| `docker-dev-stack.md` | Docker 开发栈参考 |
| `flutter-vpn-integration.md` | Flutter VPN 集成模式 |
| `go-concurrency-patterns.md` | Go 并发编程模式 |
| `hysteria2-deployment.md` | Hysteria2 部署指南 |
| `nextjs-admin-patterns.md` | Next.js 管理后台模式 |
| `postgresql-performance.md` | PostgreSQL 性能优化 |
| `sing-box-config-patterns.md` | Sing-Box 配置模式 |

---

### scripts/event-adapters/ -- 事件适配器 (3个)

| 文件 | 用途 |
|------|------|
| `lib/adapter-lib.sh` | 适配器 Shell 库, 通用事件适配函数 |
| `poll-ci-runs.py` | CI 运行轮询器, 监控 CI 执行状态 |
| `poll-fixed-control-issues.py` | 控制 Issue 轮询器, 监控控制面 Issue 变更 |

---

### scripts/schemas/ -- JSON 模式定义 (21个文件)

| 文件 | 用途 |
|------|------|
| `event-schema-v1.json` | 事件模式 V1 定义, 事件数据结构规范 |
| `adapter-cursors-schema-v1.json` | 适配器游标模式 V1 |
| `completion-evidence-schema-v1.json` | 完成证据模式 V1 |
| `review-packet-schema-v1.json` | 审查包模式 V1, Code Review 数据结构规范 |

#### 测试夹具 (fixtures/)

| 夹具组 | 文件 | 场景 |
|--------|------|------|
| 根目录 | `positive-valid-minimal.json` | 最小有效负载 |
| 根目录 | `negative-extra-field.json` | 多余字段负例 |
| 根目录 | `negative-missing-task-id.json` | 缺少任务 ID 负例 |
| 根目录 | `negative-missing-validation.json` | 缺少验证负例 |
| 根目录 | `negative-wrong-branch.json` | 错误分支负例 |
| 根目录 | `negative-committed-true.json` | 已提交标记负例 |
| 根目录 | `validation-wrong-type-string.json` | 验证字段类型错误 |
| 根目录 | `branch-match-false.json` | 分支不匹配 |
| `contract-ownership/` - 正向 | `positive-ownership-valid.json` | 合法所有权 |
| `contract-ownership/` - 负向 | `negative-early-codex-fields.json` | 过早的 Codex 字段 |
| `contract-ownership/` - 负向 | `negative-orphaned-findings-response.json` | 孤立 Findings 响应 |
| `contract-ownership/` - 负向 | `negative-timestamp-reversal.json` | 时间戳反转 |
| `event-schema/` - 正向 | `positive-ci-completed.json` | CI 完成事件 |
| `event-schema/` - 正向 | `positive-comment-created.json` | 评论创建事件 |
| `event-schema/` - 正向 | `positive-state-snapshot.json` | 状态快照事件 |
| `event-schema/` - 负向 | `negative-bad-cursor-key.json` | 错误的游标键 |
| `event-schema/` - 负向 | `negative-extra-field.json` | 多余字段 |
| `event-schema/` - 负向 | `negative-missing-event-type.json` | 缺少事件类型 |

---

### scripts/data/ -- 数据脚本 (1个)

| 文件 | 用途 |
|------|------|
| `seed_blog_zh_payloads.py` | 博客中文内容种子数据, 生成中文博文负载 |

---

## infra/ -- 基础设施与 Docker

### Dockerfile 文件 (5个)

| 文件 | 用途 |
|------|------|
| `Dockerfile.backend` | 后端 Go 服务编译与运行容器 |
| `Dockerfile.admin` | 管理后台 Next.js 应用容器 |
| `Dockerfile.website` | 前端网站应用容器 |
| `Dockerfile.jobservice` | Job Service Go 服务编译与运行容器 |
| `Dockerfile.nodeagent` | NodeAgent Go 代理服务编译与运行容器 |

### Docker Compose 文件 (4个)

| 文件 | 用途 |
|------|------|
| `docker-compose.local.yml` | 本地开发运行时, 挂载源码目录, 固定端口映射 |
| `docker-compose.staging.yml` | Staging 测试环境编排 |
| `docker-compose.hot.yml` | 热重载扩展配置, 在本地模式中自动合并 |
| `docker-compose.runtime.yml` | 运行时环境编排 |

### 环境变量模板

| 文件 | 说明 |
|------|------|
| `env/local.env.example` | 本地环境变量模板 |
| `env/staging.env.example` | Staging 环境变量模板 |
| `env/production.env.example` | 生产环境变量模板 |

### infra/mailu/ -- 邮件基础设施 (3个)

| 文件 | 用途 |
|------|------|
| `docker-compose.mailu.yml` | Mailu 邮件服务 Docker Compose 编排 |
| `Dockerfile.mailu-admin` | Mailu 管理后台自定义 Dockerfile |
| `mailu.env.example` | Mailu 环境变量模板 |

### infra/_build_deps/ -- 构建上下文目录

五个子目录, 对应各服务的 Docker 构建上下文, 包含:

| 子目录 | 来源仓库 | 典型文件 |
|--------|----------|----------|
| `backend/` | Go 后端服务 | `main.go`, `go.mod`, `go.sum`, 任务完成报告 |
| `admin/` | Next.js 管理后台 | `next.config.ts`, `package.json`, `tailwind.config.ts`, 任务就绪状态 |
| `website/` | Vite/React 前端网站 | `vite.config.ts`, `package.json`, `index.html`, 证据报告 |
| `job-service/` | Go Job 服务 | `go.mod`, `go.sum`, 编译产物, 完成报告 |
| `nodeagent/` | Go NodeAgent 代理 | `go.mod`, 编译产物 |

每个子目录包含 `.gitmodules`, `.gitignore`, `README.md`, `.exists` 等基础设施文件。

---

## templates/ -- 安装脚本模板 (1个)

| 文件 | 用途 |
|------|------|
| `sponsor/nodeagent-install.sh.tpl` | 赞助节点 NodeAgent 一键安装脚本模板 |

---

## docs/ -- 文档 (1个)

| 文件 | 用途 |
|------|------|
| `LARK_SETUP.md` | 飞书 (Lark) 机器人配置与集成指南 |

---

## .claude/ -- Claude Code 技能

| 文件 | 用途 |
|------|------|
| `skills/run-livemask-ci-cd/SKILL.md` | `run-livemask-ci-cd` 技能定义, 包含 CI/CD 运行与验证指令 |
| `skills/run-livemask-ci-cd/driver.sh` | 技能驱动脚本, 执行技能定义中的操作 |

---

## .cursor-worker/ -- Cursor Worker 任务分配状态

目录: `.cursor-worker/auto-task-assignment/`

| 文件 | 说明 |
|------|------|
| `dispatch-log.jsonl` | 任务分发日志 (JSONL 格式) |
| `TASK-ADMIN-CONFIG-MOCK-REFERENCE-CLEANUP-001.json` | 管理后台配置 Mock 引用清理任务 |
| `TASK-ADMIN-NODE-METRICS-SUMMARY-ROUTE-FIX-001.json` | 管理后台节点指标汇总路由修复任务 |
| `TASK-ADMIN-NODEAGENT-CREDENTIAL-ROTATION-001.json` | Admin NodeAgent 凭据轮换任务 |
| `TASK-BACKEND-GROWTH-SETTLEMENT-JOB-EXECUTOR-API-001.json` | 后端增长结算 Job 执行器 API 任务 |
| `TASK-BACKEND-NODE-SPEEDTEST-ADMIN-API-REGRESSION-001.json` | 后端节点测速管理 API 回归任务 |
| `TASK-BACKEND-NODE-THROUGHPUT-ENDPOINT-001.json` | 后端节点吞吐量端点任务 |
| `TASK-BACKEND-NODEAGENT-LOG-UPLOAD-SETTINGS-001.json` | 后端 NodeAgent 日志上传设置任务 |
| `TASK-BACKEND-USER-PROFILE-GROWTH-FIELDS-001.json` | 后端用户画像增长字段任务 |
| `TASK-CICD-APP-HYSTERIA2-AAR-BUILD-001.json` | CI/CD Hysteria2 AAR 构建任务 |
| `TASK-CICD-HYSTERIA2-CLIENT-CONFIG-SMOKE-001.json` | CI/CD Hysteria2 客户端配置冒烟任务 |
| `TASK-CICD-NODEAGENT-CREDENTIAL-ROTATION-SMOKE-001.json` | CI/CD NodeAgent 凭据轮换冒烟任务 |
| `TASK-CICD-VLESS-PLAIN-PROTOCOL-SMOKE-001.json` | CI/CD VLESS 明文协议冒烟任务 |

---

## 总结

livemask-ci-cd 仓库总计包含 **约 280+ 个源文件** (不计 `_build_deps` 和 `.cursor-worker` 内的数据文件), 核心架构可概括为:

- **工作流层** (`.github/workflows/`): 17 个 GitHub Actions 工作流, 覆盖构建、测试、部署、通知、分析审查等 CI/CD 全流程
- **脚本层** (`scripts/`): 约 130+ 自动化脚本, 80+ 冒烟测试覆盖全部微服务; 35 个 Shell 库文件提供复用组件; 32 个 Python 库文件提供 AI 自动化引擎 (任务调度、知识管理、质量关卡、自愈等)
- **基础设施层** (`infra/`): 5 个 Dockerfile + 4 个 Compose 文件, 支持本地开发、Staging、生产环境; Mailu 邮件栈独立编排
- **技能与辅助** (`.claude/`, `.cursor-worker/`, `templates/`): Claude Code 技能定义、Cursor Worker 任务状态跟踪、安装模板

