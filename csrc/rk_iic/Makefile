CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra -Werror
.PHONY: all test clean
all: rk_iic_demo
rk_iic_demo: rk_iic.c rk_iic_demo.c rk_iic.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_iic.c rk_iic_demo.c $(LDFLAGS) -o $@
test_rk_iic: rk_iic.c test_rk_iic.c rk_iic.h
	$(CC) $(CPPFLAGS) $(CFLAGS) rk_iic.c test_rk_iic.c $(LDFLAGS) -Wl,--wrap=open -Wl,--wrap=close -Wl,--wrap=ioctl -o $@
test: test_rk_iic
	./test_rk_iic
clean:
	rm -f rk_iic_demo test_rk_iic
