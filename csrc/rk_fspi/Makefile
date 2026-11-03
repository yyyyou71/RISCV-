CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror
.PHONY: all test clean
all: rk_fspi_demo rk_comm_cli rk_model_cli rk_video_app
rk_video_app: image_input.c image_input.h third_party/stb_image.h rk_video_app.c rk_control.c rk_control.h rk_fspi.c rk_fspi.h comm_protocol.h network_status.h video/pcie_dma.c video/pcie_dma.h video/display.c video/display.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -D_DEFAULT_SOURCE rk_video_app.c image_input.c rk_control.c rk_fspi.c video/pcie_dma.c video/display.c $(LDFLAGS) -ldl -o $@
rk_model_cli: rk_model_cli.c rk_fspi.c rk_fspi.h comm_protocol.h network_status.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_model_cli.c rk_fspi.c $(LDFLAGS) -o $@
rk_comm_cli: rk_comm_cli.c rk_fspi.c rk_fspi.h comm_protocol.h network_status.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_comm_cli.c rk_fspi.c $(LDFLAGS) -o $@
rk_fspi_demo: rk_fspi.c rk_fspi_demo.c rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_fspi.c rk_fspi_demo.c $(LDFLAGS) -o $@
test_fspi: rk_fspi.c test_fspi.c rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_fspi.c test_fspi.c $(LDFLAGS) -Wl,--wrap=open -Wl,--wrap=close -Wl,--wrap=ioctl -o $@
test_comm_cli: test_comm_cli.c rk_comm_cli.c comm_protocol.h rk_fspi.h network_status.h
	$(CC) $(CPPFLAGS) $(CFLAGS) test_comm_cli.c $(LDFLAGS) -Wl,--wrap=flock -o $@
test_model_cli: test_model_cli.c rk_model_cli.c comm_protocol.h rk_fspi.h network_status.h
	$(CC) $(CPPFLAGS) $(CFLAGS) test_model_cli.c $(LDFLAGS) -Wl,--wrap=flock -o $@
test_control: test_model_cli.c rk_control.c rk_control.h comm_protocol.h rk_fspi.h network_status.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -DTEST_RK_CONTROL test_model_cli.c $(LDFLAGS) -Wl,--wrap=flock -o $@
test_video_app: test_video_app.c rk_video_app.c rk_control.h video/pcie_dma.h video/display.h network_status.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -D_DEFAULT_SOURCE test_video_app.c $(LDFLAGS) -o $@
test_image_service: test_image_service.c ../../firmware/spi_image.c comm_protocol.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -DSPI_IMAGE_INPUT=1 test_image_service.c $(LDFLAGS) -o $@
test_image_input: test_image_input.c image_input.c image_input.h third_party/stb_image.h
	$(CC) $(CPPFLAGS) $(CFLAGS) test_image_input.c image_input.c $(LDFLAGS) -o $@
test: test_fspi test_comm_cli test_model_cli test_control test_video_app test_image_service test_image_input
	./test_fspi
	./test_comm_cli
	./test_model_cli
	./test_control
	./test_video_app
	./test_image_service
	./test_image_input
clean:
	rm -f rk_fspi_demo rk_comm_cli rk_model_cli rk_video_app test_fspi test_comm_cli test_model_cli test_control test_video_app test_image_service test_image_input
