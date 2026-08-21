# KEDA 监控接入说明

> 记录 KEDA 指标抓取的完整链路与踩过的坑，便于重建与排查。

## 抓取链路

| 组件 | 指标端口 | 抓取方式 | 备注 |
|---|---|---|---|
| keda-operator | 8080 (`metrics`) | PodMonitor `keda/keda-operator` | Prometheus 指标默认关闭，需手动开启（见下） |
| keda-metrics-apiserver | 8080 (`metrics`) | ServiceMonitor `keda/keda-metrics-apiserver` | 默认即有指标 |

- 9666 是 operator 的**内部 gRPC metricsservice**（`--metrics-service-bind-address=:9666`），不是 HTTP 指标端口，不要抓。
- Prometheus 指标绑定在 `--metrics-bind-address=:8080`。

## 开启 operator 指标（本仓库外的手动变更）

KEDA helm chart 默认 `prometheus.operator.enabled: false`（等价于 `--enable-prometheus-metrics=false`）。
本集群 KEDA 由集群外安装（不在本 gitops 仓库内），因此通过 kubectl 直接补丁：

```bash
# 1) 开启指标
kubectl patch deploy keda-operator -n keda --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args/14","value":"--enable-prometheus-metrics=true"}]'
# 注意：args 下标 14 是当前版本的 --enable-prometheus-metrics 位置，重装后需重新确认

# 2) 给 8080 端口起名（PodMonitor 的 port 字段只能写端口名）
kubectl patch deploy keda-operator -n keda --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/ports/-","value":{"name":"metrics","containerPort":8080,"protocol":"TCP"}}]'

# 3) 应用抓取配置（本仓库 keda/servicemonitor.yaml）
kubectl apply -f keda/servicemonitor.yaml
```

> 若将来 KEDA 改为 helm/gitops 管理，用等价方式替换：`prometheus.operator.enabled=true`（chart 会自动加端口和 ServiceMonitor）。

## 关键指标速查

| 指标 | 含义 |
|---|---|
| `keda_scaler_metrics_value` | 各 ScaledObject 触发器的当前值（本集群=Prometheus QPS） |
| `keda_scaler_active` | scaler 是否活跃（0/1） |
| `keda_scaler_detail_errors_total` | 触发器查询失败计数（连不上 Prometheus 时上升） |
| `keda_scaled_object_errors_total` | ScaledObject reconcile 错误计数 |
| `keda_internal_scale_loop_latency_seconds` | 单次扩缩循环耗时 |
| `keda_scaler_http_request_duration_seconds` | operator → Prometheus 查询延迟直方图 |

## 踩坑记录

1. **9666 抓不到指标**：那是 gRPC 内部服务端口，HTTP 请求必然 EOF；指标在 8080。
2. **PodMonitor `port` 字段**：该 CRD 只接受字符串（端口名），写数字会被拒绝；所以必须先给容器端口起名。
3. **`kube_hpa_*` 指标不存在**：本集群 kube-state-metrics 版本不导出 HPA 指标，副本数面板改用 `kube_replicaset_*{owner_kind="Rollout"}`。
4. **operator 反复重启（17 次/8天）**：日志为 "leader election lost"（exit 1），历史上伴随 Prometheus 查询超时（`context deadline exceeded`）。大盘「operator自身」区可观察其趋势。
