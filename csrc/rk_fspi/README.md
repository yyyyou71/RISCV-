# RK FSPI production helper (FSP2)

50 MHz, SMDT controller, mode 3, directional quad, payload-only single transfer.
See ../../docs/fspi_main_50m.md for the required CPU ownership protocol.

Build: make clean && make. Mock tests: make test.

After CPU ARM_RX(256) and a ready notification:
    ./rk_fspi_demo /dev/spidev4.0 write 256
After CPU COMMIT_TX(256) and a ready notification:
    ./rk_fspi_demo /dev/spidev4.0 read 256

There is NO automatic hardware echo in production. The unchanged CPU firmware
must explicitly adopt the optional fspi_v2.h API before these tests can succeed.
Do not use firmware/fspi_link.h or the old fspi_service image with FSP2.
The successful standalone test and its loopback tool remain in
projects/fspi_test_50m and are unchanged.
