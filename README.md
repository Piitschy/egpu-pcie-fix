# NVIDIA eGPU PCIe Link Init

Boot-time PCIe link initialization for an NVIDIA eGPU behind a Thunderbolt/USB4 bridge.

This setup was built for a Fedora system with an RTX 5070 Ti eGPU where the GPU is stable when the PCIe path is configured before the NVIDIA driver binds.

## What It Does

- Waits for the NVIDIA display-class PCI device to appear.
- If the GPU is absent, rescans only the Thunderbolt root port `0000:00:07.3`.
- Keeps the eGPU path awake with `power/control=on` and `d3cold_allowed=0`.
- Disables ASPM on the bridge path and GPU endpoint.
- Sets PCIe Target Link Speed to Gen4.
- Retrains only before NVIDIA is bound.
- Loads NVIDIA modules after the pre-bind link setup.
- Enables NVIDIA persistence mode.
- Does not set a power limit.

## What It Avoids

- No PCIe device `remove`.
- No global PCIe rescan.
- No live retrain after NVIDIA is bound.
- No `nvidia-smi` hooks in udev rules.
- No hard-coded GPU BDF.

## Files

- `bin/egpu-init.sh` -> `/usr/local/bin/egpu-init.sh`
- `systemd/egpu-init.service` -> `/etc/systemd/system/egpu-init.service`
- `udev/80-tb-pcie-tunnel.rules` -> `/etc/udev/rules.d/80-tb-pcie-tunnel.rules`
- `udev/90-nvidia-egpu-power.rules` -> `/etc/udev/rules.d/90-nvidia-egpu-power.rules`

## Install

```sh
sudo ./install.sh
sudo reboot
```

## Required Kernel Arguments

The current working setup uses these kernel arguments:

```text
pcie_port_pm=off pcie_aspm=off thunderbolt.clx=0 pci=noaer iommu=pt rd.driver.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm
```

The NVIDIA blacklist is intentional: it lets `egpu-init.service` configure and retrain the PCIe path before NVIDIA binds.

## Verify

```sh
journalctl -u egpu-init.service -b --no-pager
nvidia-smi --query-gpu=persistence_mode,pstate,power.draw,power.limit,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,memory.used,memory.total --format=csv,noheader
```

Expected service log for Gen4:

```text
post-force link: 16.0 GT/s PCIe
final link: 16.0 GT/s PCIe
post-bind configured link: 16.0 GT/s PCIe
```

Idle may still report current Gen1 while `pcie.link.gen.max` remains Gen4. Under load, the link may train up to Gen4.

## Tune Link Speed

Edit `TARGET_GEN` in `bin/egpu-init.sh`:

```sh
TARGET_GEN="4"
```

Values:

- `1`: Gen1, 2.5 GT/s
- `2`: Gen2, 5.0 GT/s
- `3`: Gen3, 8.0 GT/s
- `4`: Gen4, 16.0 GT/s

After changing it:

```sh
sudo ./install.sh
sudo reboot
```

Do not live-retrain while NVIDIA is bound.
