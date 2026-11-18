#!/usr/bin/env bash
# ------------------------------------------------------------
# 构建 api 和 web 两个镜像（linux/arm64，节点是 Graviton），推送到 ECR。
#   用法（在仓库根目录执行）：./app/build-push.sh [版本号]
#   版本号默认 0.1.0。改了代码就换一个新版本号（比如 0.1.1），
#   同一个 tag 重复推送，节点上已经缓存的旧镜像不会被重新拉取。
#
# 前提：
#   - Docker Desktop 正在运行（自带 buildx）
#   - aws 命令能用，且 ECR 仓库 k8s-lab/api、k8s-lab/web 已由 Terraform 创建（terraform/ecr.tf）
# 写法兼容 macOS 自带的 bash 3.2。
# ------------------------------------------------------------
set -euo pipefail

VERSION="${1:-0.1.0}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""
# 脚本所在目录（app/），这样不管从哪个目录执行都能找到 app/api 和 app/web
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

for repo in k8s-lab/api k8s-lab/web; do
  if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" >/dev/null 2>&1; then
    echo "[错误] ECR 仓库 ${repo} 不存在（或没有权限查看）。它由 Terraform 创建（terraform/ecr.tf）：" >&2
    echo "  cd terraform && terraform apply" >&2
    exit 1
  fi
done

echo "==> 登录 ECR：${ECR_REGISTRY}"
# 登录凭证 12 小时有效
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

for component in api web; do
  image="${ECR_REGISTRY}/k8s-lab/${component}:${VERSION}"
  echo "==> 构建并推送 ${image}"
  # --provenance=false：不附带构建证明（attestation），ECR 里每个版本就只有一个镜像，看起来更清楚
  docker buildx build \
    --platform linux/arm64 \
    --provenance=false \
    --build-arg VERSION="$VERSION" \
    -t "$image" \
    --push \
    "${APP_DIR}/${component}"
done

echo
echo "==> 完成。先确认 app/deploy/overlays/lab/kustomization.yaml 里的 newTag 是 \"${VERSION}\"，然后部署（在仓库根目录执行）："
echo "  export ECR_REGISTRY=${ECR_REGISTRY}"
echo '  kubectl kustomize app/deploy/overlays/lab | sed "s|ECR_REGISTRY|${ECR_REGISTRY}|g" | kubectl apply -f -'
