# 第 05 章 · 加入 worker，在 Mac 上用 kubectl

> 📍 **搭建篇**：只管把东西装好、确认能用。原理留到学习篇（这一章对应 **第 12 章 · 节点与 Pod 的一生** 和 **第 11 章 · Pod 网络**）。

## 🎯 做完是什么样

- `kubectl get nodes`：cp-1、worker-1、worker-2 三个节点都是 **Ready**
- 三个节点上的 Pod 两两能 ping 通（同子网、跨子网都通）
- 在 **Mac** 上直接敲 `kubectl`，不用再登录 cp-1

大约 **30 分钟**。

## 🗺 在整体里的位置

到第 04 章为止，集群只有 cp-1 一个节点。worker-1、worker-2 在第 02 章已经装好了软件，这一章让它们**加入**集群。Calico 是 DaemonSet，会自动在新节点上跑起来，不用再装。最后在 Mac 上配好 kubectl，之后的章节基本都在 Mac 上操作。

## 🧩 新名词

| 词 | 一句话 |
|---|---|
| **bootstrap token** | 一次性的"入场券"。新节点拿着它向 apiserver 证明"我是被允许加入的"，默认 24 小时过期，我们只给 1 小时 |
| **kubeadm join** | 新节点的"入职手续"：用 token 认识集群、申请自己的证书、启动 kubelet |
| **CSR** | 证书签名申请。节点（或人）生成私钥，把"请给我签一张证书"的申请交给集群，批准后集群 CA 签发 |
| **kubeconfig** | kubectl 的配置文件：连哪个地址、怎么校验服务器、用什么身份 |

---

## 🛠 步骤

### 步骤 1：开工

💻 **Mac：**

```bash
cd ~/Desktop/code/K8s-learning
./scripts/lab-up.sh                     # 如果机器是停着的
./scripts/run-on-nodes.sh scripts/node/check-node.sh worker-1 worker-2
```

两台都应该全是 ✅（第 02 章装好的软件还在）。

### 步骤 2：生成 join 命令（cp-1）

```bash
./scripts/ssm.sh cp-1
sudo -i
```

🖥️ **cp-1（root）：**

```bash
kubeadm token create --ttl 1h --print-join-command
```

输出一行（token 和 hash 每次都不同）：

```
kubeadm join api.k8s.internal:6443 --token xqakgn.xxxxxxxxxxxxxxxx --discovery-token-ca-cert-hash sha256:xxxxxxxx…
```

- `--token`：入场券，1 小时后作废。
- `--discovery-token-ca-cert-hash`：集群 CA 的指纹。新节点用它确认"连上的确实是我们的集群"，防止被冒充。

把这一行复制下来，然后退出 cp-1（`exit` 两次）。

### 步骤 3：两台 worker 一起 join（Mac）

用第 02 章的 `run-on-nodes.sh`，把 join 命令同时推给两台 worker：

💻 **Mac：**

```bash
J='kubeadm join api.k8s.internal:6443 --token … --discovery-token-ca-cert-hash sha256:…'   # 粘贴上一步的整行
printf '#!/usr/bin/env bash\nset -euo pipefail\n%s 2>&1 | tail -8\n' "$J" > /tmp/join-worker.sh
./scripts/run-on-nodes.sh /tmp/join-worker.sh worker-1 worker-2
rm /tmp/join-worker.sh                  # 里面有 token
```

两台都应该看到：

```
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.
```

📖 第 12 章：这几秒里发生了什么（TLS bootstrapping：token → 临时身份 → 节点证书）。

### 步骤 4：批准 worker 的 serving 证书，等节点 Ready（cp-1）

和第 03 章步骤 15 一样：kubelet 自己对外提供服务的证书（serving 证书）不会自动批准，要人工确认。

🖥️ **cp-1（root）：**

```bash
kubectl get csr --sort-by=.metadata.creationTimestamp
```

