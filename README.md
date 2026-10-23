# violetOS

![Zig Version](https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig)
![GitHub License](https://img.shields.io/github/license/YiraSan/violet)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/YiraSan/violet/deploy.yml)

> [!IMPORTANT]
> As defined by [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html), versions in the 0.x.y range are inherently unstable and may introduce breaking changes at any time.

**violet** (pronounced /vjɔlɛt/) is a work-in-progress operating system centered around a fully asynchronous and non-blocking architecture. The project is in an early development phase, focused on maturing these architectural foundations into a scalable, general-purpose system for modern hardware.

## Requirements

This project uses [Zig](https://ziglang.org). We recommend using [zvm](https://github.com/tristanisham/zvm) to install and manage Zig versions seamlessly.

> [!NOTE]
> The required Zig version is `0.17.0`.

To run a virtual instance of violet on your host machine, you will also need [QEMU](https://www.qemu.org) `11.1.2`.

## Build it yourself

Thanks to violet's build system, compiling an operating system has never been easier.

```sh
zig build -Dboard=<BOARD>
```

See [SUPPORT.md](SUPPORT.md) for a complete list of supported boards. Not specifying any board will create a generic image for a given architecture (default to the host machine) :

```sh
zig build -Darch=<ARCH>
```

Supported architectures are `aarch64` and `riscv64`.

### Running it on QEMU

To instantly build and boot the OS in a virtual machine, simply type:

```sh
zig build run -Darch=<ARCH>
```

## Install

violetOS is in early development ; there is no usable software yet.

### Raspberry Pi4

First download latest/raspberry_pi4.img.xz (unavailable) or [nightly/raspberry_pi4.img.xz](https://repo.violetos.org/nightly/violet-raspberry_pi4.img.xz).

If you use [Rufus](https://rufus.ie) or [Balena Etcher](https://etcher.balena.io) it should directly accept the compressed image. If you use another tool, you may need to uncompress it first.

*Since, the SD driver of the RPi4 is slower than the USB driver, we recommend using an USB device instead of the SD card to run violetOS, it avoids a lot of potential issues and make boot and usage significantly more fast and stable.*

### Apple Silicon

To install violetOS on an Apple Silicon device (with M1/M2/M3 SoC), you can use the dedicated install script:

```sh
curl -sL https://repo.violetos.org/alx/install.sh | EXPERT=1 sh
```

## License

Distributed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0). See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for more information.
