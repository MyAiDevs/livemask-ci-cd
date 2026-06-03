#!/usr/bin/env python3
"""
knowledge_base.py — Structured tech reference for LiveMask dev loop.

Provides queryable knowledge about the technologies used in the project:
  - Go (Backend patterns, error handling, concurrency, testing)
  - Flutter/Dart (Widgets, state management, platform channels, build)
  - NodeJS/TypeScript (Next.js, React patterns, API routes)
  - VPN Networking (sing-box, Hysteria2, VLESS, routing, NAT)

Usage:
    knowledge_base.py list                               # List available topics
    knowledge_base.py get <topic> [--subtopic S]         # Get knowledge entry
    knowledge_base.py search <query>                     # Full-text search

Output: JSON to stdout.
"""

import json
import os
import re
import sys

# ── Structured Knowledge Registry ─────────────────────────────────────
# Each topic has: title, tags, summary, details (list of bullet points),
# patterns (code patterns / examples), and related_topics.

KNOWLEDGE: dict[str, dict] = {
    # ── Go ─────────────────────────────────────────────────────────────
    "go-project-layout": {
        "title": "Go Project Layout (Backend)",
        "tags": ["go", "backend", "architecture", "livemask-backend"],
        "summary": "Standard layering: Handler → Service → Repository. "
                    "Each layer has single responsibility. Dependency injection through struct fields.",
        "details": [
            "internal/api/handler/ — HTTP handlers, request parsing, response writing",
            "internal/api/service/ — Business logic, validation, orchestration",
            "internal/api/repository/ — Database access (PostgreSQL via pgx)",
            "internal/api/middleware/ — Auth, logging, rate limiting, CORS",
            "internal/api/model/ — Data models, request/response structs",
            "internal/api/router/ — Route definitions (chi router)",
            "internal/config/ — Configuration loading from env/file",
            "internal/database/ — Migrations, connection pool, query builders",
            "internal/worker/ — Asynq task handlers for background jobs",
        ],
        "patterns": [
            "Handler pattern: func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request)",
            "Service pattern: func (s *Service) Method(ctx context.Context, req Request) (*Response, error)",
            "Repository pattern: func (r *Repository) FindByID(ctx context.Context, id uuid.UUID) (*Model, error)",
            "Config: viper or envconfig, loaded once at startup",
        ],
        "related_topics": ["go-concurrency", "go-testing", "go-error-handling"],
    },
    "go-concurrency": {
        "title": "Go Concurrency Patterns",
        "tags": ["go", "concurrency", "goroutine", "channel"],
        "summary": "Goroutines for lightweight concurrency. Channels for communication. sync.WaitGroup for coordination.",
        "details": [
            "goroutines: go func() { ... }() — lightweight threads managed by Go runtime",
            "channels: make(chan T, N) — typed communication pipes, buffered or unbuffered",
            "select: multiplex multiple channel operations with timeout/deadline",
            "sync.WaitGroup: wait for goroutine completion",
            "sync.Mutex / sync.RWMutex: protect shared state",
            "context.Context: propagate cancellation, deadlines, and values across API boundaries",
            "errgroup: manage goroutine lifecycle with error propagation (golang.org/x/sync/errgroup)",
            "rate limiting: time.Ticker or golang.org/x/time/rate",
        ],
        "patterns": [
            "Fan-out: for _, item := range items { go worker(item) }",
            "Fan-in: merge multiple channels into one with select or reflection",
            "Pipeline: stage1 → channel → stage2 → channel → stage3",
            "Context: ctx, cancel := context.WithTimeout(parent, 5*time.Second); defer cancel()",
        ],
        "related_topics": ["go-project-layout", "go-error-handling"],
    },
    "go-testing": {
        "title": "Go Testing & Test Patterns",
        "tags": ["go", "testing", "test", "mock"],
        "summary": "Standard testing with 'go test'. Table-driven tests encouraged. Mock interfaces for unit testing.",
        "details": [
            "go test ./... -count=1 — run all tests, disable cache",
            "go test -run TestName — run specific test",
            "go test -v — verbose output",
            "go vet ./... — static analysis",
            "go test -bench=. — benchmark tests",
            "Testify: assert.Equal, require.NoError, suite",
            "gomock / mockgen: generate mock implementations from interfaces",
            "httptest: test HTTP handlers without starting a server",
            "testcontainers-go: integration tests with real DB/Redis",
        ],
        "patterns": [
            "Table-driven: tests := []struct{name string; input T; expected R}{...}; for _, tt := range tests { ... }",
            "Mock: storeMock := new(mocks.Store); storeMock.On(\"Find\", id).Return(result, nil)",
            "Integration: func TestMain(m *testing.M) { setup(); code := m.Run(); teardown(); os.Exit(code) }",
        ],
        "related_topics": ["go-project-layout", "go-error-handling"],
    },
    "go-error-handling": {
        "title": "Go Error Handling",
        "tags": ["go", "error", "error-handling"],
        "summary": "Go uses explicit error returns (not exceptions). Wrapping errors with context is the standard pattern.",
        "details": [
            "error is an interface: type error interface { Error() string }",
            "fmt.Errorf(\"context: %w\", err) — wrap errors with %w for unwrapping",
            "errors.Is(err, target) — check if error matches target (recursive unwrap)",
            "errors.As(err, &target) — find error of specific type in chain",
            "Custom error types: struct that implements Error() string",
            "Sentinel errors: var ErrNotFound = errors.New(\"not found\")",
            "Panic only for truly exceptional cases — never for expected errors",
            "defer func() { if r := recover(); r != nil { ... } }() — catch panics",
        ],
        "patterns": [
            "if err != nil { return fmt.Errorf(\"doing thing: %w\", err) }",
            "if errors.Is(err, ErrNotFound) { return nil, nil }",
            "type ValidationError struct { Field string; Msg string; func (e *ValidationError) Error() string }",
        ],
        "related_topics": ["go-testing", "go-concurrency"],
    },
    "go-database": {
        "title": "Go Database Access (PostgreSQL)",
        "tags": ["go", "database", "postgresql", "pgx", "migration"],
        "summary": "pgx v5 is the PostgreSQL driver. goose/golang-migrate for migrations. sqlx for query building.",
        "details": [
            "pgx: high-performance PostgreSQL driver with connection pooling",
            "pgxpool: conn, err := pgxpool.New(ctx, dsn)",
            "migrations: goose up/down, golang-migrate for versioned SQL",
            "SQL queries: raw SQL preferred over ORM for performance and transparency",
            "Prepared statements: reuse query plans, prevent SQL injection",
            "Transactions: tx, err := pool.Begin(ctx); defer tx.Rollback(); tx.Commit()",
            "Audit fields: created_at, updated_at, deleted_at (soft delete) on all core tables",
        ],
        "patterns": [
            "Query: rows, err := pool.Query(ctx, \"SELECT * FROM users WHERE id=$1\", id)",
            "Exec: _, err := pool.Exec(ctx, \"UPDATE users SET name=$1 WHERE id=$2\", name, id)",
            "Transaction: tx, _ := pool.Begin(ctx); tx.Exec(ctx, ...); tx.Commit()",
        ],
        "related_topics": ["go-project-layout", "go-testing"],
    },
    # ── Flutter/Dart ───────────────────────────────────────────────────
    "flutter-project-layout": {
        "title": "Flutter/Dart Project Layout (App)",
        "tags": ["flutter", "dart", "mobile", "app", "architecture"],
        "summary": "Flutter app with feature-based folder organization. "
                    "State management via Provider/Riverpod. Platform channels for native integration.",
        "details": [
            "lib/ — main application code",
            "lib/screens/ — full-page widgets per feature",
            "lib/widgets/ — reusable UI components",
            "lib/models/ — data models with JSON serialization",
            "lib/services/ — API clients, database, auth, connectivity",
            "lib/providers/ — state management (ChangeNotifier / Riverpod)",
            "lib/utils/ — helpers, constants, theme, i18n",
            "lib/router/ — navigation / GoRouter configuration",
            "android/ — Android native code (Kotlin/Java)",
            "ios/ — iOS native code (Swift/Objective-C)",
            "test/ — unit, widget, and integration tests",
        ],
        "patterns": [
            "Widget: class MyWidget extends StatelessWidget { @override Widget build(BuildContext context) { ... } }",
            "StatefulWidget: class MyWidget extends StatefulWidget { @override State<MyWidget> createState() => _MyWidgetState(); }",
            "Provider: ChangeNotifierProvider(create: (_) => MyProvider())",
            "JSON: factory MyModel.fromJson(Map<String, dynamic> json); Map<String, dynamic> toJson()",
            "Platform channel: MethodChannel('com.livemask/vpn').invokeMethod('connect')",
        ],
        "related_topics": ["flutter-state-management", "flutter-platform-channels", "flutter-build"],
    },
    "flutter-state-management": {
        "title": "Flutter State Management",
        "tags": ["flutter", "dart", "state", "management", "provider", "riverpod"],
        "summary": "Provider and Riverpod for state management. ChangeNotifier for reactive state. ConsumerWidget for rebuilding.",
        "details": [
            "Provider: simple dependency injection / state exposure",
            "ChangeNotifier: class extends ChangeNotifier { notifyListeners() }",
            "Consumer: Consumer<T>(builder: (ctx, value, child) => Widget) — rebuilds when T changes",
            "Selector: Selector<T, R> — rebuild only when selected value changes",
            "Riverpod: ref.read/provider.watch — compile-safe, testable",
            "StateNotifier: class extends StateNotifier<T> { ... } — immutable state + methods",
            "FutureProvider: async data loading with loading/error/data states",
            "StreamProvider: real-time data from streams",
        ],
        "patterns": [
            "Provider: MultiProvider(providers: [ChangeNotifierProvider(create: (_) => AuthProvider())])",
            "Consumer: final auth = context.watch<AuthProvider>(); if (auth.isLoading) return CircularProgressIndicator()",
            "Riverpod: final counterProvider = StateNotifierProvider<Counter, int>((ref) => Counter())",
        ],
        "related_topics": ["flutter-project-layout", "flutter-platform-channels"],
    },
    "flutter-platform-channels": {
        "title": "Flutter Platform Channels (Native Bridge)",
        "tags": ["flutter", "dart", "platform-channel", "native", "bridge"],
        "summary": "MethodChannel for bidirectional Flutter ↔ Native communication. "
                    "Used for VPN (TUN fd), secure storage, biometrics, and system-level operations.",
        "details": [
            "MethodChannel: flutter side calls invokeMethod; native side handles via setMethodCallHandler",
            "BasicMessageChannel: string/simple message passing",
            "EventChannel: streaming data from native to flutter (battery level, sensor data)",
            "Pigeon: code-gen type-safe channel interfaces (recommended for new code)",
            "livemask-app uses MethodChannel('com.livemask/vpn') for VPN connection lifecycle",
            "flutter_secure_storage: wraps Keychain (iOS) / EncryptedSharedPreferences (Android)",
        ],
        "patterns": [
            "Dart: static const channel = MethodChannel('com.livemask/vpn'); final result = await channel.invokeMethod('connect', args)",
            "Android: Channel(flutterEngine.dartExecutor.binaryMessenger, 'com.livemask/vpn').setMethodCallHandler { call, result -> ... }",
            "iOS: FlutterMethodChannel(name: 'com.livemask/vpn', binaryMessenger: controller.binaryMessenger).setMethodCallHandler { call, result in ... }",
        ],
        "related_topics": ["flutter-project-layout", "flutter-build"],
    },
    "flutter-build": {
        "title": "Flutter Build & Release",
        "tags": ["flutter", "build", "release", "apk", "ipa"],
        "summary": "Build commands for debug/release. Android APK/AAB. iOS archive. Code signing.",
        "details": [
            "flutter build apk --debug — debug APK for testing",
            "flutter build apk — release APK",
            "flutter build appbundle — Android App Bundle (Google Play)",
            "flutter build ios — iOS build (requires macOS + Xcode)",
            "flutter build ipa — iOS archive for TestFlight/App Store",
            "flutter test — run all tests",
            "flutter analyze — static analysis / lint",
            "Android signing: gradle.properties + keystore for release builds",
            "iOS signing: Xcode project team ID + provisioning profile",
            "gomobile bind — build Go library for mobile (used for sing-box integration)",
        ],
        "patterns": [
            "Debug: flutter build apk --debug --target-platform android-arm64",
            "Release: flutter build apk --split-per-abi (splits by architecture)",
            "Go mobile: gomobile bind -target=android/arm64 -o lib/main.aar ./pkg/mobile",
        ],
        "related_topics": ["flutter-project-layout", "flutter-platform-channels"],
    },
    # ── NodeJS / TypeScript ────────────────────────────────────────────
    "nodejs-project-layout": {
        "title": "NodeJS / TypeScript Project Layout",
        "tags": ["nodejs", "typescript", "nextjs", "react", "frontend"],
        "summary": "Next.js App Router for admin dashboard and website. "
                    "React components, Server Components, API routes, middleware.",
        "details": [
            "app/ — Next.js App Router pages and layouts",
            "app/api/ — API routes (Backend proxy for admin)",
            "components/ — Reusable React components",
            "lib/ — Utilities, API clients, helpers",
            "hooks/ — Custom React hooks",
            "styles/ — CSS modules, Tailwind config",
            "public/ — Static assets",
            "middleware.ts — Next.js middleware (auth, redirects, headers)",
            "next.config.js — Next.js configuration (rewrites, headers, images)",
            "package.json — Dependencies and scripts",
            "tsconfig.json — TypeScript configuration",
        ],
        "patterns": [
            "Page: export default async function Page() { return <div>...</div> }",
            "API route: export async function GET(req: NextRequest) { return Response.json(data) }",
            "Layout: export default function RootLayout({ children }: { children: React.ReactNode })",
            "Middleware: export function middleware(req: NextRequest) { return NextResponse.redirect(...) }",
        ],
        "related_topics": ["typescript-patterns", "nodejs-api-routes"],
    },
    "typescript-patterns": {
        "title": "TypeScript Patterns",
        "tags": ["typescript", "ts", "types", "patterns"],
        "summary": "Strong typing, interfaces, generics, discriminated unions. "
                    "Zod for runtime validation. tRPC for type-safe APIs (future).",
        "details": [
            "interface / type — define object shapes",
            "Generics: function getById<T>(id: string): Promise<T>",
            "Discriminated unions: type Result<T> = { status: 'success'; data: T } | { status: 'error'; error: Error }",
            "Zod: const schema = z.object({ name: z.string() }); schema.parse(data)",
            "satisfies keyword: ensure type compatibility without widening",
            "as const: literal types for readonly objects",
            "Template literal types: type EventName = `on${Capitalize<string>}`",
            "Conditional types: type IsString<T> = T extends string ? true : false",
        ],
        "patterns": [
            "Zod validation: const parsed = userSchema.parse(raw); parsed.username type-safe",
            "Discriminated: if (result.status === 'success') { result.data /* typed */ }",
            "Generic function: async function fetchApi<T>(url: string): Promise<T> { ... }",
        ],
        "related_topics": ["nodejs-project-layout", "nodejs-api-routes"],
    },
    "nodejs-api-routes": {
        "title": "Next.js API Routes & Backend Proxy",
        "tags": ["nextjs", "api", "routes", "proxy", "middleware"],
        "summary": "Admin uses API routes as proxy to Backend. App Router handlers. "
                    "Rewrites for /api/* to Backend. Auth token forwarding.",
        "details": [
            "app/api/[...path]/route.ts — catch-all proxy route",
            "Rewrites in next.config.js: async rewrites() { return [{ source: '/api/:path*', destination: 'http://backend:8080/api/:path*' }] }",
            "Middleware: attach auth token to API requests",
            "Route handlers: export async function GET/POST/PUT/DELETE(req, { params })",
            "Edge runtime vs Node.js runtime — choose via export const runtime = 'nodejs'",
            "Server Actions: form mutations without API routes",
        ],
        "patterns": [
            "Proxy: export async function GET(req) { const res = await fetch(`http://backend:8080${req.nextUrl.pathname}`); return res }",
            "Middleware: request.headers.set('Authorization', `Bearer ${token}`); return NextResponse.rewrite(request)",
        ],
        "related_topics": ["nodejs-project-layout", "typescript-patterns"],
    },
    # ── VPN / Networking ───────────────────────────────────────────────
    "vpn-sing-box": {
        "title": "sing-box VPN Architecture",
        "tags": ["vpn", "sing-box", "proxy", "network", "tunnel"],
        "summary": "sing-box is the core VPN engine. Universal proxy platform. "
                    "Go-based, config-driven. Used as TUN interface provider for the VPN tunnel.",
        "details": [
            "sing-box: universal proxy platform, Go-based, configurable via JSON",
            "TUN mode: creates virtual network interface, routes all traffic through",
            "Inbound: listens for connections (TUN interface = all system traffic)",
            "Outbound: connects to proxy servers (Hysteria2, VLESS, Shadowsocks, etc.)",
            "Route: routing rules based on destination IP/domain, geoip, geosite",
            "DNS: DNS resolution and routing via RuleSet",
            "Experimental: CLASH_API for real-time traffic statistics",
            "libbox: Go mobile library for Android/iOS integration",
            "Config via JSON: { \"inbounds\": [...], \"outbounds\": [...], \"route\": {...} }",
        ],
        "patterns": [
            "Config: { 'log': {'level':'info'}, 'inbounds':[{'type':'tun','address':'10.0.0.1/30'}], 'outbounds':[{'type':'direct'}] }",
            "Route rule: { 'rule_set': ['geoip-cn'], 'outbound': 'direct' }",
            "Outbound: { 'type':'hysteria2', 'server':'example.com:443', 'auth_str':'password' }",
        ],
        "related_topics": ["vpn-protocols", "vpn-hysteria2", "vpn-tun"],
    },
    "vpn-hysteria2": {
        "title": "Hysteria2 Protocol",
        "tags": ["vpn", "hysteria2", "protocol", "proxy", "udp"],
        "summary": "Hysteria2 is a proxy protocol based on QUIC. Designed for high performance over lossy networks. "
                    "Used by livemask as primary protocol for VPN connections.",
        "details": [
            "Based on QUIC (HTTP/3) — runs over UDP, not TCP",
            "Brutal congestion control: sends at configurable rate regardless of packet loss",
            "Masquerade: hides as HTTP/3 traffic to bypass deep packet inspection",
            "Auth: password or TLS client certificate",
            "Obfuscation: password-based traffic obfuscation",
            "Multi-port: receive on multiple ports with single listener",
            "Bandwidth estimation: client reports observed bandwidth to server",
            "sing-box implements hysteria2 as built-in outbound/inbound protocol",
            "ProtocolProfile in livemask: server address, port, auth, bandwidth, obfuscation params",
        ],
        "patterns": [
            "sing-box Hysteria2 outbound: { 'type': 'hysteria2', 'server':'host:port', 'password':'pass', 'tls':{'enabled':true,'server_name':'host'}}",
            "Bandwidth: { 'up_mbps': 100, 'down_mbps': 500 } — client-side bandwidth limits",
        ],
        "related_topics": ["vpn-sing-box", "vpn-protocols", "vpn-tun"],
    },
    "vpn-protocols": {
        "title": "VPN Protocol Landscape",
        "tags": ["vpn", "protocols", "proxy", "shadowsocks", "vless", "trojan"],
        "summary": "Modern proxy protocols: VLESS, Shadowsocks, Trojan, Hysteria2. "
                    "Each has different tradeoffs for speed, security, and censorship resistance.",
        "details": [
            "VLESS: lightweight VMess successor, no encryption overhead, relies on TLS",
            "Shadowsocks: encrypted with AEAD ciphers (chacha20, aes-gcm), simple and effective",
            "Trojan: mimics HTTPS traffic with TLS, falls back to web server on probe",
            "Hysteria2: QUIC-based, designed for high packet loss networks",
            "TUIC: QUIC-based, focuses on multiplexing, lower overhead than Hysteria",
            "WireGuard: kernel-level VPN, simple and fast, used for site-to-site",
            "OpenVPN: mature, widely supported, but higher overhead",
            "ProtocolProfile: livemask abstraction layer for protocol configuration",
            "sing-box supports all major protocols as built-in outbound/inbound types",
        ],
        "patterns": [
            "sing-box VLESS: { 'type': 'vless', 'server':'host:port', 'uuid':'...', 'flow':'xtls-rprx-vision' }",
            "sing-box Shadowsocks: { 'type': 'shadowsocks', 'server':'host:port', 'method':'aes-256-gcm', 'password':'pass' }",
        ],
        "related_topics": ["vpn-sing-box", "vpn-hysteria2", "vpn-tun"],
    },
    "vpn-tun": {
        "title": "TUN Interface & VPN Routing",
        "tags": ["vpn", "tun", "network", "routing", "interface"],
        "summary": "TUN (virtual network kernel driver) creates a virtual network interface. "
                    "All system traffic can be routed through it for VPN functionality.",
        "details": [
            "TUN: Layer 3 (IP) virtual interface — processes IP packets",
            "TAP: Layer 2 (Ethernet) virtual interface — bridges networks",
            "Platform implementation: Linux (dev tun), macOS (utun), Android (VpnService)",
            "iOS: NetworkExtension / PacketTunnelProvider for TUN interface",
            "Android VPN: VpnService.Builder creates TUN interface, read/write file descriptor",
            "Routing: default route → TUN interface → VPN server",
            "Split tunneling: only route specific destinations through VPN",
            "DNS: VPN can override system DNS with custom DNS servers",
            "MTU: TUN interface MTU typically 1500 bytes, may need adjustment for VPN overhead",
            "sing-box handles TUN fd read/write internally — no manual packet processing needed",
        ],
        "patterns": [
            "Android: VpnService.Builder().setMtu(1500).addAddress('10.0.0.2', 32).addRoute('0.0.0.0', 0).establish()",
            "iOS: class PacketTunnelProvider: NEPacketTunnelProvider { override func startTunnel(...) }",
            "Flutter: MethodChannel → platform native → VpnService/TUN fd → Go sing-box engine",
        ],
        "related_topics": ["vpn-sing-box", "vpn-hysteria2", "vpn-protocols"],
    },
    "vpn-nat-sharing": {
        "title": "NAT Sharing Detection & Prevention",
        "tags": ["vpn", "nat", "sharing", "security", "detection"],
        "summary": "Prevent VPN client from acting as NAT/router for other devices. "
                    "Techniques: TTL hop detection, HTTP User-Agent entropy, connection count heuristics.",
        "details": [
            "TTL-based detection: shared connections have different TTL hops from the real client",
            "User-Agent entropy: multiple distinct UA strings from same IP = sharing",
            "Connection count: abnormally high concurrent connection count indicates sharing",
            "GeoIP inconsistency: client IP geo mismatch with VPN entry point",
            "Protocol-level: HTTP/3 connection migration detection",
            "Enforcement: throttle bandwidth, disconnect, or flag for manual review",
            "livemask-nodeagent implements backend-based detection",
            "livemask-backend stores flag results and enforces limits",
        ],
        "patterns": [
            "TTL check: ttl = ip_hdr.TTL; if abs(ttl - expected_ttl) > threshold { possible_share = true }",
            "UA entropy: count_unique_user_agents(ip, window=5min); if count > threshold { sharing_flag = true }",
        ],
        "related_topics": ["vpn-sing-box", "vpn-protocols"],
    },
}


