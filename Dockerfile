# --- 第一阶段：编译 (Builder) ---
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 1. 克隆源码
WORKDIR /src
RUN apt-get update && apt-get install -y git && git clone --recursive --depth 1 -b v25.12.5.44-stable https://github.com/ClickHouse/ClickHouse.git .

# 1. 安装基础工具
RUN apt-get update && apt-get install -y \
    lsb-release wget software-properties-common gnupg git ninja-build \
    curl python3 libicu-dev libreadline-dev libssl-dev unixodbc-dev \
    zlib1g-dev libzstd-dev libltdl-dev libpcre3-dev ca-certificates

# 2. 安装 Rust 工具链 (ClickHouse 26.x 必需)
# 我们安装 rustup 并指定安装所需的 nightly 版本
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup toolchain install nightly-2025-07-07 && \
    rustup default nightly-2025-07-07

# 3. 安装 LLVM 19 (保持之前逻辑)
RUN wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh 19 && \
    apt-get install -y clang-19 lld-19

# 4. 升级 CMake (保持之前的逻辑)
RUN CMAKE_VERSION=3.28.1 && \
    wget https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-aarch64.sh && \
    chmod +x cmake-${CMAKE_VERSION}-linux-aarch64.sh && \
    ./cmake-${CMAKE_VERSION}-linux-aarch64.sh --skip-license --prefix=/usr/local && \
    rm cmake-${CMAKE_VERSION}-linux-aarch64.sh

# 5. 配置编译参数 (切换到 clang-19)
WORKDIR /src/build
RUN cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang-19 \
    -DCMAKE_CXX_COMPILER=clang++-19 \
    -DARCH_NATIVE=1 \
    -DENABLE_TCMALLOC=0 \
    -DENABLE_THINLTO=0 \
    -DENABLE_EMBEDDED_COMPILER=1 \
    -DCOMPILER_CACHE=disabled \
    -DENABLE_TESTS=OFF && \
    ninja -j 4 clickhouse && \
    # 这一步很关键：编译完立即检查文件位置并移动到统一地点
    ls -lh programs/clickhouse || find . -name "clickhouse"

# --- 第二阶段：运行环境 (Runtime) ---
# 为了保证 GLIBC 兼容性，运行环境也使用 Ubuntu 22.04
FROM ubuntu:22.04

# 安装基础运行库
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash tzdata ca-certificates libicu70 libssl3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 从编译阶段拷贝二进制文件
COPY --from=builder /src/build/programs/clickhouse /usr/bin/
RUN ln -s /usr/bin/clickhouse /usr/bin/clickhouse-server && \
    ln -s /usr/bin/clickhouse /usr/bin/clickhouse-client

# 复制原有的入口脚本和配置逻辑
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 创建用户和必要目录
RUN groupadd -r clickhouse --gid=101 && \
    useradd -r -g clickhouse --uid=101 -d /var/lib/clickhouse clickhouse && \
    mkdir -p /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server && \
    chown -R clickhouse:clickhouse /var/lib/clickhouse /var/log/clickhouse-server

# 开放端口
EXPOSE 8123 9000 9009

ENTRYPOINT ["/entrypoint.sh"]