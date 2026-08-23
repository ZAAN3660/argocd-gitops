# argocd-gitops

一个 kind 单集群 + Argo CD 的 GitOps 实操仓库。集群里装了什么、被配成什么样、跑什么业务，全部由本仓库声明；Argo CD 保证集群永远是仓库的样子。

## 这是什么

**GitOps 一句话**：仓库是唯一事实来源。改了仓库 → Argo CD 检测到差异 → 自动同步到集群。反过来在集群上直接 `kubectl edit` 是无效的——会被自愈（selfHeal）回滚成仓库里定义的状态。

本仓库管理的东西：

- **平台组件**（装了什么）：cert-manager、metrics-server、KEDA、Argo Rollouts、Istio、OpenTelemetry Operator
- **组件配置**（怎么行为）：Istio 网格配置、可观测性配置、Argo CD 自身配置、Grafana 面板
- **演示业务**（跑什么）：bookinfo（Istio 官方示例应用，四服务：productpage / reviews / ratings / details）

## 快速开始

前置：kind 集群和 Argo CD 已安装（Argo CD 的引导在仓库外完成）。

1. 应用根应用（整个体系唯一的起点，只需手工执行一次）：

   ```bash
   kubectl apply -f bootstrap.yaml
   ```

   之后的一切都由它自动展开：bootstrap 部署 `config/argocd/` 里的 project 和 AppSet，AppSet 再为每个组件生成 Application 并自动同步。

2. 打开 Argo CD UI，就能看到所有组件 App 依次同步。UI 里按 `component=<组件名>` 过滤，可得该组件跨层的完整视图。

3. 访问演示应用（宿主机浏览器）：

   ```bash
   kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
   # 浏览器打开 http://localhost:8080/productpage
   ```

## 仓库地图

### infra/ —— 安装层：集群里装了什么

官方 chart 引用 + 安装形态参数（版本、命名、profile 等）。**只装不配**：这里不出现"装完之后组件怎么行为"的参数。

| 组件 | 干什么的 |
|---|---|
| cert-manager | 给集群内组件（webhook 等）自动签发 TLS 证书 |
| metrics-server | 提供 CPU/内存指标：`kubectl top` 与 HPA 的数据来源 |
| keda | 事件驱动自动伸缩：按消息队列等外部事件扩缩副本 |
| argo-rollouts | 渐进式发布：金丝雀 / 蓝绿发布（提供 Rollout CRD） |
| istio | 服务网格三件套：base（CRD）/ istiod（控制面）/ gateway（入口网关） |
| opentelemetry-operator | 管理 OpenTelemetry Collector / Agent 的可观测性底座 |

> Argo CD 自身没有安装层目录：由 bootstrap.yaml 手工引导安装，本仓库只管理其配置。

### config/ —— 配置层：装好的组件被定制成什么样

组件的运行时行为配置（CR 实例、ConfigMap 覆盖等）。**只配不装**。目录名镜像 infra/ 组件名：

| 目录 | 定制什么 |
|---|---|
| config/istio | 网格运行时配置（meshConfig，权威为 ConfigMap） |
| config/opentelemetry-operator | otel collector / agent 的运行时行为 |
| config/argocd | Argo CD 自身：project 权限边界 + AppSet 发散规则 |
| config/grafana | Grafana 面板（实例在宿主机，只存面板定义） |

### apps/ —— 业务层：跑在平台之上的是什么

bookinfo：Istio 官方示例应用（productpage / reviews / ratings / details 四个微服务）。

## 组件版本

集群里实际运行的组件版本（**事实锚点**：升级组件后必须同步更新此表）：

| 组件 | 版本 |
|---|---|
| cert-manager | v1.21.1 |
| metrics-server | 3.14.0 |
| keda | 2.20.2 |
| argo-rollouts | v1.9.1 |
| istio（base / istiod / gateway 三 chart） | 1.30.3 |
| opentelemetry-operator | 0.122.0 |
| Argo CD | v3.5.1 |

> 两个版本来源特殊：argo-rollouts 是官方静态清单落仓（`infra/argo-rollouts/install.yaml`，文件内无版本标记，版本为集群实查镜像）；Argo CD 无安装层，版本为集群实查（argocd-server 镜像），升级在仓库外维护。

## 常用操作

### 接入一个新组件

1. 建 `infra/<组件名>/`：kustomization.yaml（helmCharts 引用）+ values.yaml（只放安装形态参数）。
2. 如需运行时定制，建 `config/<组件名>/`。
3. 在 `config/argocd/appsets/infra-components.yaml`（或 config-components.yaml）的组件清单里加一行。
4. 提交推送 → Argo CD 自动生成 App 并同步。

### 升级组件版本

改 `infra/<组件>/kustomization.yaml` 里的 `version` → 更新上文版本表 → 提交推送。

### 改运行时配置

直接改 `config/<组件>/` 下的文件 → 提交推送 → 自动同步生效。**不要** `kubectl edit`：会被 selfHeal 回滚。

### 排查漂移

Argo CD UI 看 App 状态（Synced / OutOfSync / Degraded）和 Diff；集群实际状态以仓库为准。

## 仓库规约（写仓库的人看）

1. **三层分层，按内容来源判定**：期望状态由官方上游定义（chart/官方清单），我们只给参数 → infra/；由本仓库定义（运行时行为）→ config/；业务应用 → apps/。
2. **infra 只装不配，config 只配不装**：装完之后"怎么行为"的参数一律归 config/（典型反例：istio 的 meshConfig）。
3. **资源单一归属铁律**：一个集群资源只能归一个 App 管；冲突时由一方显式让出（如 `$patch: delete`）。
4. **App 命名**：App 名 = 官方 chart 名；名单词无辨识度的加组件域前缀（istio-base、istio-gateway）；官方名已自含词根的加不加前缀避免冗余（istiod）。
5. **component label**：AppSet 生成的 Application 统一带 `component=<组件词根>` label（istio 三 App 归一为 `istio`），供 UI 跨层过滤。label 只存在于 Application 对象，不传播到其管理的 k8s 资源。
6. **例外可留，必须声明**：infra 层允许两种例外（无官方 chart 时静态清单落仓、chart values 无法表达的环境适配资源），文件头显式声明例外及原因。
