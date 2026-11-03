"""Create a DDR address diagnostic image; preserve weights and descriptors.

Replace only A7-filled words in the writable arena with 0xD0000000 | byte_offset.
Upload with rk_model_cli load; no inference or FPGA rebuild is needed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]


def fnv(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return f'{value:08x}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=ROOT/'csrc/rk_fspi/board_model.bin')
    parser.add_argument('--output', type=Path, default=ROOT/'build/board-ai/board_model_addrprobe.bin')
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve():
        raise ValueError('Diagnostic output must not overwrite the original model')
    original = args.input.read_bytes()
    h = struct.unpack_from('<16I', original, 0x10000)
    if h[:5] != (0x314d4941, 2, 64, 64, 99) or h[7] != len(original):
        raise ValueError('Expected the board model with prefix at 0 and header at 0x10000')
    begin, end = h[12], h[7]
    if begin < 0x10040 or begin >= end or (begin | end) & 15:
        raise ValueError('Invalid writable arena bounds')
    data = bytearray(original)
    changed = 0
    for address in range(begin, end, 4):
        if original[address:address+4] == b'\xa7'*4:
            struct.pack_into('<I', data, address, 0xd0000000 | address)
            changed += 1
    if not changed:
        raise ValueError('No A7 output workspace found')
    assert data[:begin] == original[:begin]  # Includes all descriptors/weights/config.
    for address in range(begin, end, 4):
        if original[address:address+4] != b'\xa7'*4:
            assert data[address:address+4] == original[address:address+4]  # Keep guards.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    report = dict(bytes=len(data), changed_words=changed,
                  original_sha256=hashlib.sha256(original).hexdigest(),
                  sha256=hashlib.sha256(data).hexdigest(), fnv1a32=fnv(data),
                  readonly_prefix_unchanged=True, guard_words_unchanged=True,
                  marker='0xD0000000 | logical byte offset',
                  last_chunk_offset=f'{len(data)-(len(data)%224 or 224):08x}',
                  use='rk_model_cli load only; read cached model/post failure logs with rk_comm_cli listen')
    args.output.with_suffix('.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
    print('Diagnostic image:', args.output)


if __name__ == '__main__':
    main()
