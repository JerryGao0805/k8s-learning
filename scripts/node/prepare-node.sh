#!/usr/bin/env bash
# ------------------------------------------------------------
# 把一台 Ubuntu 24.04 (arm64) 准备成 Kubernetes 节点。
# 第 02 章你在 cp-1 上手敲的步骤，这里一步不差地自动化（实验部分和预拉镜像除外）。
#
# ⚠️ 这个脚本在【节点】上以 root 身份运行，不要在 Mac 上执行。
#   推荐用法（在 Mac 上）：./scripts/run-on-nodes.sh scripts/node/prepare-node.sh worker-1 worker-2
#   也可以登录节点后执行：sudo bash prepare-node.sh
#
# - 可以重复执行：已经做好的步骤会保持不变。
# - 屏幕上每一步只打一行；apt 等命令的详细输出写在节点的 /var/log/k8s-prepare-node.log。
#   （SSM Run Command 只返回 stdout 的前 24000 个字符，所以这里尽量少打印。）
# - 第一行的 #!/usr/bin/env bash 必须留在第一行：SSM 会把脚本存成文件再执行，
#   靠这一行决定用 bash 而不是 sh 来跑。
# ------------------------------------------------------------

# 保险：万一被 sh（dash）执行了，换成 bash 重新执行自己。这一段只能用 POSIX sh 语法。
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -Eeuo pipefail

# ================= 版本（以后升级只改这里）=================
K8S_MINOR="v1.36"                              # apt 源按小版本划分
K8S_PKG_VERSION="1.36.6-1.1"                   # kubelet / kubeadm / kubectl
CRI_TOOLS_VERSION="1.36.0-1.1"                 # crictl（kubeadm 1.36.1 起不再自动带上它）
PAUSE_IMAGE="registry.k8s.io/pause:3.10.2"     # 必须和 kubeadm v1.36.6 用的 pause 版本一致
ECR_CP_VERSION="v1.36.2"
ECR_CP_SHA256="7be106e9dd1e9a6a3dcfef1756661be69ce3d09ae5970c0c3685c58c94c8d3aa"   # linux/arm64

# ================= 路径 =================
LOG=/var/log/k8s-prepare-node.log
CONTAINERD_CONFIG=/etc/containerd/config.toml
K8S_KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
K8S_SOURCES=/etc/apt/sources.list.d/kubernetes.list
ECR_CP_BIN_DIR=/usr/local/libexec/kubernetes/image-credential-provider
ECR_CP_CONFIG=/etc/kubernetes/image-credential-provider/config.yaml

# ================= 运行环境 =================
[ "$(uname -s)" = "Linux" ] || { echo "这个脚本要在节点上运行，不是在 Mac 上" >&2; exit 1; }
[ "$(id -u)" -eq 0 ]        || { echo "需要 root 权限：sudo bash $0" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = "arm64" ] || { echo "只支持 arm64（ecr-credential-provider 的 sha256 是 arm64 版本的）" >&2; exit 1; }

export HOME=/root                       # SSM Run Command 不设置 HOME，gpg 之类的工具会出问题
export DEBIAN_FRONTEND=noninteractive   # apt 不要弹交互对话框
APT=(apt-get -y -q -o DPkg::Lock::Timeout=300)   # 刚开机时 unattended-upgrades 可能占着 apt 锁，最多等 5 分钟

STEP="初始化"
step() { STEP="$*"; printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; printf '\n===== %s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
run()  { "$@" >>"$LOG" 2>&1; }    # 执行命令，输出只写进日志

on_error() {
  local rc=$?
  {
    echo "❌ 失败：${STEP}（退出码 ${rc}）"
    echo "---- ${LOG} 的最后 50 行 ----"
    tail -n 50 "$LOG"
  } >&2
  exit "$rc"
}
trap on_error ERR

# 把标准输入写到文件 $1（权限 $2，默认 0644）。内容和原来一样就不动它。
# 结果放在全局变量 CHANGED 里：yes = 写了新内容，no = 没变。
write_file() {
  local target=$1 mode=${2:-0644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    CHANGED=no
  else
    install -D -m "$mode" "$tmp" "$target"
    CHANGED=yes
  fi
  rm -f "$tmp"
}

echo "节点：$(hostname)    日志：${LOG}"

# ------------------------------------------------------------
step "[1/7] 前置检查 + 更新软件源"
[ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ] || { echo "需要 cgroup v2" >&2; exit 1; }
if [ -n "$(swapon --noheadings)" ]; then
  # EC2 上的 Ubuntu 默认没有 swap。万一有，关掉并注释掉 /etc/fstab 里的 swap 行。
  swapoff -a
  sed -i -E '/[[:space:]]swap[[:space:]]/ s/^#*/#/' /etc/fstab
fi
run "${APT[@]}" update

# ------------------------------------------------------------
step "[2/7] 内核模块与 sysctl"
write_file /etc/modules-load.d/k8s.conf <<'EOF'
# containerd 用 overlayfs 把镜像的多个层叠成容器的根文件系统
overlay
EOF
modprobe overlay

write_file /etc/sysctl.d/99-kubernetes.conf <<'EOF'
# 允许内核在网卡之间转发 IP 包：Pod 的流量要经过节点转发（kubeadm 预检会检查这一项）
net.ipv4.ip_forward = 1
EOF
run sysctl --system

# ------------------------------------------------------------
step "[3/7] 时间同步（chrony → Amazon Time Sync 169.254.169.123）"
if ! command -v chronyc >/dev/null 2>&1; then
  run "${APT[@]}" install chrony     # 会顺带替换掉 systemd-timesyncd
fi
if ! grep -rqs '169\.254\.169\.123' /etc/chrony/; then
  grep -q '^sourcedir /etc/chrony/sources.d' /etc/chrony/chrony.conf \
    || echo 'sourcedir /etc/chrony/sources.d' >>/etc/chrony/chrony.conf
  write_file /etc/chrony/sources.d/aws.sources <<'EOF'
# Amazon Time Sync Service：每台 EC2 都能通过这个链路本地地址访问，不经过 NAT
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4
EOF
  run systemctl restart chrony
fi
# 等时钟同步（最多约 2 分钟）。没同步上只警告，不中断。
run chronyc waitsync 12 0.1 || echo "  ⚠️ chrony 还没同步完成，稍后用 chronyc tracking 确认"

# ------------------------------------------------------------
step "[4/7] containerd 2.x"
dpkg -s containerd >/dev/null 2>&1 || run "${APT[@]}" install containerd
containerd_ver=$(dpkg-query -W -f='${Version}' containerd)
case "$containerd_ver" in
  2.*) ;;
  *) echo "containerd 版本是 ${containerd_ver}，需要 2.x（Kubernetes 1.36 不支持 containerd 1.x）" >&2; exit 1 ;;
