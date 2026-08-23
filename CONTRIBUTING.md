# 仓库规约

面向**写这个仓库的人**：改 infra/、config/、apps/ 之前先读这里。每条 = 规则 + 为什么。

## 1. 三层分层，按内容来源判定

```
infra/    安装层：集群里装了什么平台组件（官方 chart + values）
config/   配置层：装好的组件被定制成什么样（期望状态由本仓库定义）
apps/     业务层：跑在平台之上的是什么业务
```

判定只问一个问题：**这个资源的期望状态由谁定义？**

- 由**官方上游**定义（官方 chart / 官方清单），我们只给参数 → **infra/**
- 由**本仓库**定义（组件的运行时行为定制）→ **config/**
- 业务应用自身 → **apps/**

分层不管"谁 apply"：看护方式（GitOps / 手工）是执行机制议题，与层归属无关。

## 2. infra 只装不配，config 只配不装

- infra/ 每个组件目录只允许出现：kustomization.yaml 的 `helmCharts` 引用 + values.yaml。values 里**只放安装形态参数**——profile、版本对齐、镜像、命名、revision 标签等"以什么形态装进来"的决策。
- 装完之后"怎么行为"的参数一律归 config/。典型反例：istio 的 meshConfig——权威必须在 `config/istio/istio-cm.yaml`，infra 里出现它视为越界。

**允许的例外形式**（出现时必须文件头显式声明例外及原因）：

| 例外 | 触发条件 | 要求 |
|---|---|---|
| 官方静态清单落仓 | 组件无官方 helm chart | 官方原样清单，注明版本 |
| 环境适配资源 | chart values 无法表达、但属于"怎么装"必要部分的资源 | 文件头声明例外及原因 |

## 3. 资源单一归属铁律

一个集群资源只能归一个 App 管。冲突时由一方显式让出——例如 `istio-system/istio` ConfigMap 由 infra 侧 `$patch: delete` 让出，归 istio-config 独有。违反此铁律 = 两个 App 对一个资源的期望状态打架，sync 反复漂移。

## 4. 命名规则

**目录名 = 官方全名**（`opentelemetry-operator` 而非 `otel-operator`）：缩写对新人不可读。例外仅限镜像路径等官方命名空间。

**Application 名 = 官方 chart 名**，两条例外：

- 名单词离开组件上下文无辨识度（`base`、`gateway`）→ 加组件域前缀：`istio-base`、`istio-gateway`。
- 官方名已自含组件词根（`istiod`）→ 不加前缀，避免 `istio-istiod` 冗余。

config/ 目录名镜像 infra/ 组件名：同一组件两层目录同名。组件在安装层没有目录时（无官方安装物），配置层目录挂其**宿主组件**名下（如 otel-agent 挂在 `config/opentelemetry-operator/`）。

**Application label**：AppSet 生成的 Application 统一带 `component` label，值 = **组件词根**（istio 的 base/istiod/gateway 三 App 归一为 `istio`），infra 与 config 两层同词根同值。Argo CD UI 按 `component=<词根>` 过滤即得组件跨层完整视图。注意：此 label 只存在于 Application 对象上，不传播到其管理的 k8s 资源。

**根应用**：名字 = `bootstrap-<域名>`（如 `bootstrap-infra`、`bootstrap-bookinfo`），文件固定放在域根、叫 `bootstrap.yaml`；根应用必须挂内置 `default` project（自定义 project 是它同步的产物，不能先给自己套约束）。

## 5. AppSet 归属

Argo CD 自身配置随域存放：每个域根放 `bootstrap.yaml`（根应用，path 指向本域目录）和 `project.yaml`（AppProject），AppSet 放本域 `appsets/` 子目录。

- 一层一 AppSet：`infra/appsets/infra-components.yaml` 是 infra/ 目录清单的镜像；`infra/appsets/config-components.yaml` 是 config/ 的镜像（App 名规则特化为 `<组件词根>-config`）；`apps/bookinfo/appsets/` 下一个服务一个 AppSet。
- 域根必须有 `kustomization.yaml`，且只显式列出本域 project + AppSet：不能列 bootstrap.yaml 自身（根应用自引用 → 自管理告警、删除卡 finalizer），不能列业务子目录（根应用与业务 App 抢资源，违反资源单一归属铁律）。
- 新增业务域：复制 `apps/bookinfo/` 的 self-config 四件套（bootstrap.yaml / project.yaml / kustomization.yaml / appsets/），改名字与路径。

## 6. 版本表是事实锚点

README 的组件版本表记录"集群里实际跑的版本"。**升级组件后必须同步更新**；违反 = 文档与集群事实脱节。
