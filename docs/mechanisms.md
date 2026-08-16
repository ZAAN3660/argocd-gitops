# mechanisms.md — 段落原理承接

## 1. destinations 的二元组粒度

AppProject 的 `destinations` 按 `(server, namespace)` 配对放行，不是按集群或 namespace 单个维度。同集群多环境 = 同 server 写多条、每条不同 namespace。不在清单里的组合一律拒绝 syncing。

## 2. list generator 替代 clusters generator

clusters generator 依赖 cluster secret 上唯一的 environment 标签，一个集群无法同时标记为两个环境；list generator 是显式环境清单，每行一个 (环境, 集群, namespace) 三元组，一对多天然成立。当前单集群形态下三个环境同 server，靠 namespace 划分。

## 3. 应用名三元组唯一性

`rd-<服务>-<环境>`：与集群无关，同集群两个环境也能靠环境段区分；同团队内服务目录名唯一即可，不要求跨团队唯一。

## 4. base 标签覆写与 nameReference 的取舍

v1 用 nameReference 联动改名（Service 选择器、Deployment 选择器、Pod 模板标签三处），机制正确但三处声明漏一处就会选择器与标签失配。v2 改为 overlay 用 commonLabels 覆写 app 标签值，选择器与 Pod 标签同步由 kustomize 内置转换器保证，base 不再承载联动逻辑。

## 5. bookinfo 服务短名的硬约束

bookinfo 镜像内硬编码了 details/reviews/ratings 三个 DNS 名，Service 必须用这些短名，否则应用内部调用解析失败。这是 overlay patch 把 Service 名从 `<服务>-service` 改回短名的原因。
