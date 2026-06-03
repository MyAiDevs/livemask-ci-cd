# Hysteria2 Deployment Notes

> Supplement document — Hysteria2 protocol deployment and tuning
> Source: https://github.com/apernet/hysteria + community best practices

## Server Configuration

```yaml
listen: :443
tls:
  cert: /path/to/cert.pem
  key: /path/to/key.pem
auth:
  type: password
  password: changeme
quic:
  init_stream_ receive_window: 8388608
  max_stream_receive_window: 8388608
  keep_alive_period: 10s
bandwidth:
  up: 1 gbps
  down: 1 gbps
masquerade:
  type: proxy
  proxy:
    url: https://example.com/
    rewrite_host: true
```

## Client Configuration (standalone, not sing-box)

```yaml
server: example.com:443
auth: password
tls:
  sni: example.com
  insecure: false
bandwidth:
  up: 100 mbps
  down: 500 mbps
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
```

## Performance Tuning

1. Bandwidth estimation: enable client-side for adaptive speed
2. QUIC buffer: increase kernel UDP buffer (net.core.rmem_max, net.core.wmem_max)
3. Masquerade: always enable to bypass DPI
4. Obfuscation: use password-based obfuscation if TLS fingerprint is an issue
5. Multi-port: use `"listen": ":443"` single-port for simplicity

## Known Issues

- QUIC over UDP: some ISPs throttle UDP; TCP fallback not natively supported
- Connection migration: NOT fully supported in hysteria2 (unlike raw QUIC)
- Bandwidth cap: enforced server-side; client cap is advisory
