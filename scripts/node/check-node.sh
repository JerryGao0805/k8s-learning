#!/usr/bin/env bash
# ------------------------------------------------------------
# 只读检查：这台节点是否已经按第 02 章准备好。每一项打印 ✅ 或 ❌，有任何一项 ❌，退出码就是 1。
# 不会修改任何东西，随时可以跑。
#
# ⚠️ 在【节点】上以 root 运行：
#   在 Mac 上：./scripts/run-on-nodes.sh scripts/node/check-node.sh cp-1 worker-1 worker-2
#   在节点上：sudo bash check-node.sh
# ------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail     # 不用 -e：某一项检查失败也要继续检查下去

# 期望值（和 prepare-node.sh 保持一致）
K8S_PKG_VERSION="1.36.6-1.1"
CRI_TOOLS_VERSION="1.36.0-1.1"
PAUSE_IMAGE="registry.k8s.io/pause:3.10.2"
ECR_CP_SHA256="7be106e9dd1e9a6a3dcfef1756661be69ce3d09ae5970c0c3685c58c94c8d3aa"
ECR_CP_BIN=/usr/local/libexec/kubernetes/image-credential-provider/ecr-credential-provider
ECR_CP_CONFIG=/etc/kubernetes/image-credential-provider/config.yaml

[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限：sudo bash $0" >&2; exit 1; }

fails=0
# check "说明" '要执行的检查命令'：命令成功 = ✅
check() {
  if eval "$2" >/dev/null 2>&1; then
    printf '  ✅ %s\n' "$1"
  else
    printf '  ❌ %s\n' "$1"
    fails=$((fails + 1))
  fi
}

pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

echo "== $(hostname)"

echo "[系统]"
check "cgroup v2"                        '[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ]'
check "没有 swap"                         '[ -z "$(swapon --noheadings)" ]'
check "overlay 模块已加载，并且开机自动加载" 'grep -qw "^overlay" /proc/modules && grep -qx overlay /etc/modules-load.d/k8s.conf'
check "net.ipv4.ip_forward = 1"          '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
check "chrony 已同步（Leap status: Normal）" 'chronyc -n tracking | grep -Eq "^Leap status +: Normal"'
check "chrony 的时间源里有 169.254.169.123"  'chronyc -n sources | grep -q 169.254.169.123'

echo "[containerd]"
check "containerd 正在运行"               'systemctl is-active --quiet containerd'
check "containerd 是 2.x（$(pkg_version containerd)）" '[[ "$(pkg_version containerd)" == 2.* ]]'
check "SystemdCgroup = true"             'containerd config dump | grep -q "SystemdCgroup = true"'
check "sandbox = ${PAUSE_IMAGE}"         "containerd config dump | grep -F 'sandbox = ' | grep -qF '${PAUSE_IMAGE}'"
check "crictl 能连上 containerd"          'crictl info'

echo "[Kubernetes 软件包]"
for p in kubelet kubeadm kubectl; do
  check "${p} = ${K8S_PKG_VERSION}"      "[ \"\$(pkg_version ${p})\" = \"${K8S_PKG_VERSION}\" ]"
done
check "cri-tools = ${CRI_TOOLS_VERSION}" "[ \"\$(pkg_version cri-tools)\" = \"${CRI_TOOLS_VERSION}\" ]"
check "kubelet kubeadm kubectl cri-tools containerd 都已 hold" \
  '[ "$(apt-mark showhold | grep -cxE "kubelet|kubeadm|kubectl|cri-tools|containerd")" = 5 ]'
check "kubelet 已设置开机启动"              'systemctl is-enabled --quiet kubelet'

echo "[ECR 凭证插件]"
check "ecr-credential-provider 的 sha256 正确" "echo '${ECR_CP_SHA256}  ${ECR_CP_BIN}' | sha256sum -c --status"
check "凭证插件配置文件存在"                   "[ -s ${ECR_CP_CONFIG} ]"
check "/etc/default/kubelet 带上了凭证插件参数" 'grep -q -- "--image-credential-provider-config=" /etc/default/kubelet'

echo
if [ "$fails" -eq 0 ]; then
  echo "结果：$(hostname) 全部通过 ✅"
else
  echo "结果：$(hostname) 有 ${fails} 项没通过 ❌"
  exit 1
fi
