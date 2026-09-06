# violetOS Platform Support

This document serves as the official hardware specification and status tracker for violetOS.

## 1. Hardware Requirements

violetOS is designed for modern architectures. To run the operating system, your target machine or emulator must meet the following baseline specifications:

### 1.1. Physical Memory (RAM)

* **Minimum Capacity:** 384 MiB of available physical memory.
* **Evaluation Condition:** This capacity threshold is evaluated *strictly after* kernel stage3 initialization.

### 1.2. Memory Management Unit (MMU)

* **Translation Hierarchy:** At least 3-level hardware paging is mandatory (e.g., Sv39 for RISC-V, 4-level/5-level for x86_64, or multi-level AArch64 translation regimes).
* **Granularity:** A baseline 4 KiB page granule is required. The kernel can be compiled to support 16 KiB or 64 KiB translation granules on compliant architectures.

### 1.3. Architecture-Specific Requirements

To guarantee symmetric multiprocessing (SMP) and reliable preemption, strict ISA profiles and standard interrupt controllers are enforced. Custom, vendor-specific, or legacy controllers are explicitly unsupported.

#### x86_64

* **ISA Profile:** Must comply with the **`x86-64-v2`** microarchitecture level or higher (guaranteeing `CMPXCHG16B`, `POPCNT`, and `SSE4.2`).
* **Interrupt Routing:** Must operate in an **APIC / x2APIC** environment. The legacy 8259 PIC is unsupported.

#### aarch64 (ARM64)

* **ISA Profile:** **ARMv8-A** architecture profile or newer.
* **Interrupt Routing:** Must implement the ARM Generic Interrupt Controller architecture (**GICv2, GICv3, or newer**). 
  > *Note: Then SoC-specific proprietary interrupt controllers (such as the legacy Broadcom controllers found on early Raspberry Pi boards like the RPi 3) are unsupported.*

#### riscv64

* **ISA Profile:** The base integer instruction set (`RV64I`) must be supplemented with Multiplication (`M`), Atomics (`A`), and Compressed instructions (`C`).
* **Interrupt Routing:** Must expose a standard **PLIC** (Platform-Level Interrupt Controller) or the newer **AIA** (Advanced Interrupt Architecture), alongside a **CLINT/ACLINT** for inter-processor interrupts (IPI) and timer events.

### 1.4. System Execution & Primitives

Regardless of the target architecture, the underlying platform must expose:
* **Execution Privilege:** Hardware support for privileged system call instructions (`syscall`, `svc`, `ecall`).
* **Timing Facilities:** A reliable hardware timer mechanism capable of generating precise interrupts for the kernel scheduler.

## 2. Platform Support Tiers

**violetOS** categorizes hardware platform support into four progressive tiers.

* **Tier 4** (Minimal): The platform is successfully integrated into the build system. The kernel boots and provides a functional serial console for low-level debugging.

* **Tier 3** (Headless): The core kernel is fully operational. This tier guarantees memory stability (PMM/VMM) and functional Symmetric Multiprocessing (SMP). Essential non-interactive I/O is supported, including fundamental storage drivers (NVMe, SD/eMMC) and basic network connectivity.

* **Tier 2** (Workstation): The platform supports local, interactive usage. The primary hardware buses (PCIe, USB) are successfully enumerated. The I/O ecosystem includes support for Human Interface Devices (HID) and raw display output via a generic Framebuffer.

* **Tier 1** (Full): The platform delivers a fluid, native, and highly optimized user experience. Achieving this tier strictly mandates functional hardware-accelerated graphics (GPU) alongside support for all essential peripherals (e.g., power management, audio, advanced networking). Crucially, hardware components are explicitly exempted from this support requirement if they lack public documentation, lack an open-source reference implementation, or fundamentally require the kernel to load a closed-source runtime blob (e.g., proprietary NPUs or Secure Elements). Consequently, platforms requiring undocumented runtime blobs to initialize their GPU are inherently capped at Tier 2.

## 3. Status Tracker

> [!NOTE]
> ✅ Reached <br>
> 🔨 Work in Progress (WIP) <br>
> 🗓️ Planned <br>

| Platform | Target Tier | Current State | 
| :--- | :---: | :---: |
| **QEMU (aarch64)** | Tier 1 | Tier 4 ✅ - Tier 3 🔨 |
| **QEMU (riscv64)** | Tier 1 | Tier 4 ✅ - Tier 3 🔨 |
| **QEMU (x86_64)** | Tier 1 | Tier 4 ✅ - Tier 3 🔨 |
| **Raspberry Pi 4**<sup>1</sup>| Tier 1 | Tier 4 ✅ - Tier 3 🔨 |
| **Radxa Rock 5B** | Tier 2 | 🗓️ |
| **Orange Pi5 Plus** | Tier 2 | 🗓️ |
| **VisionFive 2**<sup>2</sup> | Tier 2 | 🗓️ |

<sup>1</sup> Includes Raspberry Pi 4B, 400 and Compute Module 4.
<sup>2</sup> StarFive VisionFive 2 board (JH7110 SoC).

***

> [!IMPORTANT]
> The final decision to include, maintain, or drop a platform remains at the sole discretion of the project maintainers.
