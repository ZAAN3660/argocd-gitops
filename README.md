# argocd-gitops

## 仓库分层（集群视角）

三层，层名即顶层目录名：

```
infra/    安装层：集群里装了什么平台组件（官方 chart + values，只装不配）
config/   配置层：装好的组件行为被定制成什么样（期望状态由本仓库定义）
         └── Argo CD 自身配置在 config/argocd/（原 settings/），Grafana 面板在 config/grafana/
apps/     业务层：跑在平台之上的是什么业务
```

不属于三层的目录：

```
bootstrap.yaml   根应用：整个体系的唯一起点（手工 apply 一次），不属于三层
```

## 组件版本清单

集群内 GitOps 管理组件的实际版本（升级组件后必须同步更新此表；版本号即"集群里装的什么"的事实锚点）：

| 组件 | 版本 | 出处 |
|---|---|---|
| cert-manager | v1.21.1 | `infra/cert-manager/kustomization.yaml` |
| metrics-server | 3.14.0 | `infra/metrics-server/kustomization.yaml` |
| keda | 2.20.2 | `infra/keda/kustomization.yaml` |
| argo-rollouts | v1.9.1 | `infra/argo-rollouts/install.yaml`（官方静态清单，文件内无版本标记，出处为集群实查镜像） |
| istio（base / istiod / gateway 三个 chart） | 1.30.3 | `infra/istio/{base,istiod,gateway}/kustomization.yaml` |
| opentelemetry-operator | 0.122.0 | `infra/opentelemetry-operator/kustomization.yaml` |
| Argo CD | v3.5.1 | 集群实查（argocd-server 镜像）。**不在 infra/ 里**：无安装层，由 bootstrap.yaml 手工引导安装，本仓库只管理其配置（config/argocd/），版本升级在仓库外维护 |

## 分层判别标准

按**内容来源**定层，一问即答：

- 期望状态由**官方上游定义**（官方 chart / 官方清单），我们只给参数 → **安装层**
- 期望状态由**本仓库定义**（组件的运行时行为定制）→ **配置层**
- 业务应用自身 → **业务层**

分层不管"谁 apply"：看护方式（GitOps / 手工）是执行机制议题，与层归属无关。

## 目录命名规则

命名用**官方全名**（如 `opentelemetry-operator` 而非 `otel-operator`）：缩写对新人不可读。例外仅限镜像路径等官方命名空间（如 `otel/opentelemetry-collector-contrib`）。

**Application 名 = 官方 chart 名**，两条例外：

- 官方名单词离开组件上下文无辨识度（`base`、`gateway`）→ 加组件域前缀：`istio-base`、`istio-gateway`。
- 官方名已自含组件词根（`istiod`）→ 不加前缀，避免 `istio-istiod` 冗余。

目录名 = 官方 chart 名（与 kustomization 的 helmCharts.name 对齐）；App 名 = 目录名，或目录名加域前缀（按上两条例外）。

**Application label 规则**：AppSet 生成的 Application 统一带 `component` label，值 = **组件词根**（istio 的 base / istiod / gateway 三个 App 归一为 `istio`），infra 与 config 两层同词根同值。Argo CD UI 按 `component=<词根>` 过滤，即得该组件的跨层完整视图。注意：此 label 只存在于 Application 对象上（服务于 Argo CD 视图筛选），不传播到其管理的 k8s 资源。


`config/` 目录名**镜像** `infra/` 组件名，同一组件在两层的目录同名：

| 组件 | 安装层 infra/ | 配置层 config/ |
|---|---|---|
| istio | `infra/istio/` | `config/istio/` |
| OpenTelemetry | `infra/opentelemetry-operator/` | `config/opentelemetry-operator/` |
| Argo CD | ——（无安装层，bootstrap.yaml 手工引导） | `config/argocd/`（原 settings/） |
| Grafana | ——（实例在宿主机，不入集群） | `config/grafana/` |

组件在安装层没有目录时（无官方安装物），配置层目录挂在其**宿主组件**名下：otel-agent 无独立安装物（官方只提供 Operator + CRD），运行时行为配置挂在 `config/opentelemetry-operator/`。同一规则适用于 Argo CD 与 Grafana：两者均无本仓库安装层（Argo CD 由 bootstrap.yaml 手工引导，Grafana 实例在宿主机），配置层目录直接以组件官方名建立（宿主即自身）：`config/argocd/`、`config/grafana/`。

## infra 层约束（只装不配）

infra 下每个组件目录**只允许**出现：

1. **官方 chart 引用**：kustomization.yaml 的 `helmCharts`（repo + version + releaseName + namespace）。
2. **values.yaml**：仅限**安装形态参数**——profile、版本对齐、镜像、命名、revision 标签等"以什么形态装进来"的决策。运行时行为参数（典型反例：istio 的 meshConfig）不写在这里。

**两种允许的例外形式**：

| 例外 | 触发条件 | 仓库实例 | 要求 |
|---|---|---|---|
| 官方静态清单落仓 | 组件无官方 helm chart | `infra/argo-rollouts/install.yaml` | 必须是官方原样清单，注明版本 |
| 环境适配资源 | chart values 无法表达、但属于"怎么装"必要部分的资源 | 当前无实例（原 `infra/istio/gateway/svc.yaml` 已删：kind 入口改为不依赖宿主机固定端口，外部访问走 port-forward） | 文件头显式声明例外及原因 |

**归属规定**：运行时配置不属于 infra 层。istio 的 mesh 运行时配置权威在 `config/istio/istio-cm.yaml`（配置层）；infra 里出现任何"装完之后组件怎么行为"的参数都视为越界，应拨回配置层。

## config 层约束

config/ 只放组件的**运行时行为配置**——期望状态由本仓库定义的资源（CR 实例、ConfigMap 覆盖、策略资源）：

1. 目录名镜像 infra/ 组件名（见上表）；组件无安装层目录时挂宿主组件名下。
2. 每个文件头注释声明：镜像对象（集群中的哪个资源）、与安装层的关系、变更后的应用流程。
3. config 层内容不含安装形态参数——"怎么装"的问题归 infra 层，此处只答"怎么行为"。
4. **AppSet 归属**：一层一 AppSet——`config/argocd/appsets/config-components.yaml` 是 config/ 目录清单的镜像（与 infra-components 同构）。config 层 App 名规则特化为 `<组件词根>-config`（如 istio-config、opentelemetry-operator-config），project 统一 default，sync 策略 automated prune selfHeal。当前归属：`config/istio`、`config/opentelemetry-operator` → config AppSet（otel-agent 的集群级补权 RBAC 归安装层 infra/opentelemetry-operator，因 default project 无集群级资源白名单）；`config/argocd` → bootstrap 根应用（自举）；`config/grafana` → 待 kustomization 化后加入。**资源单一归属铁律**：一个资源只能归一个 App 管——`istio-system/istio` ConfigMap 由 infra 侧 `$patch: delete` 让出，归 istio-config 独有。
