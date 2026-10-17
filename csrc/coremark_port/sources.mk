# CoreMark 的软件源文件列表。不要加入其他包含 main() 的测试程序。
COREMARK_SRCS := csrc/coremark_port/start.S
COREMARK_SRCS += third_party/coremark/core_main.c
COREMARK_SRCS += third_party/coremark/core_list_join.c
COREMARK_SRCS += third_party/coremark/core_matrix.c
COREMARK_SRCS += third_party/coremark/core_state.c
COREMARK_SRCS += third_party/coremark/core_util.c
COREMARK_SRCS += csrc/coremark_port/core_portme.c
COREMARK_SRCS += csrc/coremark_port/ee_printf.c
