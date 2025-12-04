# fpga_gng


# 📘 **README – Build & Flash Firmware on Windows Using MSYS2 + MinGW64 + xPack RISC-V Toolchain**

This tutorial explains how to:

1. Install **MSYS2** on Windows
2. Install **MinGW64 build tools**
3. Install **Python (MinGW64)**
4. Install **pyserial**
5. Install **xPack RISC-V Embedded GCC** (required for RISC-V firmware compilation)
6. Configure the Makefile to use the correct Python interpreter
7. Build the firmware
8. Flash the firmware using `make program`

This documentation is intended for the **fpga_gng/picotiny** project.

---

# 🧰 1. Install MSYS2

Download from:

👉 [https://www.msys2.org/](https://www.msys2.org/)

Install using default settings.

After installation, **open MSYS2 MinGW64 terminal**, not MSYS or UCRT64.

---

# 🔄 2. Update MSYS2 Package Database

Run:

```
pacman -Syu
```

Close MSYS2 → reopen MinGW64 terminal → run again:

```
pacman -Syu
```

---

# 🛠️ 3. Install MinGW64 Build Tools

Install development tools:

```
pacman -S --needed base-devel
pacman -S --needed mingw-w64-x86_64-toolchain
```

Verify installation:

```
make --version
gcc --version
```

---

# 🐍 4. Install Python (MinGW64 Version)

Install Python for MinGW64:

```
pacman -S mingw-w64-x86_64-python
```

Check:

```
/mingw64/bin/python --version
```

---

# 🔌 5. Install pyserial (Required for Flashing via COM Port)

```
pacman -S mingw-w64-x86_64-python-pyserial
```

Test:

```
/mingw64/bin/python -c "import serial; print('OK')"
```

If it prints “OK”, pyserial is correctly installed.

---

# 🧩 6. Install xPack RISC-V Embedded GCC (Required Compiler)

Download from:

👉 [https://xpack.github.io/riscv-none-embed-gcc/](https://xpack.github.io/riscv-none-embed-gcc/)

Choose the Windows `.zip` release (not installer).

Example folder path after extraction:

```
C:\xpack-riscv-none-embed-gcc\12.2.0-1\bin
```

Add this folder to PATH inside MSYS2.
Edit your `~/.bashrc`:

```
nano ~/.bashrc
```

Add:

```
export PATH="/c/xpack-riscv-none-embed-gcc/12.2.0-1/bin:$PATH"
```

Reload:

```
source ~/.bashrc
```

Check:

```
riscv-none-embed-gcc --version
```

You should see xPack GCC version info.

---

# 📂 7. Clone the Repository

```
git clone https://github.com/yourname/fpga_gng.git
cd fpga_gng/picotiny
```

---

# 🐍 8. Configure Makefile to Use the Correct Python

MSYS2 has two Python versions:

| Interpreter        | Path                  | pyserial support |
| ------------------ | --------------------- | ---------------- |
| **MSYS Python**    | `/usr/bin/python`     | ❌ does NOT work  |
| **MinGW64 Python** | `/mingw64/bin/python` | ✔ works          |

Edit the Makefile:

Find:

```
PYTHON = python
```

Replace with:

```
PYTHON = /mingw64/bin/python
```

Or (recommended):

```
PYTHON ?= /mingw64/bin/python
```

---

# 🏗️ 9. Build the Firmware

Run:

```
make
```

The compiled bitstream will be generated in:

```
fw/fw-flash/build/fw-flash.v
```

---

# 🔥 10. Flash the Firmware

Connect your RP2040/PicoTiny board via USB (COM port).

Run:

```
make program
```

If needed, override Python manually:

```
make PYTHON=/mingw64/bin/python program
```

Or directly:

```
/mingw64/bin/python sw/pico-programmer.py fw/fw-flash/build/fw-flash.v COM14
```

Change `COM14` to your actual port.
