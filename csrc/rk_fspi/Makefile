CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror
.PHONY: all test clean
all: rk_fspi_demo rk_comm_cli
rk_comm_cli: rk_comm_cli.c rk_fspi.c rk_fspi.h comm_protocol.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_comm_cli.c rk_fspi.c $(LDFLAGS) -o $@
rk_fspi_demo: rk_fspi.c rk_fspi_demo.c rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_fspi.c rk_fspi_demo.c $(LDFLAGS) -o $@
test_fspi: rk_fspi.c test_fspi.c rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_fspi.c test_fspi.c $(LDFLAGS) -Wl,--wrap=open -Wl,--wrap=close -Wl,--wrap=ioctl -o $@
test_comm_cli: test_comm_cli.c rk_comm_cli.c comm_protocol.h rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) test_comm_cli.c $(LDFLAGS) -Wl,--wrap=flock -o $@
test: test_fspi test_comm_cli
	./test_fspi
	./test_comm_cli
clean:
	rm -f rk_fspi_demo rk_comm_cli test_fspi test_comm_cli
