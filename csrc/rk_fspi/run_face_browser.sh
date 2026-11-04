#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"
make all
exec sudo -E ./rk_video_app "${SPI_DEVICE:-/dev/spidev4.0}" \
    --input ./images --output ai --model ./face_model.bin --interactive "$@"
