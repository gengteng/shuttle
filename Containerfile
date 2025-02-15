#syntax=docker/dockerfile-upstream:1.4


# Base image for builds and cache
ARG RUSTUP_TOOLCHAIN
FROM docker.io/lukemathwalker/cargo-chef:latest-rust-${RUSTUP_TOOLCHAIN}-buster as cargo-chef
WORKDIR /build


# Stores source cache and cargo chef recipe
FROM cargo-chef as planner
WORKDIR /src
COPY . .
# Select only the essential files for copying into next steps
# so that changes to miscellaneous files don't trigger a new cargo-chef cook.
# Beware that .dockerignore filters files before they get here.
RUN find . \( \
    -name "*.rs" -or \
    -name "*.toml" -or \
    -name "Cargo.lock" -or \
    -name "*.sql" -or \
    -name "README.md" -or \
    # Used for local TLS testing, as described in admin/README.md
    -name "*.pem" -or \
    -name "ulid0.so" \
    \) -type f -exec install -D \{\} /build/\{\} \;
WORKDIR /build
RUN cargo chef prepare --recipe-path /recipe.json
# TODO upstream: Reduce the cooking by allowing multiple --bin args to prepare, or like this https://github.com/LukeMathWalker/cargo-chef/issues/181


# Builds crate according to cargo chef recipe.
# This step is skipped if the recipe is unchanged from previous build (no dependencies changed).
FROM cargo-chef AS builder
ARG CARGO_PROFILE
COPY --from=planner /recipe.json /
# https://i.imgflip.com/2/74bvex.jpg
RUN cargo chef cook \
    --all-features \
    $(if [ "$CARGO_PROFILE" = "release" ]; then echo --release; fi) \
    --recipe-path /recipe.json
COPY --from=planner /build .
# Building all at once to share build artifacts in the "cook" layer
RUN cargo build \
    $(if [ "$CARGO_PROFILE" = "release" ]; then echo --release; fi) \
    --bin shuttle-auth \
    --bin shuttle-deployer \
    --bin shuttle-gateway \
    --bin shuttle-logger \
    --bin shuttle-provisioner \
    --bin shuttle-resource-recorder \
    --bin shuttle-next -F next


# Base image for running each "shuttle-..." binary
ARG RUSTUP_TOOLCHAIN
FROM docker.io/library/rust:${RUSTUP_TOOLCHAIN}-buster as shuttle-crate-base
ARG folder
# Some crates need additional libs
COPY ${folder}/*.so /usr/lib/
ENV LD_LIBRARY_PATH=/usr/lib/
ENTRYPOINT ["/usr/local/bin/service"]


# Targets for each crate
# Copying of each binary is non-DRY to allow other steps to be cached

FROM shuttle-crate-base AS shuttle-auth
ARG CARGO_PROFILE
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-auth /usr/local/bin/service
FROM shuttle-auth AS shuttle-auth-dev

FROM shuttle-crate-base AS shuttle-deployer
ARG CARGO_PROFILE
ARG prepare_args
# Fixes some dependencies compiled with incompatible versions of rustc
ARG RUSTUP_TOOLCHAIN
ENV RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN}
# Used as env variable in prepare script
ARG PROD
COPY deployer/prepare.sh /prepare.sh
RUN /prepare.sh "${prepare_args}"
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-deployer /usr/local/bin/service
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-next /usr/local/cargo/bin/
FROM shuttle-deployer AS shuttle-deployer-dev
# Source code needed for compiling with [patch.crates-io]
COPY --from=planner /build /usr/src/shuttle/
FROM shuttle-crate-base AS shuttle-gateway
ARG CARGO_PROFILE
ARG folder
# Some crates need additional libs
COPY ${folder}/*.so /usr/lib/
ENV LD_LIBRARY_PATH=/usr/lib/
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-gateway /usr/local/bin/service
FROM shuttle-gateway AS shuttle-gateway-dev
# For testing certificates locally
COPY --from=planner /build/*.pem /usr/src/shuttle/

FROM shuttle-crate-base AS shuttle-logger
ARG CARGO_PROFILE
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-logger /usr/local/bin/service
FROM shuttle-logger AS shuttle-logger-dev

FROM shuttle-crate-base AS shuttle-provisioner
ARG CARGO_PROFILE
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-provisioner /usr/local/bin/service
FROM shuttle-provisioner AS shuttle-provisioner-dev

FROM shuttle-crate-base AS shuttle-resource-recorder
ARG CARGO_PROFILE
COPY --from=builder /build/target/${CARGO_PROFILE}/shuttle-resource-recorder /usr/local/bin/service
FROM shuttle-resource-recorder AS shuttle-resource-recorder-dev
