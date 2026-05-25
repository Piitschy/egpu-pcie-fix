# NVIDIA eGPU PCIe Link Init

Boot-time PCIe link initialization for an NVIDIA eGPU behind a Thunderbolt/USB4 bridge.

This setup was built for a Fedora system with an RTX 5070 Ti eGPU where the GPU is stable when the PCIe path is configured before the NVIDIA driver binds.

## What It Does

- Waits for the NVIDIA display-class PCI device to appear.
- If the GPU is absent, rescans only the Thunderbolt root port `0000:00:07.3`.
- Keeps the eGPU path awake with `power/control=on` and `d3cold_allowed=0`.
- Disables ASPM on the bridge path and GPU endpoint.
- Sets PCIe Target Link Speed to Gen3.
- Retrains only before NVIDIA is bound.
- Loads NVIDIA modules after the pre-bind link setup.
- Enables NVIDIA persistence mode.
- Does not set a power limit.

## What It Avoids

- No PCIe device `remove`.
- No global PCIe rescan.
- No live retrain after NVIDIA is bound.
- No runtime `modprobe nvidia_drm` on an already running desktop.
- No `nvidia-smi` hooks in udev rules.
- No hard-coded GPU BDF.

## Files

- `bin/egpu-init.sh` -> `/usr/local/bin/egpu-init.sh`
- `systemd/egpu-init.service` -> `/etc/systemd/system/egpu-init.service`
- `udev/80-tb-pcie-tunnel.rules` -> `/etc/udev/rules.d/80-tb-pcie-tunnel.rules`
- `udev/90-nvidia-egpu-power.rules` -> `/etc/udev/rules.d/90-nvidia-egpu-power.rules`
- `modprobe.d/nvidia-egpu-gate.conf` -> `/etc/modprobe.d/nvidia-egpu-gate.conf`

## Install

```sh
sudo ./install.sh
sudo reboot
```

## Required Kernel Arguments

The current working setup uses these kernel arguments:

```text
pcie_port_pm=off pcie_aspm=off thunderbolt.clx=0 pci=noaer iommu=pt resume=UUID=80eb8856-a7e6-4cca-ab53-5d814c764007 resume_offset=237110272 rd.driver.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm
```

The NVIDIA blacklist is intentional: it prevents early NVIDIA autoload that previously caused boot freezes. `egpu-init.service` configures the PCIe path first and only retrains while NVIDIA is not yet bound.

The modprobe gate is also intentional. It blocks accidental NVIDIA autoload with `install ... /bin/false`, while `egpu-init.sh` uses `modprobe -i` to load the modules explicitly after PCIe setup. This avoids the race where udev binds `nvidia` before `egpu-init.service` can retrain/configure the path.

Do not load `nvidia_drm` manually on the running desktop. It has caused a freeze on this machine. If display-output testing needs `nvidia_drm`, do it only as a controlled boot-time configuration change with a recovery path.

## Verify

```sh
journalctl -u egpu-init.service -b --no-pager
nvidia-smi --query-gpu=persistence_mode,pstate,power.draw,power.limit,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,memory.used,memory.total --format=csv,noheader
```

Expected service log for Gen3:

```text
post-force link: 8.0 GT/s PCIe
final link: 8.0 GT/s PCIe
post-bind configured link: 8.0 GT/s PCIe
```

Idle may still report a lower current link while the configured target remains Gen3. Under load, the link may train up to Gen3.

## Tune Link Speed

Edit `TARGET_GEN` in `bin/egpu-init.sh`:

```sh
TARGET_GEN="3"
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

Do not live-load `nvidia_drm` while the desktop is running.
