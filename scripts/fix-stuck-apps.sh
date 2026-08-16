#!/usr/bin/env bash
# fix-stuck-apps.sh —— 自愈"卡 Deleting"的 Application
#
# 场景：AppProject 被删除后，仍引用它的旧 Application 带着
# resources-finalizer 进入 Deleting，级联删除因无法解析 project 而永久卡死
# （Argo CD 的已知行为，详见 docs/mechanisms.md 第 9 节）。
#
# 原理：先确认该应用的旧追踪标签（app.kubernetes.io/instance=<应用名>）
# 已无任何 live 资源（= 级联其实早已完成），再摘掉 finalizer 让 K8s 收尾。
# 旧标签资源不为 0 时跳过，避免留下孤儿资源。
#
# 用法：
#   bash scripts/fix-stuck-apps.sh             # 实际修复
#   bash scripts/fix-stuck-apps.sh --dry-run   # 只报告，不修改
set -uo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
NS=argocd

# 1. 找出带 deletionTimestamp 的 Application。
#    注意：jsonpath 对空值输出空串（不是 <none>），所以用"行内字段数 > 1"判断。
stuck=$(kubectl get applications.argoproj.io -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
        | awk 'NF > 1 {print $1}')
if [ -z "${stuck:-}" ]; then
  echo "✅ 没有卡在 Deleting 的 Application"
  exit 0
fi

for app in $stuck; do
  # 2. 计数旧追踪标签的 live 资源（-A 全命名空间；多 kind 一次查询，CRD 缺失时静默）
  count=$(kubectl get all,rollout,scaledobject,podmonitor,destinationrule,virtualservice,gateway,envoyfilter,analysistemplate \
          -A -l app.kubernetes.io/instance="$app" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" != "0" ]; then
    echo "⏭  $app：仍残留 $count 个旧标签资源，跳过（级联未完成，先人工排查）"
    continue
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "🔍 $app：级联已完成，可安全摘 finalizer（dry-run 不执行）"
    continue
  fi
  # 3. 摘 finalizer，K8s 立即完成删除
  kubectl patch application "$app" -n "$NS" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  echo "✅ $app：finalizer 已摘除，删除完成"
done
