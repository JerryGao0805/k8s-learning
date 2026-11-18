# 多阶段构建：第一阶段编译，第二阶段只放编译好的二进制，最终镜像只有几 MB。

# ---- 阶段 1：编译 ----
# --platform=$BUILDPLATFORM：编译器跑在本机架构上（Mac 是 arm64），不靠 QEMU 模拟，速度快；
# 目标架构由下面的 GOOS/GOARCH 决定（交叉编译）。
FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/golang:1.27-alpine AS build
WORKDIR /src

# 先只复制依赖清单并下载依赖：只要 go.mod/go.sum 不变，这一层就能复用缓存
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY *.go ./

# TARGETOS / TARGETARCH 由 buildx 根据 --platform 自动填入（比如 linux / arm64）
ARG TARGETOS TARGETARCH
ARG VERSION=dev
# CGO_ENABLED=0：纯静态二进制，不依赖 libc，才能放进 distroless/static
# -trimpath：去掉本机路径；-s -w：去掉调试符号，体积更小；-X：把版本号写进 main.version
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/api .

# ---- 阶段 2：运行 ----
# distroless：没有 shell、没有包管理器，只有 CA 证书和时区数据，攻击面很小。
# :nonroot 标签默认以 UID 65532 运行。
FROM gcr.io/distroless/static-debian12:nonroot
ARG VERSION=dev
LABEL org.opencontainers.image.title="notes-api" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=build /out/api /api
EXPOSE 8080
# 用数字 UID：K8s 的 runAsNonRoot 只能校验数字形式的用户
USER 65532:65532
ENTRYPOINT ["/api"]
