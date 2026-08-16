# naming.md — 命名规范与维度路由

## 命名规范的官方依据

| 依据 | 内容 | 来源 |
|---|---|---|
| DNS-1123 subdomain | 名字只能小写字母/数字/连字符，以字母数字开头结尾 | Kubernetes 官方文档 *Object Names and IDs* |
| 命名空间即环境边界 | 环境用 namespace 表达，命名空间内同名复用是惯例 | Kubernetes 官方文档 *Namespaces* + GitOps 多环境主流做法 |
| Recommended Labels | `app.kubernetes.io/name / instance / part-of / managed-by` 等标准标签表达归属关系 | Kubernetes 官方文档 *Recommended Labels* |
| bookinfo 官方样例 | VS=`bookinfo`、Gateway=`bookinfo-gateway`、DR=`reviews`（裸短名） | istio/istio samples/bookinfo |
| Argo Rollouts 官方约定 | 灰度配套服务名 = `<rollout>-canary` / `<rollout>-stable` | argo-rollouts 官方文档 Istio 示例 |
| Argo CD 多环境惯例 | 应用名 = `<app>-<env>`（同 namespace 多条必须带环境段） | Argo CD 官方文档 ApplicationSet 示例 |

## 核心原则（三条）

1. **环境归属靠 namespace，不靠名字**：dev/staging/prod 各占一个命名空间，
   同一资源类型在三个环境里同名共存是 Kubernetes 惯例（名字唯一性只要求
   namespace 内 kind 内唯一）。名字里塞环境段反而制造噪音。
2. **环境后缀只出现在共享 namespace**：目前唯一共享 namespace 是 argocd，
   所以只有 Argo CD Application 名带环境段：`shop-<服务>-<env>`。
   将来若出现 istio-system / monitoring 里的共享资源，也必须带环境前缀。
3. **类型语义不进名字、进标签**：Kubernetes 官方推荐用 `app.kubernetes.io/component`
   表达组件类型。本仓库的角色后缀（-app/-scaler/-monitor/-dr/-canary）是
   仓库约定，为的是 `kubectl get <kind>` 输出里名字自解释；类型归属同时用
   官方推荐标签兜底（见下文标签规范）。

## 资源命名总表

### 共享 namespace（argocd）——必须带环境段

| Kind | 名字 | 环境段 | 说明 |
|---|---|---|---|
| Application | `shop-<服务目录名>-<env>` | ✅ 必须有 | 15 条挤在同一个 argocd namespace，靠环境段区分 |
| ApplicationSet | `shop-backend` | ❌ | 一条规则覆盖所有环境 |
| AppProject | `shop-<团队>` | ❌ | 团队边界，与环境无关 |

### 环境 namespace（dev/staging/prod）——名字不带环境段

| Kind | 名字模式 | 实例 | 依据 |
|---|---|---|---|
| Namespace | `<env>` | dev | 本身就是环境 |
| Service（稳定通道） | `<短名>` | productpage | bookinfo 镜像硬编码，不可改 |
| Service（金丝雀通道） | `<短名>-canary` | productpage-canary | Argo Rollouts 官方约定 |
| Rollout | `bookinfo-<服务>-app` | bookinfo-productpage-app | 仓库统一角色后缀 |
| ScaledObject | `bookinfo-<服务>-scaler` | bookinfo-productpage-scaler | 同上 |
| PodMonitor | `bookinfo-<服务>-monitor` | bookinfo-productpage-monitor | 同上 |
| DestinationRule | `bookinfo-<服务>-dr` | bookinfo-productpage-dr / bookinfo-reviews-dr | 同上（官方样例用裸短名，仓库统一带 -dr 便于跨类型检索） |
| Deployment | `bookinfo-reviews-<version>` | bookinfo-reviews-v1 | 三版本并存靠版本段区分 |
| VirtualService | `bookinfo` | 每环境一份 | Istio 官方 bookinfo 样例原名 |
| Gateway | `bookinfo-gateway` | 每环境一份 | Istio 官方 bookinfo 样例原名 |
| EnvoyFilter | `filter-<功能>-<目标>` | filter-local-ratelimit-productpage | Istio 官方 Rate Limit 示例模式（filter-local-ratelimit-svc） |
| AnalysisTemplate | `<指标语义>` | traffic-check / success-rate / p99-latency | Rollouts 官方示例风格 |

### 名字内部引用关系（改名时的连锁影响）

- Rollout 名被引用：ScaledObject.scaleTargetRef.name；ReplicaSet 名 `<rollout>-<hash>`
- 短名被引用：VS destination host、DR host（FQDN）、Rollout stable/canaryService
- 路由名 `<短名>-route` 被引用：Rollout trafficRouting.virtualService.routes
- VS 名 `bookinfo` 被引用：Rollout trafficRouting.virtualService.name
- Gateway 名被引用：VS gateways 字段（同 namespace 内解析）
- DR / EnvoyFilter / AnalysisTemplate 名字不被其他资源按名引用（DR 靠 host 关联；
  AnalysisTemplate 仅被同 namespace 的 Rollout analysis.templates 引用）

