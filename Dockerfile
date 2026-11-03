# ============================================================
# 阶段1：Builder（工具链 + 编译 + 测试 + 清理）
# ============================================================
FROM ubuntu:24.04 AS builder

ARG HTTP_PROXY
ARG HTTPS_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY}
ENV http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY}

# 安装所有依赖（一次 apt）
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential cmake autoconf bison patch libncurses-dev \
    git ca-certificates python3 expect curl patchelf \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
RUN curl -fSL "https://github.com/bazelbuild/bazelisk/releases/download/v1.26.0/bazelisk-linux-${TARGETARCH}" \
        -o /usr/local/bin/bazelisk && \
    chmod +x /usr/local/bin/bazelisk && \
    ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel

RUN useradd -m -s /bin/bash -u 1001 cockroach

#COPY go.tar.gz /tmp/go.tar.gz
#RUN tar -C /usr/local -xzf /tmp/go.tar.gz && rm -f /tmp/go.tar.gz
#ENV PATH=/usr/local/go/bin:$PATH

# 2. 安装 Go（根据你的 CockroachDB 版本调整）
ENV GO_VERSION=1.22.5
RUN curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz
ENV PATH=/usr/local/go/bin:/root/go/bin:$PATH

# 安装 bazelisk（本地二进制）
#COPY bazelisk /usr/local/bin/bazelisk
#RUN chmod +x /usr/local/bin/bazelisk && ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel

# 拷贝完整源码（含已初始化的 submodule）
COPY --chown=cockroach:cockroach . /home/cockroach/workspace

# 设置工作目录到源码根（.bazelversion 在这里）
WORKDIR /home/cockroach/workspace

# 创建本地 Bazel 缓存
RUN mkdir -p /home/cockroach/.cache/bazel-repo-cache /home/cockroach/.cache/bazel-disk-cache
RUN chown -R cockroach:cockroach /home/cockroach/.cache

#RUN mkdir -p /home/cockroach/.cache/bazelisk/downloads/cockroachdb/bazel-7.6.0-linux-x86_64/bin
#COPY bazel-7.6.0 /home/cockroach/.cache/bazelisk/downloads/cockroachdb/bazel-7.6.0-linux-x86_64/bin/bazel
#RUN chmod +x /home/cockroach/.cache/bazelisk/downloads/cockroachdb/bazel-7.6.0-linux-x86_64/bin/bazel

ENV BAZELISK_HOME=/home/cockroach/.cache/bazelisk
ENV BAZELISK_OFFLINE=true
RUN chown -R cockroach:cockroach /home/cockroach/.cache /home/cockroach/workspace

USER cockroach
RUN printf 'build --repository_cache=/home/cockroach/.cache/bazel-repo-cache\nbuild --config=crosslinux\nbuild --config=nolintonbuild\ntest --test_tmpdir=/tmp/cockroach\ntest --sandbox_add_mount_pair=/tmp\n' > .bazelrc.user
# 预下载外部依赖（循环重试，确保成功）
RUN for i in 1 2 3 4 5; do \
      echo "=== Fetch attempt $i/5 ===" && \
      bazelisk fetch //pkg/cmd/cockroach:cockroach && break || \
      (echo "Retrying in 60s..." && sleep 60); \
    done

# 预下载 protobuf 相关
RUN for i in 1 2 3; do \
      echo "=== Fetch go_proto attempt $i/3 ===" && \
      bazelisk fetch //pkg/gen:go_proto && break || \
      (echo "Retrying in 60s..." && sleep 60); \
    done

# 确保缓存目录 owner 是 cockroach（关键！）
RUN chown -R cockroach:cockroach /home/cockroach/.cache

# 切换普通用户
ENV USER=cockroach
ENV HOME=/home/cockroach
ENV PATH="/usr/local/go/bin:/usr/local/bin:/home/cockroach/go/bin:${PATH}"
ENV BAZELISK_HOME=/home/cockroach/.cache/bazelisk
ENV BAZELISK_OFFLINE=true
WORKDIR /home/cockroach/workspace
RUN bazelisk version

