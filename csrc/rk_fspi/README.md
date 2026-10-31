# RK FSPI production helper (FSP2)

CPU application integration is now available: see ../../docs/comm_service.md.
Use rk_comm_cli I2C_DEVICE SPI_DEVICE status|get INDEX|set INDEX VALUE|logs
after loading firmware/comm_service into the existing CPU ROM/RAM IPs.
This client performs IIC coordination automatically. The raw tool below remains
for manually coordinated transfers and must not run alongside rk_comm_cli.

50 MHz, SMDT controller, mode 3, directional quad, payload-only single transfer.
See ../../docs/fspi_main_50m.md for the required CPU ownership protocol.

Build: make clean && make. Mock tests: make test.

After CPU ARM_RX(256) and a ready notification:
    ./rk_fspi_demo /dev/spidev4.0 write 256
After CPU COMMIT_TX(256) and a ready notification:
    ./rk_fspi_demo /dev/spidev4.0 read 256

There is NO automatic hardware echo in production. Existing programmed firmware
must be replaced with the newly built communication application to use rk_comm_cli.
Do not use firmware/fspi_link.h or the old fspi_service image with FSP2.
The successful standalone test and its loopback tool remain in
projects/fspi_test_50m and are unchanged.
