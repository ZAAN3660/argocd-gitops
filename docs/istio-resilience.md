# istio-resilience.md — 熔断 / 限流 / 重试 / 超时（v5）

依据 Istio 1.30.3 官方文档落地，四类韧性能力全部由 GitOps 声明式管理，
跟随 routing / 服务 overlay 按环境发散。本文档记录取值、依据与验证方法。

## 总览

| 能力 | 承载资源 | 代码位置 | 官方依据（1.30.3） |
|---|---|---|---|
| 熔断 | DestinationRule.trafficPolicy | 团队 base `destination-rule.yaml`（3 个灰度服务）+ reviews 自带 base DR | Tasks: Circuit Breaking |
| 限流 | EnvoyFilter（local_ratelimit） | routing base `envoyfilter-ratelimit.yaml`，每环境一份 | Tasks: Rate Limit（Local rate limiting 小节） |
| 重试 | VirtualService.http[].retries | routing 各 overlay `virtual-service.yaml` 四条权重路由 | API: HTTPRetry（官方示例取值） |
| 超时 | VirtualService.http[].timeout（含 retries.perTryTimeout） | 同上 | API: HTTPRoute.timeout / HTTPRetry.perTryTimeout |

## 1. 熔断（Circuit Breaking）

### 取值（官方 Circuit Breaking 任务页演示值，全部服务一致）

```yaml
trafficPolicy:
  connectionPool:
    tcp:
      maxConnections: 1            # 与上游最多 1 条 TCP 连接
    http:
      http1MaxPendingRequests: 1   # HTTP/1.1 排队请求上限
      maxRequestsPerConnection: 1  # 每条连接只复用 1 个请求
  outlierDetection:
    consecutive5xxErrors: 1        # 连续 1 次 5xx 即驱逐
    interval: 1s
    baseEjectionTime: 3m           # 驱逐 3 分钟后放回
    maxEjectionPercent: 100        # 允许驱逐全部实例
```

- 官方示例正是给 reviews 的 v1/v2/v3 挂这套策略，本仓库 reviews DR 与其同构；
  productpage/details/ratings 复用同一骨架，由 overlay patch 注入 DR 名与 FQDN host。
- **语义**：connectionPool 在客户端侧限制到上游的连接/请求并发（超限请求直接 503）；
  outlierDetection 把连续失败的实例踢出负载均衡池，起到"熔断不把流量继续往坏实例送"的效果。
- **官方演示值故意设得很小**，正常并发下也可能触发 503 + 驱逐。生产化调整见第 5 节。

### 验证

```bash
# 1) DR 已下发且挂到对应 host
kubectl get destinationrule -n dev
istioctl proxy-config cluster <productpage-pod> -n dev | grep details
# 2) 压测观察 503 与驱逐计数（bookinfo 镜像内无 fortio，用 gateway 或临时 fortio pod）
kubectl exec deploy/fortio -c fortio -- fortio load -c 3 -t 30s http://details:9080/details/0
kubectl exec deploy/fortio -c fortio -- fortio curl http://details:9080/details/0
```

## 2. 限流（Local Rate Limiting）

### 方案：本地限流（每 Envoy 实例独立计数）

- 官方 Rate Limit 任务页 "Local rate limiting" 示例原样落库：
  在 productpage sidecar 的 SIDECAR_INBOUND 链路上插入
  `envoy.filters.http.local_ratelimit`，token_bucket = 4 / 60s。
- 被限流的请求返回 **HTTP 429**，且响应头带 `x-local-rate-limit: "true"`（官方示例行为）。
- **每 Pod 计数**：4 req/min 是"每个 productpage Pod"的配额，Pod 扩容后总配额随之放大。
  需要全局精确限流时走官方 Global rate limiting：
  ratelimit 服务（ConfigMap 描述符 + samples/ratelimit/rate-limit-service.yaml）+
  `envoy.filters.http.ratelimit` 的 GATEWAY EnvoyFilter（须放 root namespace）。
