# Native Minecraft Servers with GraalVM Native Image

[![Build Native Minecraft Server](https://github.com/hpi-swa/native-minecraft-server/actions/workflows/main.yml/badge.svg)](https://github.com/hpi-swa/native-minecraft-server/actions/workflows/main.yml)

![Banner](./assets/graalvm_native_image_minecraft_banner.jpg)

The Minecraft server is known to require a lot of CPU and memory resources and can be hard to deploy.
This project makes it possible to compile the Minecraft server into a self-contained native executable using [GraalVM Native Image][ni].
As such, it is supposed to require fewer CPU and memory resources, provide better startup times, and be easier and cheaper to deploy.

A native Minecraft server is less than 120MB in size, and with that significantly smaller than Minecraft's `server.jar` plus a JDK required to run it.
With [upx] compression, the size of the native executable can be reduced even further to less than 40MB, which is smaller than just the `server.jar`.
Initial experiments also suggest competitive run-time performance with a reduced memory footprint.
For best results, build with [GraalVM Enterprise][ee] Native Image, which provides better performance and lower memory usage than the Community Edition, and try out the [G1 GC][g1gc] and [Profile-Guided Optimizations][pgo].
The [Oracle Cloud Free Tier][oci-free] not only provides four Ampere A1 cores and 24 GB of RAM always free, which is plenty for [hosting a Minecraft server][oci-minecraft], but also free access to GraalVM Enterprise.

Check out [this blog post][blog-post] for more information.

*Disclaimer: This project is meant for demonstration purposes only and intended to help the Minecraft community evaluate the use of GraalVM Native Image. Please use at your own risk.*

## Getting Started

1. Download GraalVM [Community][ce] or [Enterprise][ee] for JDK 25 *(a GraalVM distribution with Native Image is required; `native-image` must be on your `$PATH` or reachable via `$GRAALVM_HOME` — the resolved location is remembered in `.graalvm-home` for later runs)*.  
*Optional: pass `UPX=1` to compress the executable with [upx] after building.*
2. Download or check out this repository and run the [`build.sh`](build.sh).
3. Launch the native Minecraft server with `./native-minecraft-server`.  
*The first time you run the server, you will have to follow the regular procedure of accepting Minecraft's EULA.*

## How It Works
This project only contains the `build.sh` script and [reachability metadata][metadata] for building a native Minecraft server.
The `build.sh` script first downloads Minecraft's `server.jar` and extracts jars and other resources from it.
Afterward, it invokes GraalVM Native Image with an appropriate configuration to generate a native version of the Minecraft server.
Finally, and only if [upx] is on the `$PATH`, the script will compress the native executable.
The build produces the executable plus a few bundled JDK native libraries (`lib*.so`) which must stay next to it when moving the server to another machine.

The currently supported Minecraft version is `26.3`.
To build a different version, pass its name via `MINECRAFT_VERSION`, e.g. `MINECRAFT_VERSION=1.18.2 ./build.sh` — older versions require the reachability metadata of the corresponding commit in this repository's Git history (recent GraalVM releases removed some of the options those versions need).

### Profile-Guided Optimizations (optional, Oracle GraalVM only)

PGO trains the optimizer with a real workload; on Minecraft 26.3 it raised peak tick throughput by ~68% (41→69 TPS in a 100-bot `tick sprint 2000`), cut median tick latency by ~35%, and shrank the executable by ~40%.

One command does the whole pipeline (instrumented build → automated training run in a throwaway world with a hot `tick sprint`, console traffic and, if available, bot-client waves → final PGO build):

```bash
scripts/build-with-pgo.sh [path-to-botmark-binary]   # or export BOTMARK_BIN
```

The individual steps, if you want to control them:

1. `PGO=instrument ./build.sh` — build an instrumented binary into `build/`.
2. `scripts/train-pgo.sh [path-to-botmark-binary]` — run the training workload and collect the profile into `build/pgo/` (boot with a fresh world, `tick sprint 2000`, console commands, optional bot waves; profiles accumulate across runs).
3. `PGO=apply ./build.sh` — rebuild with the collected profiles.

Note: `--enable-monitoring=jfr` is dropped automatically for instrumented builds because JFR's JVMTI agent crashes the instrumented image build in Oracle GraalVM 25.

## Limitations and Known Issues

- The configuration currently only supports Minecraft `26.3`.
- Mods are currently not supported.
- There is no build script for Windows yet, but the [WSL] should work.
- The server GUI works on Linux through X11/XWayland (exactly like a regular JVM on Wayland desktops). The build ships a launcher that sets `java.home` (overridable at runtime with `-Djava.home=...`) and generates `lib/fontconfig.properties` from the system fonts, because the JDK's native fontconfig integration is unavailable inside a native image.



## Contributions
Please [report any issues here on GitHub][issues] and open pull requests if you'd like to contribute to the project.

## License
This project is released under the [MIT license](./LICENSE).


[blog-post]: https://medium.com/p/1a3f6a92eb48
[ce]: https://github.com/graalvm/graalvm-ce-builds/releases/latest
[ee]: https://www.oracle.com/downloads/graalvm-downloads.html
[g1gc]: https://www.graalvm.org/22.2/reference-manual/native-image/optimizations-and-performance/MemoryManagement/
[issues]: https://github.com/hpi-swa/native-minecraft-server/issues
[metadata]: https://www.graalvm.org/22.2/reference-manual/native-image/metadata/
[ni]: https://www.graalvm.org/native-image/
[oci-free]: https://www.oracle.com/cloud/free/
[oci-minecraft]: https://blogs.oracle.com/developers/post/how-to-set-up-and-run-a-really-powerful-free-minecraft-server-in-the-cloud
[pgo]: https://www.graalvm.org/22.2/reference-manual/native-image/guides/optimize-native-executable-with-pgo/
[upx]: https://upx.github.io/
[wsl]: https://docs.microsoft.com/en-us/windows/wsl/install