esac

# 先在临时文件里生成配置：默认配置 + 我们的两处修改
tmp=$(mktemp)
containerd config default >"$tmp"
# ① runc 用 systemd 管理 cgroup：先删掉已有的 SystemdCgroup 行，再插到 runc.options 表头的下一行
sed -i '/SystemdCgroup/d' "$tmp"
sed -i '/runtimes\.runc\.options\]/a\            SystemdCgroup = true' "$tmp"
# ② pause（sandbox）镜像和 kubeadm 保持一致
sed -i -E "s#^([[:space:]]*sandbox = ).*#\1'${PAUSE_IMAGE}'#" "$tmp"
grep -q 'SystemdCgroup = true' "$tmp"         || { echo "没能写入 SystemdCgroup = true" >&2; exit 1; }
grep -q "sandbox = '${PAUSE_IMAGE}'" "$tmp"   || { echo "没能写入 sandbox = ${PAUSE_IMAGE}" >&2; exit 1; }

install -d /etc/containerd                      # Ubuntu 的 containerd 包不会创建这个目录
if [ -f "$CONTAINERD_CONFIG" ] && cmp -s "$tmp" "$CONTAINERD_CONFIG"; then
  rm -f "$tmp"
else
  install -m 0644 "$tmp" "$CONTAINERD_CONFIG"
  rm -f "$tmp"
  run systemctl restart containerd               # 只有配置变了才重启
fi
run systemctl enable --now containerd

# ------------------------------------------------------------
step "[5/7] kubelet / kubeadm / kubectl ${K8S_PKG_VERSION} + crictl ${CRI_TOOLS_VERSION}"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" 2>>"$LOG" \
  | gpg --batch --yes --dearmor -o "$K8S_KEYRING" 2>>"$LOG"
write_file "$K8S_SOURCES" <<EOF
deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF
run "${APT[@]}" update
run "${APT[@]}" install --allow-change-held-packages \
  "kubelet=${K8S_PKG_VERSION}" "kubeadm=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}" \
  "cri-tools=${CRI_TOOLS_VERSION}"
# 锁定版本：apt upgrade / unattended-upgrades 都不会再动它们。升级集群要走 kubeadm upgrade（第 22 章）。
run apt-mark hold kubelet kubeadm kubectl cri-tools containerd
# kubelet 会进入"启动 → 找不到配置 → 退出 → 重启"的循环，直到第 03 章 kubeadm 给它写好配置。这是正常的。
run systemctl enable --now kubelet

# ------------------------------------------------------------
step "[6/7] crictl 指向 containerd 的 CRI socket"
run crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
run crictl info

# ------------------------------------------------------------
step "[7/7] ecr-credential-provider ${ECR_CP_VERSION}（第 08 章拉 ECR 私有镜像时用）"
bin="${ECR_CP_BIN_DIR}/ecr-credential-provider"
if ! echo "${ECR_CP_SHA256}  ${bin}" | sha256sum -c --status 2>/dev/null; then
  tmp=$(mktemp)
  run curl -fsSL -o "$tmp" \
    "https://artifacts.k8s.io/binaries/cloud-provider-aws/${ECR_CP_VERSION}/linux/arm64/ecr-credential-provider-linux-arm64"
  echo "${ECR_CP_SHA256}  ${tmp}" | sha256sum -c --status \
    || { rm -f "$tmp"; echo "ecr-credential-provider 的 sha256 校验失败" >&2; exit 1; }
  install -D -m 0755 "$tmp" "$bin"
  rm -f "$tmp"
fi

write_file "$ECR_CP_CONFIG" <<'EOF'
# kubelet 拉镜像时，如果镜像地址匹配 matchImages，就调用 ecr-credential-provider 拿临时密码
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr-ecr.*.on.aws"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF

# kubeadm 给 kubelet 装的 systemd drop-in 会读取这个文件里的 KUBELET_EXTRA_ARGS
write_file /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--image-credential-provider-config=${ECR_CP_CONFIG} --image-credential-provider-bin-dir=${ECR_CP_BIN_DIR}"
EOF

# ------------------------------------------------------------
echo "✅ 完成：$(hostname)  containerd $(dpkg-query -W -f='${Version}' containerd)  kubelet $(dpkg-query -W -f='${Version}' kubelet)"
