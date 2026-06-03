# sing-box Configuration Patterns

> Supplement document — livemask-nodeagent sing-box integration patterns
> Source: https://sing-box.sagernet.org/ + livemask implementation

## Common Profiles in livemask

### TUN Inbound (Standard)

```json
{
  "inbounds": [{
    "type": "tun",
    "interface_name": "tun0",
    "address": ["10.0.0.1/30"],
    "mtu": 1500,
    "auto_route": true,
    "strict_route": false
  }]
}
```

### Hysteria2 Outbound

```json
{
  "outbounds": [{
    "type": "hysteria2",
    "tag": "hy2-out",
    "server": "example.com:443",
    "up_mbps": 100,
    "down_mbps": 500,
    "password": "auth-token",
    "tls": {
      "enabled": true,
      "server_name": "example.com",
      "insecure": false
    }
  }]
}
```

### VLESS Outbound

```json
{
  "outbounds": [{
    "type": "vless",
    "tag": "vless-out",
    "server": "example.com:443",
    "uuid": "uuid-here",
    "flow": "xtls-rprx-vision",
    "tls": { "enabled": true, "server_name": "example.com" }
  }]
}
```

## Route Rules

```json
{
  "route": {
    "rules": [
      { "rule_set": ["geoip-cn"], "outbound": "direct" },
      { "rule_set": ["geosite-cn"], "outbound": "direct" },
      { "rule_set": ["geosite-category-ads"], "outbound": "block" }
    ],
    "rule_set": [
      { "type": "remote", "tag": "geoip-cn", "url": "https://...", "download_detour": "proxy-out" },
      { "type": "remote", "tag": "geosite-cn", "url": "https://..." }
    ],
    "final": "hy2-out",
    "auto_detect_interface": true
  }
}
```

## Key Rules for livemask

1. Never store full config in code — construct from ProtocolProfile
2. Always set `tls.insecure: false` in production
3. Use `"domain_strategy": "prefer_ipv6"` for IPv6 support
4. Keep `"experimental"` section minimal — only CLASH_API for metrics
5. TUN MTU: 1500 is safe default; lower (1300-1400) for lossy networks