- **命名空间作用域**：EnvoyFilter 随 routing overlay 渲染进 dev/staging/prod，
  只作用于同命名空间 `app=productpage` 的 sidecar，三个环境配额互相独立。

### 验证

```bash
kubectl get envoyfilter -n dev
# 连续请求 productpage，第 5 个起应看到 429 + 响应头
for i in $(seq 1 8); do
  curl -s -o /dev/null -w "%{http_code} %{header_json}" \
    -H "Host: bookinfo.example.com" http://<ingress-gateway-ip>/productpage | head -c 120; echo
done
# 确认过滤器已注入 sidecar
kubectl exec -n dev deploy/bookinfo-productpage-app -c istio-proxy -- \
  pilot-agent request GET config_dump | grep -c local_ratelimit
```

## 3. 重试（Retries）与 4. 超时（Timeouts）

写在 routing 层 VirtualService 的四条权重路由上（header/cookie 定向路由不加）：

| 路由 | timeout | retries |
|---|---|---|
| details-route / ratings-route / reviews-route | 5s（内部调用，正常 <1s，p99 目标 500ms） | attempts 3 × perTryTimeout 2s |
| productpage-route | 10s（入口，productpage 内部还要串行调 reviews+details） | attempts 3 × perTryTimeout 2s |

- `retryOn: gateway-error,connect-failure,refused-stream`：官方 HTTPRetry 示例原值
  （gateway-error = 502/503/504，connect-failure = 建连失败，refused-stream = H2 拒绝流）。
- `perTryTimeout` 必须小于路由 `timeout`，否则重试没有意义；官方示例 2s。
- **与 Rollouts 共存**：已核对 argo-rollouts v1.7 源码，发布切流时只原地改写
  `route[].route[idx].weight`，同路由的 timeout/retries/match 原样保留（见 mechanisms.md §6）。
- 注意：productpage-route 覆盖 POST /login，连接类错误重试对 bookinfo 登录基本无害；
  生产环境对非幂等 POST 需要评估 `retryOn` 里是否剔除 5xx 类条件。

### 验证

```bash
istioctl analyze -n dev --use-kube=false  # 或 istioctl validate
# 熔断演示 + 重试叠加效果：杀掉 ratings Pod 后立即请求，
# reviews 侧应观察到重试后成功（或 5xx 被驱逐计数增加）
kubectl get vs -n dev bookinfo -o yaml | grep -A5 retries
```

## 5. 生产化调整建议

| 项 | 当前演示值 | 生产建议 |
|---|---|---|
| maxConnections / http1MaxPendingRequests | 1 | 按压测结果定容量，常见 100~1024 |
| maxRequestsPerConnection | 1 | 保持 1 可防 H1 队头阻塞；有连接复用需求时放宽 |
| consecutive5xxErrors | 1 | 3~5（容忍瞬时抖动） |
| baseEjectionTime | 3m | 30s~60s + 设置 maxEjectionPercent ≤ 50% |
| 限流 token_bucket | 4 / 60s / Pod | 按入口容量评估；需要精确全局阈值改全局限流 |
| timeout | 5s / 10s | 按服务 P99 定（内部更紧，入口放宽） |
| retries | 3 × 2s | 幂等接口 2~3 次；非幂等接口关闭或收敛 retryOn |

## 6. 验证清单（合入后逐项过）

- [ ] `kustomize build` 全部 15 个 overlay 无语法错误
- [ ] `kubectl get destinationrule -n dev`：bookinfo-productpage/details/ratings-dr + bookinfo-reviews 各一份，host 为 FQDN
- [ ] `kubectl get envoyfilter -n dev`：filter-local-ratelimit-productpage 存在
- [ ] `kubectl get vs -n dev bookinfo -o yaml`：四条权重路由带 timeout/retries
- [ ] 连续刷新 productpage 页面可复现 429 + x-local-rate-limit 响应头
- [ ] 压测 details 可复现熔断 503 与驱逐
- [ ] 发布一次灰度（改镜像 tag 触发 Rollout），确认 timeout/retries 在切流期间未被抹掉
