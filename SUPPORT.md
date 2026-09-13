# violetOS Platform Support

This document defines the official hardware support lifecycle, architectural baselines, and compatibility matrix for violetOS. 

If a platform does not meet the baseline requirements outlined in this document, attempts to introduce support for it will be systematically rejected.

## 1. The "No Museum" Policy

violetOS explicitly excludes support for legacy standards. The following are permanently unsupported:

* **32-bit Architectures:** No support for x86 (IA-32), ARMv7, or RV32.
* **Legacy Firmware:** No BIOS or CSM (Compatibility Support Module) support. A compliant 64-bit UEFI environment is mandatory for bootstrapping.
* **Obsolete Interrupt Routing:** 
  * No Intel 8259 PIC.
  * No RISC-V PLIC or CLINT/ACLINT.
  * No legacy proprietary SoC interrupt controllers (e.g., legacy Broadcom controllers found on Raspberry Pi 3 or older).
* **Uncooperative Hardware:** Silicon that fundamentally requires undocumented closed-source blobs operating at Ring 0 / EL1 / S-mode to function is unsupported. 

## 2. Architectural Baselines

To run violetOS, the target machine or emulator must meet the following hardware capabilities.

### 2.1. Memory and Translation (MMU)

* **Physical Memory:** A minimum of 384 MiB of available physical RAM. This threshold is evaluated strictly *after* the kernel's stage3 initialization and firmware memory map reclamation.
* **Translation Granule:** Hardware must support a baseline 4 KiB page granule for the initial UEFI handover and early boot. However, the kernel is designed to immediately pivot to optimal translation granules.

### 2.2. CPU Profiles & Interrupts

#### x86_64

* **ISA Profile:** Must strictly comply with the **`x86-64-v3`** microarchitecture level or higher.
* **Interrupt Routing:** Must operate in an **x2APIC** environment.

*Note* : x86_64 is not supported due to the fact that I (YiraSan) cannot simultaneously maintain aarch64, riscv64, and x86_64. I chose to prioritize modern architectures instead. However, PRs are welcome.

#### aarch64 (ARM64)
* **ISA Profile:** **ARMv8.0-A** architecture profile or newer.
* **Interrupt Routing:** Must implement a modern interrupt controller architecture that provides feature parity with (or exceeds) the ARM Generic Interrupt Controller v2 (**GICv2**).

#### riscv64
* **ISA Profile:** Must strictly comply with the **`RVA23S64`** profile. 

### 2.3. System Primitives

Regardless of the architecture, the hardware must provide:
* **Execution Privilege:** Hardware support for standard privileged system calls (`syscall`, `svc`, `ecall`).
* **Timing Facilities:** A reliable hardware timer capable of generating precise interrupts for the kernel scheduler without relying on firmware intervention.

## 3. Platform Support Tiers

violetOS categorizes hardware support into four distinct, capability-based tiers.

* **Tier 4 (Bootstrap):** The platform is successfully integrated into the build system. The kernel can boot, initialize the physical and virtual memory manager, and provide a functional serial console.

* **Tier 3 (Headless):** The core system is fully operational. Symmetric Multiprocessing (SMP), and hardware interrupts/timers are functional. Primary hardware buses (e.g., PCIe, ECAM) are enumerated. Essential non-interactive I/O is supported, such as NVMe storage and basic network connectivity.

* **Tier 2 (Workstation):** The platform supports local, interactive usage. The USB subsystem is operational. The OS can output a graphical interface via a generic Framebuffer (e.g., GOP/EFI FB).

* **Tier 1 (Native):** The platform delivers a fully optimized experience. This tier strictly mandates functional hardware-accelerated graphics (GPU) and advanced power management (CPU frequency scaling, sleep/wake states). 

## 4. Hardware Support Matrix

This matrix provides the status of architecture bring-up and driver implementation for specific targets.

> [!NOTE]
> ✅ Implemented and stable. <br>
> 🔨 Work in progress, unstable, or incomplete. <br>
> ❌ Not yet implemented or currently blocked. <br>
> 🗓️ On the roadmap but no code committed yet. <br>

### 4.1. Virtual environments

| Platform | Arch | Current Tier |
| :--- | :---: | :---: |
| **QEMU `virt`** | `riscv64` | Tier 4 |
| **QEMU `virt`** | `aarch64` | Tier 4 |

### 4.2. Physical Hardware
Support matrix for bare-metal silicon and single-board computers (SBCs).

| Board / SoC | Arch | Target Tier | Boot & Serial | SMP | PCIe | USB | Display | GPU |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Apple Silicon** | `aarch64` | Tier 1 | 🗓️ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Raspberry Pi 4** | `aarch64` | Tier 1 | ✅ | 🔨 | ❌ | ❌ | ❌ | ❌ |
| **Raspberry Pi 5** | `aarch64` | Tier 2 | 🗓️ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Radxa Rock 5B** | `aarch64` | Tier 2 | 🗓️ | ❌ | ❌ | ❌ | ❌ | ❌ |

***

> [!IMPORTANT]
> The inclusion, maintenance, or deprecation of any physical platform is at the sole discretion of the project maintainers.