# Bazel 配置
RUN printf 'build --repository_cache=/home/cockroach/.cache/bazel-repo-cache\nbuild --config=crosslinux\nbuild --config=nolintonbuild\ntest --test_tmpdir=/tmp/cockroach\ntest --sandbox_add_mount_pair=/tmp\n' > .bazelrc.user

RUN printf '#!/usr/bin/expect -f\nspawn ./dev doctor --no-cache --autofix --remote=no\nexpect "Which config you want to use (dev,crosslinux)?"\nsend "crosslinux\\r"\nexpect "Do you want to use the `lintonbuild` configuration?"\nsend "n\\r"\nexpect "Please set a tmpdir"\nsend "/tmp/cockroach\\r"\nexpect "Do you want me to update your .bazelrc.user file for you to configure the loopback cache?"\nsend "y\\r"\nexpect eof\n' > /tmp/doctor.expect \
&& chmod +x /tmp/doctor.expect \
&& /tmp/doctor.expect \
&& cat .bazelrc.user

RUN rm -rf bin

# before build x86 dev, add amd64 libs
#COPY --chown=cockroach:cockroach amd64-lib/ld-linux-x86-64.so.2 /lib64/
#COPY --chown=cockroach:cockroach amd64-lib/lib*.so* /lib/x86_64-linux-gnu/


RUN chmod +x /tmp/doctor.expect 
RUN ./dev doctor

RUN ./dev build -- -c opt --config=crosslinuxarm //pkg/cmd/cockroach:cockroach
RUN ./dev test pkg/sql

RUN ls bin/dev-versions

# 再编译 arm 二进制, 解决 arm 工具包下载到缓存的问题
#RUN ./dev build -- -c opt --config=crosslinuxarm //pkg/cmd/cockroach:cockroach

# 切回 root 清理（避免权限问题）
USER root
RUN rm -rf cockroach artifacts _bazel .git /tmp/doctor.expect && \
rm -rf ~/.cache/bazel ~/.cache/dev-bazel-remote

RUN chown -R cockroach:cockroach /home/cockroach/.cache /home/cockroach/workspace

RUN mkdir -p /home/cockroach/workspace/lib
#COPY --chown=cockroach:cockroach libgeos.so libgeos_c.so /home/cockroach/workspace/lib/


# ============================================================
# 阶段2：最终镜像（只保留工具和清理后的 workspace）
# ============================================================
FROM ubuntu:24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential cmake autoconf bison patch libncurses-dev \
    git ca-certificates python3 patchelf \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash -u 1001 cockroach

COPY --from=builder /usr/local/go /usr/local/go
COPY --from=builder /usr/local/bin/bazelisk /usr/local/bin/bazelisk
RUN ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel

COPY --from=builder --chown=cockroach:cockroach /home/cockroach/.cache/bazelisk /home/cockroach/.cache/bazelisk
COPY --from=builder --chown=cockroach:cockroach /home/cockroach/.cache/bazel-repo-cache /home/cockroach/.cache/bazel-repo-cache
COPY --from=builder --chown=cockroach:cockroach /tmp /tmp

ENV HOME=/home/cockroach
ENV PATH="/usr/local/go/bin:/usr/local/bin:/home/cockroach/go/bin:${PATH}"
ENV BAZELISK_HOME=/home/cockroach/.cache/bazelisk

RUN mkdir -p /home/cockroach/workspace
COPY --from=builder --chown=cockroach:cockroach /home/cockroach/workspace/lib /home/cockroach/workspace

RUN chown -R cockroach:cockroach /home/cockroach/workspace /home/cockroach/.cache
USER cockroach
WORKDIR /home/cockroach/workspace

RUN printf 'build --repository_cache=/home/cockroach/.cache/bazel-repo-cache\nbuild --config=crosslinux\nbuild --config=nolintonbuild\ntest --test_tmpdir=/tmp/cockroach\ntest --sandbox_add_mount_pair=/tmp\n' > .bazelrc.user

CMD ["/bin/bash"]
