#!/usr/bin/env bash

set -o errexit
set -o nounset

# Supported Minecraft versions and the SHA-1 of their server.jar as published
# in Mojang's version manifest (https://launchermeta.mojang.com/mc/game/version_manifest_v2.json).
# The reachability metadata in "configuration/" matches the version below
# ("26.3"); earlier versions remain available in the Git history.
# A case-based lookup keeps this script compatible with the aging /bin/bash 3.2 on macOS.
server_jar_sha1() {
    case "$1" in
        1.18.2) echo "c8f83c5655308435b3dcf03c06d9fe8740a77469" ;;
        26.3)   echo "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" ;;
        *)      return 1 ;;
    esac
}
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
VERSION="${MINECRAFT_VERSION:-26.3}"
BUILD_DIR="${SCRIPT_DIR}/build"
JAR_PATH="${BUILD_DIR}/server.jar"
META_INF_PATH="${BUILD_DIR}/META-INF"
CONFIG_DIR="${SCRIPT_DIR}/configuration"
BINARY_NAME="native-minecraft-server"
GRAALVM_HOME_FILE="${SCRIPT_DIR}/.graalvm-home"
if [[ -n "${GRAALVM_HOME:-}" ]] && [[ -x "${GRAALVM_HOME}/bin/native-image" ]]; then
    NI_EXEC="${GRAALVM_HOME}/bin/native-image"
elif command -v native-image &> /dev/null; then
    NI_EXEC="$(command -v native-image)"
elif [[ -f "${GRAALVM_HOME_FILE}" ]] && [[ -x "$(cat "${GRAALVM_HOME_FILE}")/bin/native-image" ]]; then
    NI_EXEC="$(cat "${GRAALVM_HOME_FILE}")/bin/native-image"
else
    echo "Unable to find GraalVM Native Image."
    echo "Provide it via \$GRAALVM_HOME or \$PATH (it will be remembered in ${GRAALVM_HOME_FILE})."
    exit 1
fi
# Remember the resolved GraalVM home so later runs (CI, fresh shells, PGO
# pipeline stages) do not need \$GRAALVM_HOME set again.
GRAALVM_DETECTED_HOME=$(dirname "$(dirname "${NI_EXEC}")")
if [[ -w "${SCRIPT_DIR}" ]]; then
    printf '%s\n' "${GRAALVM_DETECTED_HOME}" > "${GRAALVM_HOME_FILE}"
fi
readonly SCRIPT_DIR VERSION BUILD_DIR JAR_PATH META_INF_PATH CONFIG_DIR BINARY_NAME NI_EXEC

if ! SERVER_JAR_SHA1=$(server_jar_sha1 "${VERSION}"); then
    echo "Unsupported Minecraft version '${VERSION}'. Exiting..."
    exit 1
fi
readonly SERVER_JAR_SHA1

SERVER_JAR_DL="https://piston-data.mojang.com/v1/objects/${SERVER_JAR_SHA1}/server.jar"
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
# The manifest files may lack a trailing newline; the read guard covers that.
while IFS= read -r path || [[ -n "${path:-}" ]]; do
    CLASSPATH+=":${META_INF_PATH}/libraries/${path}"
done < <(cut -f3 "${META_INF_PATH}/libraries.list")
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
# Profile-Guided Optimizations (Oracle GraalVM only):
#   PGO=instrument ./build.sh   -> build an instrumented binary for a training run
#   PGO=apply ./build.sh        -> build with the profiles collected in build/pgo/
PGO_FLAGS=()
MONITORING="--enable-monitoring=heapdump,jfr"
if [[ "${PGO:-}" == "instrument" ]]; then
    PGO_FLAGS+=("--pgo-instrument")
    # JFR's JVMTI agent conflicts with PGO instrumentation in the builder
    # (SIGSEGV in JfrJvmtiAgent::retransform_classes), so leave it out here.
    MONITORING="--enable-monitoring=heapdump"
