#!/usr/bin/env python3
"""Emit one JSON object per line for seed-blog-zh-content.sh (keep in sync with seed_zh.go)."""
import json
import sys

ARTICLES = [
    {
        "slug": "vpn-privacy-guide-zh",
        "title": "VPN 隐私保护完全指南：如何安全匿名上网",
        "excerpt": "了解 VPN 如何加密流量、隐藏 IP，以及选择服务商时应关注的零日志、Kill Switch 等关键能力。",
        "category": "隐私安全",
        "tags": ["隐私", "VPN入门", "安全"],
        "markdown": "## 为什么需要 VPN\n\n在公共网络、跨境办公或日常浏览中，你的 IP、访问记录可能被运营商或第三方追踪。VPN 通过加密隧道把流量转发到远端节点，降低被窃听和定位的风险。\n\n## 选择 VPN 的五个要点\n\n1. **加密强度**：优先 AES-256 等现代算法\n2. **零日志政策**：确认服务商不长期保存可识别日志\n3. **Kill Switch**：断线时自动阻断外泄流量\n4. **DNS 防泄露**：避免 DNS 请求绕过隧道\n5. **节点覆盖**：覆盖你常用的国家与地区\n\n## LiveMask 建议\n\n结合强密码、系统更新与谨慎授权，VPN 是隐私防护的重要一层，而不是唯一手段。",
    },
    {
        "slug": "choose-fast-vpn-node-zh",
        "title": "如何挑选最快的 VPN 节点：流媒体与游戏实战",
        "excerpt": "从延迟、负载、地理距离与协议选择四个维度，教你为看视频、打游戏选出更稳定的节点。",
        "category": "性能优化",
        "tags": ["节点", "加速", "游戏", "流媒体"],
        "markdown": "## 影响速度的核心因素\n\n- **地理距离**：越近通常延迟越低\n- **节点负载**：同时在线用户越少越稳定\n- **本地运营商路由**：同一节点不同 ISP 体验可能差异很大\n- **协议选择**：弱网环境可尝试 QUIC 系协议\n\n## 实操建议\n\n1. 先测 2–3 个邻近地区节点\n2. 高峰时段复测，避免只看单次结果\n3. 游戏优先低延迟，下载优先高带宽节点\n4. 使用 LiveMask 仪表盘查看节点健康与负载\n\n## 小结\n\n没有「永远最快」的节点，只有「当前网络下最合适」的节点。",
    },
    {
        "slug": "hysteria2-overview-zh",
        "title": "Hysteria2 协议解读：为不稳定网络而生的传输方案",
        "excerpt": "基于 QUIC 的 Hysteria2 如何在丢包与抖动环境下保持更高吞吐，以及 LiveMask 如何集成该协议。",
        "category": "技术科普",
        "tags": ["Hysteria2", "QUIC", "协议"],
        "markdown": "## Hysteria2 是什么\n\nHysteria2 构建在 QUIC/UDP 之上，针对高延迟、高丢包链路做了带宽与拥塞优化，适合移动网络与跨境线路。\n\n## 主要优势\n\n- 连接建立更快\n- 弱网下吞吐通常优于传统 TCP VPN\n- 内置混淆能力，有助于应对部分 DPI 场景\n\n## 何时使用\n\n如果你在 Wi-Fi 切换、4G/5G 或晚高峰经常出现卡顿，可在 LiveMask 客户端尝试切换到 Hysteria2，并与稳定节点组合使用。",
    },
    {
        "slug": "cross-platform-setup-zh",
        "title": "全平台安装 LiveMask：Windows / macOS / iOS / Android / Linux",
        "excerpt": "从下载、登录到首次连接的完整步骤，帮助你在所有设备上快速启用 VPN 保护。",
        "category": "安装教程",
        "tags": ["安装", "跨平台", "新手"],
        "markdown": "## Windows / macOS\n\n1. 从官网或管理后台指引下载对应安装包\n2. 安装后使用邮箱登录 LiveMask 账号\n3. 选择推荐节点并点击连接\n\n## iOS / Android\n\n在应用商店或官方渠道安装客户端，首次连接需允许 VPN 配置描述文件。\n\n## Linux\n\n使用官方 CLI 或图形客户端，通过命令行 connect 即可建立隧道。",
    },
    {
        "slug": "vpn-troubleshooting-zh",
        "title": "VPN 连不上？十个最常见问题与解决办法",
        "excerpt": "涵盖认证失败、DNS 泄露、速度慢、频繁掉线等典型故障的排查路径。",
        "category": "故障排查",
        "tags": ["故障排查", "DNS", "掉线"],
        "markdown": "## 常见问题\n\n1. 无法连接：检查网络、账号与防火墙\n2. 速度慢：换节点与协议\n3. DNS 泄露：启用客户端 DNS 保护\n4. 频繁断线：打开 Kill Switch\n5. 流媒体失败：切换地区节点\n\n按客户端日志逐项排除可快速定位原因。",
    },
    {
        "slug": "public-wifi-safety-zh",
        "title": "公共 Wi-Fi 安全上网：机场、咖啡馆必备 VPN 习惯",
        "excerpt": "在开放热点下如何防止中间人攻击、钓鱼门户与明文嗅探。",
        "category": "隐私安全",
        "tags": ["公共Wi-Fi", "安全习惯"],
        "markdown": "## 公共 Wi-Fi 的风险\n\n开放热点可能被伪造，攻击者可嗅探未加密流量。\n\n## 三条黄金法则\n\n1. 连接前先开 VPN\n2. 避免访问未加密的敏感后台\n3. 关闭自动加入未知网络",
    },
    {
        "slug": "gaming-latency-zh",
        "title": "游戏加速实战：用 VPN 降低跨境延迟的误区与正解",
        "excerpt": "解释 VPN 并非总是降低 Ping，以及如何为不同游戏服务器选择线路。",
        "category": "性能优化",
        "tags": ["游戏", "延迟", "加速"],
        "markdown": "## 正解思路\n\n- 选择靠近游戏服务器区域的节点\n- 使用 UDP 友好协议\n- 关闭不必要的后台下载\n\n连接前后分别 ping 游戏网关，观察抖动与丢包。",
    },
    {
        "slug": "streaming-unlock-zh",
        "title": "流媒体观看指南：地区内容与 VPN 合规使用",
        "excerpt": "从技术角度理解地区版权与 CDN 路由，并给出合规观看建议。",
        "category": "使用技巧",
        "tags": ["流媒体", "解锁", "合规"],
        "markdown": "## 合规提醒\n\n请遵守服务条款与当地法律，仅访问你有权观看的内容。\n\n选择带宽充足、晚高峰负载低的节点可获得更稳定的播放体验。",
    },
    {
        "slug": "remote-work-vpn-zh",
        "title": "企业远程办公 VPN：安全访问内网与云资源",
        "excerpt": "拆分隧道、设备合规与审计日志，帮助团队安全远程协作。",
        "category": "企业场景",
        "tags": ["远程办公", "企业", "零信任"],
        "markdown": "## 最佳实践\n\n- 按角色分配最小权限\n- 启用 MFA 与异常登录告警\n- 对敏感系统走全隧道\n- 对普通浏览启用拆分隧道",
    },
    {
        "slug": "dns-leak-fix-zh",
        "title": "DNS 泄露检测与修复：一步验证 VPN 是否真正生效",
        "excerpt": "教你使用检测网站判断 DNS/WebRTC 泄露，并在 LiveMask 客户端中关闭风险点。",
        "category": "隐私安全",
        "tags": ["DNS", "泄露", "检测"],
        "markdown": "## 检测步骤\n\n1. 连接 VPN\n2. 打开 dnsleaktest.com\n3. 确认解析商与节点地区一致\n\n启用防泄露 DNS 并禁用可疑系统代理。",
    },
    {
        "slug": "zero-log-vpn-zh",
        "title": "什么是零日志 VPN？如何判断服务商是否可信",
        "excerpt": "拆解「无日志」营销话术，从审计报告、司法互助与元数据保留角度评估。",
        "category": "隐私安全",
        "tags": ["零日志", "审计", "信任"],
        "markdown": "## 评估清单\n\n- 是否有第三方审计\n- 注册地司法环境\n- 是否收集支付身份\n\n零日志需结合技术架构与治理透明度判断。",
    },
    {
        "slug": "compliance-notice-zh",
        "title": "跨境网络使用合规提示：留学生与外贸从业者必读",
        "excerpt": "从授权访问、版权与数据跨境角度，整理常见合规边界。",
        "category": "合规科普",
        "tags": ["合规", "跨境", "法律"],
        "markdown": "## 基本原则\n\nVPN 是中性工具，关键在于用途是否合法、是否获得访问授权。\n\n请遵守当地法规与平台服务条款。",
    },
    {
        "slug": "mobile-battery-tips-zh",
        "title": "手机 VPN 省电技巧：延长续航的五个设置",
        "excerpt": "通过按需连接、拆分隧道与协议选择，在保护与续航之间取得平衡。",
        "category": "使用技巧",
        "tags": ["手机", "省电", "iOS", "Android"],
        "markdown": "## 省电建议\n\n1. 不用时断开 VPN\n2. 仅对需要的 App 走隧道\n3. 弱网再启用高吞吐协议\n4. 关闭不必要后台刷新",
    },
    {
        "slug": "mfa-with-vpn-zh",
        "title": "双因素认证与 VPN：构建多层账号安全",
        "excerpt": "在启用 VPN 的同时为邮箱、云盘与面板开启 MFA，降低撞库风险。",
        "category": "隐私安全",
        "tags": ["MFA", "2FA", "账号安全"],
        "markdown": "## 推荐组合\n\n- VPN 保护传输层\n- TOTP/硬件密钥保护账号\n- 管理后台独立强密码",
    },
    {
        "slug": "ipv6-vpn-zh",
        "title": "IPv6 与 VPN：泄露风险与关闭建议",
        "excerpt": "解释 IPv6 旁路如何导致真实地址暴露，以及客户端防护选项。",
        "category": "技术科普",
        "tags": ["IPv6", "泄露", "网络"],
        "markdown": "## 处理办法\n\n- 启用 IPv6 阻断或全隧道\n- 在路由器关闭未使用的 IPv6\n- 使用检测工具验证双栈出口",
    },
    {
        "slug": "split-tunnel-guide-zh",
        "title": "拆分隧道配置指南：哪些流量该走 VPN？",
        "excerpt": "按应用或网段精细分流，兼顾内网访问与本地设备互联。",
        "category": "使用技巧",
        "tags": ["拆分隧道", "分流", "高级"],
        "markdown": "## 配置原则\n\n默认敏感流量全隧道，按白名单放行本地网段。变更后务必重新做泄露检测。",
    },
    {
        "slug": "selfhost-vs-service-zh",
        "title": "自建节点与商业 VPN：运维成本对比",
        "excerpt": "从可用性、合规、协议维护与攻击面角度，帮助个人与团队做选择。",
        "category": "技术科普",
        "tags": ["自建", "运维", "对比"],
        "markdown": "## 对比\n\n自建可控但运维成本高；商业服务提供多地域 PoP 与客户端生态。多数用户选择商业 VPN 获得稳定体验。",
    },
    {
        "slug": "study-abroad-network-zh",
        "title": "留学上网指南：访问学术资源与日常社交",
        "excerpt": "为学校 SSO、在线图书馆与视频课程选择稳定线路的实用建议。",
        "category": "使用技巧",
        "tags": ["留学", "学术", "教育"],
        "markdown": "## 建议\n\n优先使用学校 VPN 或图书馆代理；LiveMask 可作为补充加密层。Zoom/Teams 对抖动敏感，选择低延迟节点。",
    },
    {
        "slug": "cross-border-ecommerce-zh",
        "title": "跨境电商运营：用 VPN 保护店铺与支付安全",
        "excerpt": "多店铺隔离、固定出口 IP 与团队权限管理的安全实践。",
        "category": "企业场景",
        "tags": ["电商", "跨境", "运营"],
        "markdown": "## 建议\n\n为每个店铺配置独立子账号与节点策略，禁止共享个人社交账号；结合 MFA 与操作审计。",
    },
    {
        "slug": "livemask-quickstart-zh",
        "title": "LiveMask 新手指南：三分钟完成首次连接",
        "excerpt": "注册、下载、选节点、验证连接的四步快速上手流程。",
        "category": "安装教程",
        "tags": ["新手", "LiveMask", "快速开始"],
        "markdown": "## 四步上手\n\n1. 注册账号\n2. 下载客户端\n3. 登录并选节点连接\n4. 验证 IP 与 DNS 泄露检测",
    },
]


def main() -> None:
    for article in ARTICLES:
        payload = {
            "slug": article["slug"],
            "locale": "zh-CN",
            "content_type": "blog_article",
            "title": article["title"],
            "excerpt": article["excerpt"],
            "content_markdown": article["markdown"],
            "status": "published",
            "visibility": "public",
            "author_name": "LiveMask 团队",
            "category": article["category"],
            "tags": article["tags"],
        }
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
