# StormBreaker — Changelog

GKI kernel for the POCO X7 PRO (Redmi Turbo 4).

---

## 0 — Initial

- Synced to AOSP `android15-6.6` at **6.6.142**, KMI `android15-8`, 4k page size.

AOSP's `gki_defconfig` is never edited. Everything this kernel changes lives in its own configuration fragment.

---

## 0.1 — BBR by default

- TCP BBR enabled as the default congestion control.

---

## 0.2 — BORE and ADIOS

- **BORE 5.9.6** CPU scheduler added and enabled. *Masahito Suzuki (firelzrd).*
- **ADIOS 3.3.0** I/O scheduler added and set as the default for the device's disks. *Masahito Suzuki (firelzrd).* Backported from 6.12 to 6.6.
- I/O scheduler re-assert, so the choice survives late boot.

---

## 0.3 — Build system and installer

In-house modular installer replacing AnyKernel3, for both recovery and flashing apps, which verifies what it wrote instead of trusting the exit code. *StormBreaker.*


---

## 0.4 — BBRv3 and fq_codel

- **TCP BBRv3** added and set as the default congestion control.
- **fq_codel** configured and enabled as the default queueing discipline.