```
NAME        AGE   SIGNERNAME                                    REQUESTOR                   CONDITION
csr-ft62n   20s   kubernetes.io/kube-apiserver-client-kubelet   system:bootstrap:xqakgn     Approved,Issued
csr-hzjtr   20s   kubernetes.io/kube-apiserver-client-kubelet   system:bootstrap:xqakgn     Approved,Issued
csr-zzn7z   19s   kubernetes.io/kubelet-serving                 system:node:ip-10-0-10-21   Pending
csr-45smx   18s   kubernetes.io/kubelet-serving                 system:node:ip-10-0-11-21   Pending
```

- 前两行：worker 用 token 申请的**客户端**证书，集群已经自动批准了。
- 后两行：**serving** 证书，等你批准。先看 REQUESTOR 是不是这两台 worker 自己。

只批准这两台节点自己申请的：

```bash
for n in ip-10-0-10-21 ip-10-0-11-21; do
  kubectl get csr --field-selector spec.signerName=kubernetes.io/kubelet-serving \
    -o jsonpath="{range .items[?(@.spec.username=='system:node:$n')]}{.metadata.name}{'\n'}{end}" \
  | xargs -r kubectl certificate approve
done
```

给 worker 打个角色标签（只是为了 `get nodes` 的 ROLES 一列好看），然后等它们 Ready：

```bash
kubectl label node ip-10-0-10-21 ip-10-0-11-21 node-role.kubernetes.io/worker=
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes
```

```
NAME            STATUS   ROLES           AGE   VERSION
ip-10-0-10-11   Ready    control-plane   25h   v1.36.6
ip-10-0-10-21   Ready    worker          24s   v1.36.6
ip-10-0-11-21   Ready    worker          24s   v1.36.6
```

`kubectl -n calico-system get pods -o wide` 能看到每台 worker 上多了 calico-node、csi-node-driver，还多了一个 calico-typha（节点多了，operator 自动加副本）。

退出 cp-1。

### 步骤 5：在 Mac 上配置 kubectl

💻 **Mac：**

```bash
./scripts/make-mac-kubeconfig.sh
```

```
==> 把证书申请发到 cp-1 签名
 ✔ 证书：subject=O=kubeadm:cluster-admins, CN=mac-admin notAfter=Nov 18 20:23:08 2027 GMT
 ✔ 完成：/Users/<你>/.kube/k8s-lab.yaml
```

这个脚本做了三件事：

1. 在 Mac 上生成私钥（`~/.kube/k8s-lab/mac-admin.key`），**私钥从不离开 Mac**；
2. 把证书申请（CSR）经 SSM 发到 cp-1，用 K8s 的 CSR API 批准，取回集群 CA 签的证书（1 年有效）；
3. 拼成 `~/.kube/k8s-lab.yaml`：地址是 `https://127.0.0.1:16443`，再用 `tls-server-name: api.k8s.internal` 告诉 kubectl 按这个名字校验服务器证书。

它是一个**单独的文件**，不会动你原来的 `~/.kube/config`（里面有 kind 的配置）。

打开隧道（这个窗口保持开着）：

```bash
./scripts/api-tunnel.sh
```

**另开一个终端**：

```bash
export KUBECONFIG=~/.kube/k8s-lab.yaml        # 想每次都生效，可以写进 ~/.zshrc
kubectl auth whoami
kubectl get nodes -o wide
```

```
ATTRIBUTE   VALUE
Username    mac-admin
Groups      [kubeadm:cluster-admins system:authenticated]
```

📖 第 21 章：用同样的 CSR 流程给"只读用户"发证书，再用 RBAC 限制它能做什么。

### 步骤 6：跨节点冒烟测试（Mac）

在三个节点上各起一个 busybox，两两 ping：

```bash
bash <<'EOF'
for n in ip-10-0-10-11 ip-10-0-10-21 ip-10-0-11-21; do
  kubectl run "xn-${n#ip-10-0-}" --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$n\",\"terminationGracePeriodSeconds\":1,\"tolerations\":[{\"operator\":\"Exists\"}]}}" -- sleep 600 >/dev/null
done
kubectl wait --for=condition=Ready pod -l run --timeout=120s >/dev/null
read -r -a IPS <<< "$(kubectl get pods -l run -o jsonpath='{range .items[*]}{.status.podIP} {end}')"
for p in $(kubectl get pods -l run -o jsonpath='{.items[*].metadata.name}'); do
  for ip in "${IPS[@]}"; do
    printf '%-12s -> %-15s : ' "$p" "$ip"
    kubectl exec "$p" -- ping -c1 -W2 "$ip" >/dev/null 2>&1 && echo ok || echo FAIL
  done
done
kubectl delete pod -l run --wait=false
EOF
```

