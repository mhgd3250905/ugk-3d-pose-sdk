# ugk-coach-relay

AI 训练助理中转 Worker：DeepSeek key 只在 Worker，App 只带可吊销的 App 令牌。

- 地址：`https://ugk-coach-relay.294851575.workers.dev`（Cloudflare 账号 294851575@qq.com）
- 接口：`POST /v1/chat/completions`（OpenAI 兼容）；`GET /health` 查看是否已配置上游 key
- 鉴权：请求头 `X-App-Token`，按 App 区分（secret `APP_TOKENS`，JSON：`{"flarelab":"…","hiplab":"…","smartfit":"…"}`）；吊销某个 App = 改这份 JSON
- 上游 key：secret `OPENCSG_API_KEY`
- 服务端固定模型 `deepseek-v4.1-flash-1017`、max_tokens 上限 8000、请求体 ≤64KB、只透传白名单字段
- 限流：每个 App+IP 每 60 秒 10 次（Cloudflare ratelimit 绑定 `RL`）
- 日志：每次只记 app、上游状态码、耗时（Workers Observability），不记内容

App 侧：`--dart-define=UGK_COACH_BASE_URL=https://ugk-coach-relay.294851575.workers.dev/v1 --dart-define=UGK_COACH_RELAY_TOKEN=<App 令牌>`，不再传 key。

部署：Cloudflare API `PUT /accounts/{id}/workers/scripts/ugk-coach-relay`（metadata 含 ratelimit 绑定），或 `wrangler deploy`（见 wrangler.toml）。
