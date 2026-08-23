# argocd-gitops

## 仓库分层

```
infra/            安装层：怎么装（被 settings/appsets 的 AppSet 消费，GitOps 看护）
otel/otel-agent   安装层：集群级可观测性组件部署清单（observability 域，同样被 AppSet 消费）
istio/            配置层：运行时配置权威（mesh 行为、tracing 出口），当前手工维护、无 GitOps 看护
apps/             应用层：按环境分发的业务应用
settings/         GitOps 自身配置（AppSet、Project、Argo CD 引导）
grafana/ docs/    面板与操作记录
```

分层判别标准：**"谁在 apply 它"比"它写的是什么"更能分层**。被 Argo CD Application 消费的 = 安装层（因果链：git push → AppSet → Application → 集群，有看护）；手工 apply 的 = 配置层（因果链：人 → kubectl apply，无看护，漂移风险自负）。

## infra 层约束（只装不配）

infra 下每个组件目录**只允许**出现：

1. **官方 chart 引用**：kustomization.yaml 的 `helmCharts`（repo + version + releaseName + namespace）。
2. **values.yaml**：仅限**安装形态参数**——profile、版本对齐、镜像、命名、revision 标签等"以什么形态装进来"的决策。运行时代码行为参数（典型反例：istio 的 meshConfig）不写在这里。

**两种允许的例外形式**：

| 例外 | 触发条件 | 仓库实例 | 要求 |
|---|---|---|---|
| 官方静态清单落仓 | 组件无官方 helm chart | `infra/argo-rollouts/install.yaml` | 必须是官方原样清单，注明版本 |
| 环境适配资源 | chart values 无法表达、但属于"怎么装"必要部分的资源 | `infra/istio/gateway/svc.yaml`（kind 写死 nodePort） | 文件头显式声明例外及原因 |

**归属规定**：运行时配置不属于 infra 层。istio 的 mesh 运行时配置权威在 `istio/istio-cm.yaml`（配置层）；infra 里出现任何"装完之后组件怎么行为"的参数都视为越界，应拨回配置层。
