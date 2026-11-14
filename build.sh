#!/usr/bin/env bash

set -o errexit
set -o nounset

# Supported Minecraft versions and the SHA-1 of their server.jar as published
# in Mojang's version manifest (https://launchermeta.mojang.com/mc/game/version_manifest_v2.json).
# The reachability metadata in "configuration/" matches the version below
# ("26.3"); earlier versions remain available in the Git history.
declare -A SERVER_JAR_SHA1=(
    ["1.18.2"]="c8f83c5655308435b3dcf03c06d9fe8740a77469"
    ["26.3"]="33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"
)
SERVER_JAR_DL_TEMPLATE="https://piston-data.mojang.com/v1/objects/%s/server.jar"
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
VERSION="${MINECRAFT_VERSION:-26.3}"
BUILD_DIR="${SCRIPT_DIR}/build"
JAR_PATH="${BUILD_DIR}/server.jar"
META_INF_PATH="${BUILD_DIR}/META-INF"
CONFIG_DIR="${SCRIPT_DIR}/configuration"
BINARY_NAME="native-minecraft-server"
if [[ -n "${GRAALVM_HOME:-}" ]] && [[ -x "${GRAALVM_HOME}/bin/native-image" ]]; then
    NI_EXEC="${GRAALVM_HOME}/bin/native-image"
elif command -v native-image &> /dev/null; then
    NI_EXEC="$(command -v native-image)"
else
    echo "Unable to find GraalVM Native Image. Please provide a GraalVM installation via \$GRAALVM_HOME or \$PATH. Exiting..."
    exit 1
fi
readonly SERVER_JAR_DL_TEMPLATE SCRIPT_DIR VERSION BUILD_DIR JAR_PATH META_INF_PATH CONFIG_DIR BINARY_NAME NI_EXEC

if [[ ! -v "SERVER_JAR_SHA1[${VERSION}]" ]]; then
    echo "Unsupported Minecraft version '${VERSION}'. Supported versions: ${!SERVER_JAR_SHA1[*]}. Exiting..."
    exit 1
fi

printf -v SERVER_JAR_DL "${SERVER_JAR_DL_TEMPLATE}" "${SERVER_JAR_SHA1[${VERSION}]}"
readonly SERVER_JAR_DL

if [[ ! -d "${BUILD_DIR}" ]]; then
    mkdir -p "${BUILD_DIR}"
fi
pushd "${BUILD_DIR}" > /dev/null

if [[ ! -f "${JAR_PATH}" ]]; then
    echo "Downloading Minecraft ${VERSION}'s server.jar..."
    curl --show-error --fail --location -o "${JAR_PATH}" "${SERVER_JAR_DL}"
fi

if [[ ! -d "${META_INF_PATH}" ]]; then
    echo "Extracting resources from Minecraft's server.jar..."
    unzip -qq "${JAR_PATH}" "META-INF/*" -d "."
fi

# JOML ships package-info.class files compiled with a pre-Java-5 class file
# version, which the Native Image class loader rejects (JOML-CI/JOML#430).
# The annotations they carry are compilation tooling only; drop them.
JOML_JAR=$(awk -F'\t' '$2 ~ /^org\.joml:joml:/ {print $3; exit}' "${META_INF_PATH}/libraries.list" || true)
if [[ -n "${JOML_JAR}" ]]; then
    zip -q -d "${META_INF_PATH}/libraries/${JOML_JAR}" "*package-info.class" 2> /dev/null || true
fi
readonly JOML_JAR

# The server.jar is a bundler jar: the actual Minecraft classes live in
# "META-INF/versions/<version>/server-<version>.jar" and its libraries in
# "META-INF/libraries/". Assemble the classpath from the bundler manifests.
if [[ ! -f "${META_INF_PATH}/libraries.list" || ! -f "${META_INF_PATH}/versions.list" ]]; then
    echo "Unable to determine classpath. Exiting..."
    exit 1
fi
CLASSPATH=""
mapfile -t LIBRARY_PATHS < <(cut -f3 "${META_INF_PATH}/libraries.list")
for path in "${LIBRARY_PATHS[@]}"; do
    CLASSPATH+=":${META_INF_PATH}/libraries/${path}"
done
VERSION_JAR="${META_INF_PATH}/versions/$(cut -f3 "${META_INF_PATH}/versions.list" | head -n 1)"
readonly VERSION_JAR
CLASSPATH="${VERSION_JAR}${CLASSPATH}"
readonly CLASSPATH

if [[ ! -f "${META_INF_PATH}/main-class" ]]; then
    echo "Unable to determine main class. Exiting..."
    exit 1
fi
MAIN_CLASS=$(cat "${META_INF_PATH}/main-class")
readonly MAIN_CLASS

echo "Building native Minecraft server for ${VERSION}..."
"${NI_EXEC}" \
    --gc=G1 \
    -H:ConfigurationFileDirectories="${CONFIG_DIR}/" \
    --enable-url-protocols=https,jar \
    --initialize-at-run-time=io.netty,com.sun.jna \
    --enable-monitoring=heapdump,jfr \
    --initialize-at-build-time=net.minecraft.util.profiling.jfr.event \
    -J-Xmx${NATIVE_IMAGE_XMX:-12g} \
    -o "${BINARY_NAME}" \
    -cp "${CLASSPATH}" \
    "${MAIN_CLASS}"
mv "${BINARY_NAME}" "${SCRIPT_DIR}/${BINARY_NAME}"
# The image loads the bundled JDK native libraries from next to the executable.
for lib in "${BUILD_DIR}"/lib*.so; do
    if [[ -e "${lib}" ]]; then
        cp -f "${lib}" "${SCRIPT_DIR}/"
    fi
done
popd > /dev/null # Exit $BUILD_DIR

if command -v upx &> /dev/null; then
    echo "Compressing the native Minecraft server with upx..."
    upx "${SCRIPT_DIR}/${BINARY_NAME}"
fi

echo ""
echo "Done! The native Minecraft server for ${VERSION} is located at:"
echo "${SCRIPT_DIR}/${BINARY_NAME}"
