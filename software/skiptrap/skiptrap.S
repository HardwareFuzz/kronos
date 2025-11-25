	.section .text
	.globl	_start

_start:
	# Set stack pointer
	la      sp, _stack_pointer

	# Install trap handler
	la      t0, trap_handler
	csrw    mtvec, t0

	# Minimal mstatus init (do not touch FS on a core without F)
	csrr    t0, mstatus
	# MIE=0, MPV=0, keep others
	csrw    mstatus, t0

	j       user_code

# ------------------------------------------------------------
user_code:
	# 1) 一些通用寄存器写入
	.globl  L_LI_T0
L_LI_T0:
	li      t0, 0x12345678
	.globl  L_LI_T1
L_LI_T1:
	li      t1, 0xABCDEF01
	.globl  L_LI_T2
L_LI_T2:
	li      t2, 0x11223344
	.globl  L_LI_T3
L_LI_T3:
	li      t3, 0

	# 2) 一些内存写入（对齐访问）
	la      t4, g_data0
	.globl  L_SW_GDATA0
L_SW_GDATA0:
	sw      t0, 0(t4)
	la      t5, g_data1
	.globl  L_SW_GDATA1
L_SW_GDATA1:
	sw      t1, 0(t5)

	# 2.1 复杂些的内存写入到 g_buf（测试 byte/half/word 掩码）
	la      t6, g_buf
	.globl  L_SW_GBUF
L_SW_GBUF:
	sw      t2, 0(t6)        # word: mask=0xF, data=0x11223344
	.globl  L_SH_GBUF_P2
L_SH_GBUF_P2:
	sh      t2, 2(t6)        # half at +2: mask=0xC, data=store_data(rotated)
	.globl  L_SB_GBUF_P1
L_SB_GBUF_P1:
	sb      t2, 1(t6)        # byte at +1: mask=0x2, data=store_data(rotated)

	# 3) 故意触发异常：ECALL（非法或系统调用陷入）
	.globl  L_ECALL
L_ECALL:
	ecall

	# 4) 故意触发异常：对齐错误（向地址+2写 word）
	la      t6, g_data0
	addi    t6, t6, 2
	.globl  L_MISALIGNED_SW
L_MISALIGNED_SW:
	sw      t2, 0(t6)

	# 5) 故意触发异常：EBREAK
	.globl  L_EBREAK
L_EBREAK:
	ebreak

exit:
	# 向 tohost 写入 1 表示通过
	.globl  L_LI_T0_1
L_LI_T0_1:
	li      t0, 1
	la      t1, tohost
	.globl  L_SW_TOHOST
L_SW_TOHOST:
	sw      t0, 0(t1)
1:
	j       1b

	.align  2
trap_handler:
	# 记录并处理异常，自动跳过当前指令（C/非C 均可）
	csrr    t0, mepc             # faulting PC
	csrr    t1, mcause           # trap cause
	csrr    t4, mtval

	slli    t5, t1, 1            # strip interrupt bit
	srli    t1, t5, 1

	li      t2, 2                # 默认长度：压缩指令 2B
	li      t3, 2                # 非法指令 -> mtval 可能给出编码
	beq     t1, t3, use_mtval
	li      t3, 1                # 指令访问异常
	beq     t1, t3, update_mepc
	li      t3, 12               # 指令页异常
	beq     t1, t3, update_mepc

	lhu     t4, 0(t0)            # 其他情况，从指令内存读低 16bit 判定长度
	j       decode_length

use_mtval:
	# 对于非法指令，使用 mtval（此处直接走统一长度判定流程）
	j       decode_length

decode_length:
	andi    t4, t4, 3
	li      t3, 3
	bne     t4, t3, compressed_len
	li      t2, 4                # 标准 32-bit 指令
	j       update_mepc

compressed_len:
	li      t2, 2                # 压缩指令

update_mepc:
	add     t0, t0, t2           # 跳过出错的指令
	csrw    mepc, t0
	csrw    mcause, x0
	csrw    mtval, x0
	mret

	.section .data
	.p2align 2
g_data0:
	.word 0
g_data1:
	.word 0
	.p2align 2
g_buf:
	.space 16

	.section .tohost,"aw",@progbits
	.align  6
	.globl  tohost
	.globl  fromhost
tohost:
	.dword  0
fromhost:
	.dword  0
