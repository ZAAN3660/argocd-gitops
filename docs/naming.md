# naming.md — 目录定义与维度路由

## 维度路由（hub 模式，单集群形态）

| 维度 | 承载层 | 当前形态 |
|---|---|---|
| 集群 | cluster secret + ApplicationSet list | hub 集群自用，`server` 统一为 https://kubernetes.default.svc |
| 环境 | ApplicationSet list 元素 + `overlays/<env>` 目录 | dev / staging / prod 三环境，staging 与 prod 同集群靠 namespace 区分 |
| 团队 | `apps/<domain>/` 目录 + 一个 AppProject | rd-backend 域（rd 团队） |
| 应用域 | 团队内的命名空间 | bookinfo 系列 |

## 目录定义

- `bootstrap.yaml`：根应用，唯一手动 apply 一次，只同步 `argocd-settings/`
- `argocd-settings/`：Argo CD 自身配置——project 权限边界、appset 生成规则
- `apps/<domain>/base/`：应用域公共 workload 骨架，标准 overlay 引用它
- `apps/<domain>/microservices/<service>/overlays/<env>/`：每个服务、每个环境一个 overlay，ApplicationSet 扫描点
- reviews：不引用团队 base，自带 base（三版本 Deployment 特例）
- bookinfo-routing：base 放 Gateway，VirtualService 按环境差异放 overlay

## 命名约定

- 应用名 = `rd-<服务目录名>-<环境名>`，由 appset template 生成
- namespace = `<env>`（dev/staging/prod），与 appset list 条目严格一致
- Rollout 名 = `bookinfo-<服务>-app`；稳定 Service 名 = 官方短名；金丝雀 Service 名 = `<短名>-canary`
- **Service 名 = 官方短名**（productpage/details/reviews/ratings）：bookinfo 镜像硬编码了这些 DNS 名，改名会导致服务间调用失败
- 标签：`app: <短名>`；reviews 额外带 `version: v1/v2/v3` 供 DestinationRule 切分 subset
- DestinationRule 名 = `bookinfo-<服务>-dr`（reviews 例外：`bookinfo-reviews`，随自带 base 发布）
- 镜像 tag：1.16.2，官方独立镜像最后版本

## 灰度发布约定（Argo Rollouts）

- 路由名 = `<短名>-route`：写在 routing 层 VirtualService 里，Rollout 的 trafficRouting 只引用这一条权重路由
- header/cookie 定向规则：`<短名>-header-canary` / `<短名>-cookie-canary`，静态不归 Rollout 管
- 发布节奏：10 → 25 → 75 → 100，每步 pause 后由 AnalysisRun 自动判断继续或回滚
- 分析模板三件（traffic-check / success-rate / p99-latency）：每环境一份，放 routing base，各服务 Rollout 共用
- KEDA 触发器三件：CPU 80% / 内存 75% / QPS（网格指标），扩缩容目标是 Rollout 而非 Deployment
- Argo CD 豁免（appset ignoreDifferences）：Rollout 的 rollouts-pod-template-hash 标签、VS 权重、Service selector 三处由 Rollout 控制器运行时动态改，Argo CD 不得视为漂移回滚
- reviews 未接入 Rollouts：保留 v1/v2/v3 subset 演示（官方 bookinfo 灰度样例）
- 探针用 tcpSocket：bookinfo 镜像无统一就绪端点；KEDA Utilization 依赖 resources.requests，base 已写死 demo 值

## 韧性配置约定（熔断/限流/重试/超时，v5 新增）

- **熔断**：DestinationRule.trafficPolicy（connectionPool + outlierDetection），取值照官方 Circuit Breaking 演示值
  - reviews：写在自带 base 的 destination-rule.yaml（subset + trafficPolicy，与官方 bookinfo 熔断示例同构）
  - productpage/details/ratings：团队 base 骨架 + 各 overlay patch 注入 DR 名与 FQDN host
- **限流**：本地限流 EnvoyFilter（envoy.filters.http.local_ratelimit），放 routing base 随环境渲染，
  只作用于同命名空间 app=productpage 的 sidecar（每 Pod 4 req/min，官方演示值）
- **重试/超时**：写在 routing 层 VirtualService 四条权重路由上（内部 5s / 入口 10s；
  retries 3 次 × perTry 2s，retryOn gateway-error,connect-failure,refused-stream）
- **共存边界**：Rollouts 只改写 route[].weight，不覆盖同路由的 timeout/retries；
  header/cookie 定向路由不加韧性字段（保持最小配置）