def _load_search_text() -> str:
    """Build plain-text index from all knowledge entries."""
    parts = []
    for topic, entry in KNOWLEDGE.items():
        parts.append(f"{entry['title']}: {entry['summary']}")
        for d in entry.get("details", []):
            parts.append(d)
        for p in entry.get("patterns", []):
            parts.append(p)
    return "\n".join(parts)


def _search(query: str) -> list[dict]:
    """Full-text search across all knowledge entries using simple keyword matching."""
    ql = query.lower()
    results = []

    for topic, entry in KNOWLEDGE.items():
        # Build searchable text
        searchable = f"{entry['title']} {entry['summary']} {' '.join(entry['details'])} {' '.join(entry['patterns'])} {' '.join(entry['tags'])}"
        sl = searchable.lower()

        # Score by keyword match density
        score = 0
        words = ql.split()
        for w in words:
            score += sl.count(w) * 10

        # Bonus for exact phrase match
        if ql in sl:
            score += 50

        # Bonus for tag match
        for t in entry["tags"]:
            if t in ql or ql in t:
                score += 30

        if score > 0:
            results.append({
                "topic": topic,
                "title": entry["title"],
                "tags": entry["tags"],
                "score": score,
            })

    results.sort(key=lambda x: -x["score"])
    return results