## 标签规范（K8s Recommended Labels）

功能标签与官方推荐标签分工：

| 标签键 | 值 | 承担功能 | 是否进选择器 |
|---|---|---|---|
| `app` | `<短名>`（reviews 例外沿用 `bookinfo-reviews`，历史遗留值） | 选择器/灰度身份/PodMonitor 匹配（功能标签，历史沿用） | ✅ 进 |
| `version` | v1/v2/v3（仅 reviews） | DestinationRule subset 切分（功能标签） | ✅ 进 |
| `rollouts-pod-template-hash` | 运行时生成 | 灰度 hash 分析（Rollouts 注入） | ✅ 进 |
| `app.kubernetes.io/name` | `<短名>` / bookinfo | 官方推荐：应用名 | ❌ 只贴元数据 |
| `app.kubernetes.io/part-of` | bookinfo | 官方推荐：所属应用 | ❌ |
| `app.kubernetes.io/managed-by` | argocd | 官方推荐：管理工具 | ❌ |
| `app.kubernetes.io/instance` | — | **故意不写**：Argo CD 自 v2.2 起默认占用该键做追踪标签，kustomize 再写会互相覆盖 | — |

实现方式：灰度 overlay 的 `labels` 块里第一条（app）开 includeSelectors，
第二条（推荐标签）不开——只贴 metadata 与 Pod 模板标签，不动 selector；
routing overlay 的 labels 作用于最终全部资源（含 base 的 Gateway/分析模板/EnvoyFilter）。

## 维度路由（hub 模式，单集群形态）

| 维度 | 承载层 | 当前形态 |
|---|---|---|
| 集群 | cluster secret + ApplicationSet list | hub 集群自用，`server` 统一为 https://kubernetes.default.svc |
| 环境 | ApplicationSet list 元素 + `overlays/<env>` 目录 | dev / staging / prod 三环境，staging 与 prod 同集群靠 namespace 区分 |
| 团队 | `apps/<domain>/` 目录 + 一个 AppProject | shop-backend 域（shop 团队） |
| 应用域 | 团队内的命名空间 | bookinfo 系列 |

## 目录定义

- `bootstrap.yaml`：根应用，唯一手动 apply 一次，只同步 `argocd-settings/`
- `argocd-settings/`：Argo CD 自身配置——project 权限边界、appset 生成规则
- `apps/<domain>/base/`：应用域公共 workload 骨架，标准 overlay 引用它
- `apps/<domain>/microservices/<service>/overlays/<env>/`：每个服务、每个环境一个 overlay，ApplicationSet 扫描点
- reviews：不引用团队 base，自带 base（三版本 Deployment 特例）
- bookinfo-routing：base 放 Gateway，VirtualService 按环境差异放 overlay

## 灰度发布约定（Argo Rollouts）

- 路由名 = `<短名>-route`：写在 routing 层 VirtualService 里，Rollout 的 trafficRouting 只引用这一条权重路由
- header/cookie 定向规则：`<短名>-header-canary` / `<短名>-cookie-canary`，静态不归 Rollout 管
- 发布节奏：10 → 25 → 75 → 100，每步 pause 后由 AnalysisRun 自动判断继续或回滚
- 分析模板三件（traffic-check / success-rate / p99-latency）：每环境一份，放 routing base，各服务 Rollout 共用
- KEDA 触发器三件：CPU 80% / 内存 75% / QPS（网格指标），扩缩容目标是 Rollout 而非 Deployment
- Argo CD 豁免（appset ignoreDifferences）：Rollout 的 rollouts-pod-template-hash 标签、VS 权重、Service selector 三处由 Rollout 控制器运行时动态改，Argo CD 不得视为漂移回滚
- reviews 未接入 Rollouts：保留 v1/v2/v3 subset 演示（官方 bookinfo 灰度样例）
- 探针用 tcpSocket：bookinfo 镜像无统一就绪端点；KEDA Utilization 依赖 resources.requests，base 已写死 demo 值

## 韧性配置约定（熔断/限流/重试/超时）

- **熔断**：DestinationRule.trafficPolicy（connectionPool + outlierDetection），取值照官方 Circuit Breaking 演示值
  - reviews：写在自带 base 的 destination-rule.yaml（subset + trafficPolicy，与官方 bookinfo 熔断示例同构）
  - productpage/details/ratings：团队 base 骨架 + 各 overlay patch 注入 DR 名与 FQDN host
- **限流**：本地限流 EnvoyFilter（envoy.filters.http.local_ratelimit），放 routing base 随环境渲染，
  只作用于同命名空间 app=productpage 的 sidecar（每 Pod 4 req/min，官方演示值）
- **重试/超时**：写在 routing 层 VirtualService 四条权重路由上（内部 5s / 入口 10s；
  retries 3 次 × perTry 2s，retryOn gateway-error,connect-failure,refused-stream）
- **共存边界**：Rollouts 只改写 route[].weight，不覆盖同路由的 timeout/retries；
  header/cookie 定向路由不加韧性字段（保持最小配置）
