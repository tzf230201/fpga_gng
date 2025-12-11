import struct
import sys

MAGIC = 0xB007C0DE

def read_header(path):
    with open(path, "rb") as f:
        header = f.read(12)  # 3 x uint32_t (signature, size, checksum)
        if len(header) < 12:
            print("File too small, no 12-byte header present.")
            return

        signature, size, checksum = struct.unpack("<III", header)
        print(f"Signature : 0x{signature:08X}")
        print(f"Size      : {size} bytes (0x{size:08X})")
        print(f"Checksum  : 0x{checksum:08X}")

        if signature == MAGIC:
            print("Signature matches (0xB007C0DE) → valid NEORV32 header.")
        else:
            print("Signature does NOT match → likely not a valid neorv32_exe.bin.")

        # Optional: check file length vs. size field in the header
        f.seek(0, 2)
        file_size = f.tell()
        payload_size = file_size - 12
        print(f"File size : {file_size} bytes, payload (without header) {payload_size} bytes.")
        if payload_size != size:
            print("WARNING: size in header != actual payload size.")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python check_neorv32_header.py <path/to/neorv32_exe.bin>")
        sys.exit(1)
    read_header(sys.argv[1])