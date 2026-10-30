# RK FSPI host helper

See ../../docs/fspi_porting.md for board setup and the exact protocol.
Build on RK with make (or a matching cross compiler), then run:

    ./rk_fspi_demo /dev/spidev4.0 256

This overwrites the FPGA shared buffer. Stop CPU buffer use first.
Quad-only, mode 0, <=1 MHz, max 2048 bytes; standard Linux spidev API required.
Vendor smdt driver compatibility has not been tested. No automatic retries.
Run make test on Linux for mocked ioctl framing and error-handling tests.