9 行全是 `ok`：

```
xn-10-11     -> 192.168.155.16  : ok
xn-10-11     -> 192.168.229.3   : ok
xn-10-11     -> 192.168.210.3   : ok
...
xn-11-21     -> 192.168.210.3   : ok
```

- `xn-10-11` 和 `xn-10-21` 在同一个子网（10.0.10.0/24），`xn-11-21` 在另一个子网。两种情况都通，说明 VXLAN 隧道工作正常。
- 用 `bash <<'EOF'` 包起来，是因为 Mac 的 zsh 不会把 `$IPS` 拆成多个参数。

---

## ✅ 验收

- [ ] `kubectl get nodes`：3 个节点都是 **Ready**，worker 的 ROLES 是 `worker`
- [ ] `kubectl get csr`：没有 Pending 的 `kubelet-serving`
- [ ] Mac 上 `kubectl auth whoami` 是 `mac-admin`
- [ ] 跨节点 ping：9 行全是 `ok`
- [ ] `kubectl logs` 能看 worker 上的 Pod 日志（说明 worker 的 serving 证书已生效）

---

## 🧹 收工

关掉隧道窗口（Ctrl-C），然后：

```bash
./scripts/lab-down.sh
git add -A
git commit -m "ch05: 加入 worker，Mac 上的 kubectl"
```

**下一章**：第 06 章，扩成 3 个 control plane + 3 个 worker。

---

## 🧯 出问题时

| 现象 | 可能的原因 | 怎么查 |
|---|---|---|
| join 报 `token id ... is invalid` 或 `expired` | token 过期了（我们只给了 1 小时） | 回到步骤 2 重新生成 |
| join 卡在 `[preflight]` 然后超时 | worker 连不上 `api.k8s.internal:6443` | worker 上 `nc -vz api.k8s.internal 6443`；看安全组 `cp-6443-from-worker` |
| join 报 `already exists` / 端口被占用 | 这台 worker 以前 join 过 | worker 上 `kubeadm reset -f`，再 `rm -rf /etc/cni/net.d/*`（只删文件），然后重新 join |
| 节点一直 NotReady | calico-node 没起来 | `kubectl -n calico-system get pods -o wide`，看对应节点上的 calico-node |
| `kubectl logs` 报 `tls: internal error` | serving 证书还没批准 | 回到步骤 4 批准 CSR |
| Mac 上 `kubectl` 报 `connection refused` | 隧道没开或断了 | 重新跑 `./scripts/api-tunnel.sh` |
| Mac 上报 `x509: certificate is valid for ... not 127.0.0.1` | kubeconfig 里少了 `tls-server-name` | 重新跑 `./scripts/make-mac-kubeconfig.sh` |
| `make-mac-kubeconfig.sh` 签名失败 | cp-1 不在线或 SSM 没注册 | `./scripts/status.sh` |

---

## 📖 学习篇会深入

- **第 12 章 · 节点与 Pod 的一生**：TLS bootstrapping 全过程（bootstrap token → `system:bootstrappers` → 自动批准的客户端证书 → 证书轮换）；为什么 serving 证书要人工批准；停掉一台 worker 的 kubelet，看节点 NotReady、Pod 被驱逐
- **第 11 章 · Pod 网络**：跨节点 VXLAN 的路由和 fdb 表、抓 UDP 4789 的包；CrossSubnet 演练（同子网的 cp-1 ↔ worker-1 会断，跨子网的照样通）
- **第 21 章 · 安全加固**：kubeconfig 就是身份；用 CSR + RBAC 给不同的人发不同权限的证书
