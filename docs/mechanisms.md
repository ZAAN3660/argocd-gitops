# mechanisms.md — 段落原理承接

## 1. destinations 的二元组粒度

AppProject 的 `destinations` 按 `(server, namespace)` 配对放行，不是按集群或 namespace 单个维度。同集群多环境 = 同 server 写多条、每条不同 namespace。不在清单里的组合一律拒绝 syncing。

## 2. list generator 替代 clusters generator

clusters generator 依赖 cluster secret 上唯一的 environment 标签，一个集群无法同时标记为两个环境；list generator 是显式环境清单，每行一个 (环境, 集群, namespace) 三元组，一对多天然成立。当前单集群形态下三个环境同 server，靠 namespace 划分。

## 3. 应用名三元组唯一性

`bookstore-<服务>-<环境>`：与集群无关，同集群两个环境也能靠环境段区分；同团队内服务目录名唯一即可，不要求跨团队唯一。

## 4. base 标签覆写与 nameReference 的取舍

v1 用 nameReference 联动改名（Service 选择器、Deployment 选择器、Pod 模板标签三处），机制正确但三处声明漏一处就会选择器与标签失配。v2 改为 overlay 用 commonLabels 覆写 app 标签值，选择器与 Pod 标签同步由 kustomize 内置转换器保证，base 不再承载联动逻辑。

## 5. bookinfo 服务短名的硬约束

bookinfo 镜像内硬编码了 details/reviews/ratings 三个 DNS 名，Service 必须用这些短名，否则应用内部调用解析失败。这是 overlay patch 把 Service 名从 `<服务>-service` 改回短名的原因。

## 6. Rollouts 与 VS 韧性字段共存（v5）

Rollouts 的 istio 控制器定位到权重路由后只原地改写 `route[].route[idx].weight`（源码 patchVirtualService：`destination["weight"] = patch.weight`），同路由的 match/timeout/retries 等字段原样保留。因此重试/超时可以安全写在 Rollout 托管的权重路由上，发布切流不会抹掉它们；appset 的 ignoreDifferences 仍只需豁免 weight 漂移，无需新增条目。

## 7. EnvoyFilter 的命名空间作用域（v5）

官方 EF 参考：root namespace（istio-system）里的 EnvoyFilter 对全网格生效；其他命名空间里的只作用于同命名空间 workload。routing overlay 把限流 EF 渲染进 dev/staging/prod，恰好实现每环境独立配额；若改全网格统一限流，把 EF 移入 istio-system 即可。注意 GATEWAY context 的 EF 必须放 root namespace，因此本地限流选择 SIDECAR_INBOUND 落地在服务侧，避免跨命名空间选不中 ingressgateway 的问题。

## 8. 熔断 DR 与 host 模式 canary 的边界（v5）

Rollouts 当前是 host 模式（VS 直连 stable/canary 两个 Service，不写 subset，也不创建/管理任何 DestinationRule），因此团队自建 DR 无冲突；但 DR host 只写稳定短名，`<短名>-canary` 在灰度期间不受熔断保护。若日后切 subset 模式（Rollout 增加 destinationRule 字段），Rollouts 会自管一条 DR，必须先撤掉对应服务的自建 DR，避免同一 host 双 DR 互相覆盖（Istio 对冲突字段按 last-write-wins 合并，会造成配置漂移拉锯）。

## 9. 资源删除顺序：为什么排序拦不住、怎么根治（v7）

**根因**：删除链条横跨两个控制器，没有任何全局排序能管住——bootstrap 同步删 AppProject/旧 ApplicationSet；旧 appset 的 finalizer 让 appset 控制器**异步**清退它生成的 Application（级联每条要数分钟）；两条流并行。当 Application 的级联删除需要解析已不存在的 project 时（`DeletionError: error getting app project`），`resources-finalizer` 永远摘不掉 → 卡 Deleting。

**Argo CD 能提供的排序，只约束单次同步内部**：
- `argocd.argoproj.io/sync-wave`：应用按波从低到高，prune 按**逆序**（高波先删）；本仓库 project 已标 `-1`（最先建、最后删）；
- `argocd.argoproj.io/sync-options: PruneLast`：同同步内让该资源最后被 prune；
- `PrunePropagationPolicy=background/orphan`：改 K8s 删除传播方式，不解决 finalizer 级联问题。

以上都管不住 appset 控制器的异步删除，因此**根治靠两阶段提交**：

1. **阶段 1（本次提交）**：新 project + 新 appset + 新目录一步到位，**旧 project 文件原样保留**（旧 appset 已删，其应用清退时旧 project 仍在 → 级联可正常解析，不会卡）；
2. **观察收敛**：`kubectl get app -n argocd | grep <旧前缀>` 为空、旧 appset 消失；
3. **阶段 2（下一次提交）**：删除旧 project 文件（此时已无任何应用引用它）。

**卡死后的自愈**：`bash scripts/fix-stuck-apps.sh [--dry-run]`——先确认旧追踪标签资源为 0，再摘 finalizer。改名不是删除 project 的理由；若名字不再变，这类问题不会再发生。