elif [[ "${PGO:-}" == "apply" ]] && compgen -G "${BUILD_DIR}/pgo/*.iprof" > /dev/null; then
    # --pgo= expects explicit profile file paths (no directories), comma-separated.
    PROFILE_FILES=("${BUILD_DIR}"/pgo/*.iprof)
    PGO_FLAGS+=("--pgo=$(IFS=,; echo "${PROFILE_FILES[*]}")")
elif [[ "${PGO:-}" == "apply" ]]; then
    echo "PGO=apply requested but no profiles found in ${BUILD_DIR}/pgo/."
    echo "Run 'PGO=instrument ./build.sh' and 'scripts/train-pgo.sh' first."
    echo "Continuing WITHOUT profile-guided optimizations..."
fi
readonly PGO_FLAGS MONITORING

# Bake java.home so AWT/Swing (the server GUI) can locate font configuration
# at runtime; native images do not set it themselves. Overridable at runtime
# with -Djava.home=... .
"${NI_EXEC}" \
    --gc=G1 \
    ${PGO_FLAGS[@]+"${PGO_FLAGS[@]}"} \
    "-Djava.home=${GRAALVM_DETECTED_HOME}" \
    -H:ConfigurationFileDirectories="${CONFIG_DIR}/" \
    --enable-url-protocols=https,jar \
    --initialize-at-run-time=io.netty,com.sun.jna \
    "${MONITORING}" \
    --initialize-at-build-time=net.minecraft.util.profiling.jfr.event \
    -J-Xmx"${NATIVE_IMAGE_XMX:-12g}" \
    -o "${BINARY_NAME}" \
    -cp "${CLASSPATH}" \
    "${MAIN_CLASS}"
if [[ "${PGO:-}" == "instrument" ]]; then
    # Instrumented binaries are throwaway training artifacts: keep them inside
    # build/ (the JDK libraries they need are there anyway) and skip upx.
    mv "${BINARY_NAME}" "${BUILD_DIR}/native-minecraft-server-instrument"
    echo ""
    echo "Done! The instrumented binary for PGO training is located at:"
    echo "${BUILD_DIR}/native-minecraft-server-instrument"
    echo "Train it with: scripts/train-pgo.sh   (then rebuild with PGO=apply)"
    popd > /dev/null # Exit $BUILD_DIR
    exit 0
fi
mv "${BINARY_NAME}" "${SCRIPT_DIR}/${BINARY_NAME}.bin"
# The image loads the bundled JDK native libraries from next to the executable
# (.so on Linux, .dylib on macOS).
for lib in "${BUILD_DIR}"/lib*.so "${BUILD_DIR}"/lib*.dylib; do
    if [[ -e "${lib}" ]]; then
        cp -f "${lib}" "${SCRIPT_DIR}/"
    fi
done
popd > /dev/null # Exit $BUILD_DIR

# The AWT server GUI needs a "fontconfig.properties": the native fontconfig
# integration of the JDK is unavailable inside a native image. Generate a
# minimal one from the system's default fonts.
if command -v fc-match &> /dev/null; then
    SYSTEM_SANS=$(fc-match -f '%{file}' 'sans-serif:style=Regular')
    mkdir -p "${SCRIPT_DIR}/lib"
    cat > "${SCRIPT_DIR}/lib/fontconfig.properties" <<EOF
version=1
sequence.allfonts=alphabetic/default
allfonts.alphabetic=SystemSans
filename.SystemSans=${SYSTEM_SANS}
EOF
else
    echo "fc-match not found: the server GUI will lack font configuration."
fi

# Launcher: native images do not set java.home themselves, but the AWT server
# GUI needs it (any existing directory works — fonts come from system
# fontconfig). Point it at the launcher's own directory.
cat > "${SCRIPT_DIR}/${BINARY_NAME}" <<'LAUNCHER'
#!/usr/bin/env bash
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
exec "${DIR}/native-minecraft-server.bin" -Djava.home="${DIR}" "$@"
LAUNCHER
chmod +x "${SCRIPT_DIR}/${BINARY_NAME}"

if [[ "${UPX:-0}" == "1" ]]; then
    if command -v upx &> /dev/null; then
        echo "Compressing the native Minecraft server with upx..."
        upx "${SCRIPT_DIR}/${BINARY_NAME}.bin"
    else
        echo "UPX=1 requested but upx is not on \$PATH. Skipping compression."
    fi
fi

echo ""
echo "Done! The native Minecraft server for ${VERSION} is located at:"
echo "${SCRIPT_DIR}/${BINARY_NAME}"