# ── Commands ─────────────────────────────────────────────────────────

def cmd_list(args: list[str]) -> int:
    """List all available topics."""
    topics = []
    for topic, entry in sorted(KNOWLEDGE.items()):
        topics.append({
            "topic": topic,
            "title": entry["title"],
            "tags": entry["tags"],
            "summary": entry["summary"][:100] + "..." if len(entry["summary"]) > 100 else entry["summary"],
        })

    # Group by domain
    by_domain = {}
    for t in topics:
        domain = "unknown"
        for tag in t["tags"]:
            if tag in ("go", "flutter", "dart", "nodejs", "typescript", "vpn"):
                domain = tag
                break
        by_domain.setdefault(domain, []).append(t)

    print(json.dumps({
        "total_topics": len(topics),
        "by_domain": by_domain,
        "topics": topics,
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_get(args: list[str]) -> int:
    """knowledge_base.py get <topic> [--subtopic S]"""
    if not args:
        print(json.dumps({"error": "usage: get <topic> [--subtopic S]"}))
        return 1

    topic = args[0]
    subtopic = ""

    for i in range(1, len(args)):
        if args[i] == "--subtopic" and i + 1 < len(args):
            subtopic = args[i + 1]

    if topic not in KNOWLEDGE:
        # Try fuzzy match
        matches = [k for k in KNOWLEDGE if topic.lower() in k.lower()]
        if matches:
            topic = matches[0]
        else:
            print(json.dumps({"error": f"topic not found: {topic}"}))
            return 1

    entry = KNOWLEDGE[topic]

    if subtopic:
        # Filter to specific subtopic
        filtered = {
            "topic": topic,
            "title": entry["title"],
            "subtopic": subtopic,
        }
        if subtopic in entry:
            filtered["content"] = entry[subtopic]
        else:
            # Search across details and patterns
            matches = [d for d in entry.get("details", []) if subtopic.lower() in d.lower()]
            if matches:
                filtered["details_matching"] = matches
            pat_matches = [p for p in entry.get("patterns", []) if subtopic.lower() in p.lower()]
            if pat_matches:
                filtered["patterns_matching"] = pat_matches
        print(json.dumps(filtered, indent=2, ensure_ascii=False))
    else:
        print(json.dumps({
            "topic": topic,
            "title": entry["title"],
            "tags": entry["tags"],
            "summary": entry["summary"],
            "details": entry["details"],
            "patterns": entry["patterns"],
            "related_topics": entry.get("related_topics", []),
        }, indent=2, ensure_ascii=False))
    return 0


def cmd_search(args: list[str]) -> int:
    """knowledge_base.py search <query>"""
    if not args:
        print(json.dumps({"error": "usage: search <query>"}))
        return 1

    query = " ".join(args)
    results = _search(query)

    print(json.dumps({
        "query": query,
        "total_results": len(results),
        "results": results[:10],
    }, indent=2, ensure_ascii=False))
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return 0 if sys.argv[1:2] in (["--help"], ["-h"]) else 1

    command = sys.argv[1]
    args = sys.argv[2:]

    cmds = {
        "list": cmd_list,
        "get": cmd_get,
        "search": cmd_search,
    }

    if command not in cmds:
        print(json.dumps({"error": f"unknown command: {command}"}), file=sys.stderr)
        return 1

    try:
        rc = cmds[command](args)
        sys.exit(rc)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
