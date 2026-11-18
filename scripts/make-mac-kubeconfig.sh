#!/usr/bin/env bash
# ------------------------------------------------------------
# 给 Mac 上的 kubectl 生成一份 kubeconfig（第 05 章）。
#   用法：./scripts/make-mac-kubeconfig.sh
#   结果：~/.kube/k8s-lab.yaml（单独一个文件，不动你原来的 ~/.kube/config）
#
# 做法和 cp-1 上的 admin.conf 不一样：
#   1. 私钥在 Mac 上生成，从不离开 Mac（~/.kube/k8s-lab/mac-admin.key）
#   2. 只把"证书申请"（CSR，公开信息）经 SSM 发到 cp-1，交给集群的 CSR API
#   3. 在 cp-1 上批准，取回集群 CA 签好的证书
# 所以 SSM 的命令历史里只有公开信息，没有任何私钥。
#
# 身份：用户名 mac-admin，组 kubeadm:cluster-admins（kubeadm 已把这个组绑定到 cluster-admin）。
# 证书有效期 1 年，到期后重新跑一次这个脚本即可（私钥会复用）。
# ------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require aws jq openssl kubectl

USER_NAME="mac-admin"
VIA="${VIA:-cp-1}"                     # 在哪台 control plane 上签
DIR="$HOME/.kube/k8s-lab"
KCFG="$HOME/.kube/k8s-lab.yaml"
KEY="$DIR/${USER_NAME}.key"

mkdir -p "$DIR"
chmod 700 "$DIR"

# ---------- 1. 私钥（已有就复用） ----------
if [ ! -f "$KEY" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$KEY"
  ok "生成私钥：$KEY"
fi
chmod 600 "$KEY"

# ---------- 2. 证书申请：CN = 用户名，O = 组 ----------
csr_b64=$(openssl req -new -key "$KEY" -subj "/O=kubeadm:cluster-admins/CN=${USER_NAME}" | base64 | tr -d '\n')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---------- 3. 在 cp-1 上提交 CSR、批准、取回证书和集群 CA ----------
cat > "$tmp/sign-csr.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl delete csr ${USER_NAME} --ignore-not-found >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: ${csr_b64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages: [client auth]
YAML
kubectl certificate approve ${USER_NAME} >/dev/null
for i in \$(seq 1 20); do
  c=\$(kubectl get csr ${USER_NAME} -o jsonpath='{.status.certificate}')
  [ -n "\$c" ] && break
  sleep 1
done
[ -n "\$c" ] || { echo "CSR 批准了但没签发证书" >&2; exit 1; }
echo "CERT=\$c"
echo "CA=\$(base64 -w0 /etc/kubernetes/pki/ca.crt)"
EOF

log "把证书申请发到 ${VIA} 签名"
"$(dirname "$0")/run-on-nodes.sh" "$tmp/sign-csr.sh" "$VIA" > "$tmp/out" 2>&1 \
  || { cat "$tmp/out" >&2; die "在 ${VIA} 上签名失败"; }

sed -n 's/^ *CERT=//p' "$tmp/out" | tr -d '\r' | base64 -d > "$DIR/${USER_NAME}.crt"
sed -n 's/^ *CA=//p'   "$tmp/out" | tr -d '\r' | base64 -d > "$DIR/ca.crt"
[ -s "$DIR/${USER_NAME}.crt" ] && [ -s "$DIR/ca.crt" ] || die "没取回证书，输出在：$tmp/out"
ok "证书：$(openssl x509 -in "$DIR/${USER_NAME}.crt" -noout -subject -enddate | tr '\n' ' ')"

# ---------- 4. 组装 kubeconfig ----------
# server 指向本机 16443（api-tunnel.sh 开的隧道）；
# 但 apiserver 证书里没有 127.0.0.1，所以用 tls-server-name 告诉 kubectl "按 api.k8s.internal 校验证书"。
export KUBECONFIG="$KCFG"
kubectl config set-cluster k8s-lab --server=https://127.0.0.1:16443 --tls-server-name=api.k8s.internal \
  --certificate-authority="$DIR/ca.crt" --embed-certs >/dev/null
kubectl config set-credentials "$USER_NAME" --client-certificate="$DIR/${USER_NAME}.crt" \
  --client-key="$KEY" --embed-certs >/dev/null
kubectl config set-context k8s-lab --cluster=k8s-lab --user="$USER_NAME" >/dev/null
kubectl config use-context k8s-lab >/dev/null
chmod 600 "$KCFG"

ok "完成：$KCFG"
echo "   使用：另开一个终端跑 ./scripts/api-tunnel.sh，然后"
echo "         export KUBECONFIG=$KCFG"
echo "         kubectl get nodes"
