CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror
.PHONY: all test clean
all: rk_fspi_demo
rk_fspi_demo: rk_fspi.c rk_fspi_demo.c rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_fspi.c rk_fspi_demo.c $(LDFLAGS) -o $@
test_fspi: rk_fspi.c test_fspi.c rk_fspi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_fspi.c test_fspi.c $(LDFLAGS) -Wl,--wrap=open -Wl,--wrap=close -Wl,--wrap=ioctl -o $@
test: test_fspi
	./test_fspi
clean:
	rm -f rk_fspi_demo test_fspi
