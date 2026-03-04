.section .text
.globl _start
_start:
  lui   x22, 0x670d4
  addi  x22, x22, 0x6f4
  lui   x1,  0x12345
  add   x23, x22, x1
  sw    x22, 0(x0)
1:
  j     1b
