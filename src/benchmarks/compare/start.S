.section .text.start, "ax"
.global _start
_start:
    la sp, __stack_top
    call main
    li t0, -40
    sw a0, 0(t0)
1:  j 1b
