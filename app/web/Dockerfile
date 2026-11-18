# 前端镜像：官方 nginx 的 unprivileged 变体（默认以 UID 101 运行、监听 8080），
# 放进我们的 nginx.conf 和 index.html 就行，不需要编译。
FROM public.ecr.aws/nginx/nginx-unprivileged:1.30-alpine

ARG VERSION=dev
LABEL org.opencontainers.image.title="notes-web" \
      org.opencontainers.image.version="${VERSION}"

# 我们的 nginx.conf 是完整配置、不引用 conf.d/，删掉镜像自带的默认站点，免得以为它也在生效
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080
