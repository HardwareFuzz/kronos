// Copyright (c) 2020 Sonal Pinto
// SPDX-License-Identifier: Apache-2.0

/*
Kronos Execution Unit
*/

module kronos_EX
  import kronos_types::*;
#(
  parameter logic [31:0]  BOOT_ADDR = 32'h0,
  parameter logic [31:0]  HARTID = 32'h0,
  parameter EN_COUNTERS = 1,
  parameter EN_COUNTERS64B = 1,
  parameter STBUF_ENABLE = 0,
  parameter STBUF_ALLOW_LOAD_BYPASS = 0,
  parameter STBUF_CONFLICT_STALL = 1,
  parameter FENCE_DRAIN_STBUF = 1
)(
  input  logic        clk,
  input  logic        rstz,
  // ID/EX
  input  pipeIDEX_t   decode,
  input  logic        decode_vld,
  output logic        decode_rdy,
  // REG Write
  output logic [31:0] regwr_data,
  output logic [4:0]  regwr_sel,
  output logic        regwr_en,
  // Branch
  output logic [31:0] branch_target,
  output logic        branch,
  // Data interface
  output logic [31:0] data_addr,
  input  logic [31:0] data_rd_data,
  output logic [31:0] data_wr_data,
  output logic [3:0]  data_mask,
  output logic        data_wr_en,
  output logic        data_req,
  input  logic        data_ack,
  // Interrupt sources
  input  logic        software_interrupt,
  input  logic        timer_interrupt,
  input  logic        external_interrupt
);

logic [31:0] result;
logic [4:0] rd;

logic instr_vld;
logic instr_jump;
logic basic_rdy;
logic fence_hold;

logic lsu_vld, lsu_rdy;
logic lsu_stbuf_empty;
logic [31:0] load_data;
logic regwr_lsu;

logic csr_vld,csr_rdy;
logic [31:0] csr_data;
logic regwr_csr;
logic instret;
logic core_interrupt /* verilator public_flat */;
logic [3:0] core_interrupt_cause;

logic exception /* verilator public_flat */;

logic activate_trap, return_trap;
logic [31:0] trap_cause /* verilator public_flat */, trap_handle, trap_value;
logic trap_jump /* verilator public_flat */;

  logic instr_accept;
  logic [31:0] log_reg_pc /* verilator public_flat */;
  logic        log_reg_pc_vld /* verilator public_flat */;
  logic [31:0] log_reg_ir /* verilator public_flat */;
  logic [31:0] log_reg_op1 /* verilator public_flat */;
  logic [31:0] log_reg_op2 /* verilator public_flat */;
  logic [31:0] log_mem_pc /* verilator public_flat */;
  logic        log_mem_pc_vld /* verilator public_flat */;
  logic [31:0] log_mem_addr /* verilator public_flat */;
  logic [31:0] log_mem_data /* verilator public_flat */;
  logic [3:0]  log_mem_mask /* verilator public_flat */;
  logic [31:0] log_trap_pc /* verilator public_flat */;
  logic        log_trap_pc_vld /* verilator public_flat */;

enum logic [2:0] {
  STEADY,
  LSU,
  CSR,
  TRAP,
  RETURN,
  WFINTR,
  JUMP
} state, next_state;


// ============================================================
// IR Segments
assign rd  = decode.ir[11:7];

// ============================================================
// EX Sequencer
always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) state <= STEADY;
  else state <= next_state;
end

always_comb begin
  next_state = state;
  /* verilator lint_off CASEINCOMPLETE */
  unique case (state)
    STEADY: if (decode_vld) begin
      if (core_interrupt) next_state = TRAP;
      else if (exception) next_state = TRAP;
      else if (decode.system) begin
        unique case (decode.sysop)
          ECALL,
          EBREAK: next_state = TRAP;
          MRET  : next_state = RETURN;
          WFI   : next_state = WFINTR;
        endcase
      end
      else if (decode.load || decode.store) begin
        // If the LSU can complete immediately (e.g. store buffered),
        // stay in STEADY to avoid getting stuck in LSU state.
        if (lsu_rdy) next_state = STEADY;
        else next_state = LSU;
      end
      else if (decode.csr) next_state = CSR;
    end

    LSU: if (lsu_rdy) next_state = STEADY;

    CSR: if (csr_rdy) next_state = STEADY;

    WFINTR: if (core_interrupt) next_state = TRAP;

    TRAP: next_state = JUMP;

    RETURN: next_state = JUMP;

    JUMP: if (trap_jump) next_state = STEADY;

  endcase // state
  /* verilator lint_on CASEINCOMPLETE */
end

// Decoded instruction valid
assign instr_vld = decode_vld && state == STEADY && ~exception && ~core_interrupt;
assign instr_accept = decode_vld && decode_rdy;

// Basic instructions
assign fence_hold = STBUF_ENABLE && FENCE_DRAIN_STBUF && decode.fence && instr_vld && !lsu_stbuf_empty;
assign basic_rdy = instr_vld && decode.basic && !fence_hold;

// Next instructions
assign decode_rdy = |{basic_rdy, lsu_rdy, csr_rdy};

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_reg_pc <= '0;
    log_reg_pc_vld <= 1'b0;
    log_reg_ir <= '0;
    log_reg_op1 <= '0;
    log_reg_op2 <= '0;
  end
  else begin
    // Align the logged PC with the architectural writeback event.
    // Note: regwr_en is registered, so using it directly would delay the log by 1 cycle.
    logic regwr_pulse;
    regwr_pulse = (instr_vld && decode.regwr_alu)
              || (lsu_rdy && regwr_lsu)
              || (csr_rdy && regwr_csr);

    log_reg_pc_vld <= regwr_pulse;
    if (regwr_pulse) begin
      log_reg_pc <= decode.pc;
      log_reg_ir <= decode.ir;
      log_reg_op1 <= decode.op1;
      log_reg_op2 <= decode.op2;
    end
  end
end

// Log architectural store events (PC/address/data/mask) when the store instruction retires.
// This is intentionally decoupled from the memory interface handshake so store-buffer variants
// still attribute writes to the correct instruction PC.
always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_mem_pc <= '0;
    log_mem_pc_vld <= 1'b0;
    log_mem_addr <= '0;
    log_mem_data <= '0;
    log_mem_mask <= '0;
  end
  else begin
    log_mem_pc_vld <= instr_accept && decode.store;
    if (instr_accept && decode.store) begin
      log_mem_pc <= decode.pc;
      log_mem_addr <= {decode.addr[31:2], 2'b0};
      log_mem_data <= decode.op2;
      log_mem_mask <= decode.mask;
    end
  end
end


// Log trap events when the trap cause is latched.
//
// Note: System/trap instructions (ECALL/EBREAK/WFI) and exceptions do not go through the
// normal decode_rdy/instr_accept path, so `exec_pc` is not reliable here. Use `decode.pc`.
always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_trap_pc <= '0;
    log_trap_pc_vld <= 1'b0;
  end
  else begin
    log_trap_pc_vld <= 1'b0;

    if (decode_vld && state == STEADY) begin
      if (core_interrupt
          || decode.illegal
          || (decode.misaligned_jmp && instr_jump)
          || (decode.misaligned_ldst && decode.load)
          || (decode.misaligned_ldst && decode.store)
          || (decode.system && (decode.sysop == ECALL))
          || (decode.system && (decode.sysop == EBREAK))) begin
        log_trap_pc_vld <= 1'b1;
        log_trap_pc <= decode.pc;
      end
    end
    else if (state == WFINTR && core_interrupt) begin
      log_trap_pc_vld <= 1'b1;
      log_trap_pc <= decode.pc;
    end
  end
end

// ============================================================
// ALU
kronos_alu u_alu (
  .op1   (decode.op1  ),
  .op2   (decode.op2  ),
  .aluop (decode.aluop),
  .result(result      )
);

// ============================================================
// LSU
assign lsu_vld = instr_vld || state == LSU;

kronos_lsu #(
  .STBUF_ENABLE(STBUF_ENABLE),
  .STBUF_ALLOW_LOAD_BYPASS(STBUF_ALLOW_LOAD_BYPASS),
  .STBUF_CONFLICT_STALL(STBUF_CONFLICT_STALL)
) u_lsu (
  .clk         (clk         ),
  .rstz        (rstz        ),
  .decode      (decode      ),
  .lsu_vld     (lsu_vld     ),
  .lsu_rdy     (lsu_rdy     ),
  .stbuf_empty (lsu_stbuf_empty),
  .load_data   (load_data   ),
  .regwr_lsu   (regwr_lsu   ),
  .data_addr   (data_addr   ),
  .data_rd_data(data_rd_data),
  .data_wr_data(data_wr_data),
  .data_mask   (data_mask   ),
  .data_wr_en  (data_wr_en  ),
  .data_req    (data_req    ),
  .data_ack    (data_ack    )
);

// ============================================================
// Register Write Back

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    regwr_en <= 1'b0;
  end
  else begin
    regwr_sel <= rd;

    if (instr_vld && decode.regwr_alu) begin
      // Write back ALU result
      regwr_en <= 1'b1;
      regwr_data <= result;
    end
    else if (lsu_rdy && regwr_lsu) begin
      // Write back Load Data
      regwr_en <= 1'b1;
      regwr_data <= load_data;
    end
    else if (csr_rdy && regwr_csr) begin
      // Write back CSR Read Data
      regwr_en <= 1'b1;
      regwr_data <= csr_data;
    end
    else begin
      regwr_en <= 1'b0;
    end
  end
end

// ============================================================
// Jump and Branch
assign branch_target = trap_jump ? trap_handle : decode.addr;
assign instr_jump =  decode.jump || decode.branch;
assign branch = (instr_vld && instr_jump) || trap_jump;

// ============================================================
// Trap Handling

assign exception = decode.illegal || decode.misaligned_ldst || (instr_jump && decode.misaligned_jmp);

// setup for trap
always_ff @(posedge clk) begin
  if (decode_vld && state == STEADY) begin
    if (core_interrupt) begin
      trap_cause <= {1'b1, 27'b0, core_interrupt_cause};
      trap_value <= '0;
    end
    else if (decode.illegal) begin
      trap_cause <= {28'b0, ILLEGAL_INSTR};
      trap_value <= decode.ir;
    end
    else if (decode.misaligned_jmp && instr_jump) begin
      trap_cause <= {28'b0, INSTR_ADDR_MISALIGNED};
      trap_value <= decode.addr;
    end
    else if (decode.misaligned_ldst && decode.load) begin
      trap_cause <= {28'b0, LOAD_ADDR_MISALIGNED};
      trap_value <= decode.addr;
    end
    else if (decode.misaligned_ldst && decode.store) begin
      trap_cause <= {28'b0, STORE_ADDR_MISALIGNED};
      trap_value <= decode.addr;
    end
    else if (decode.sysop == ECALL) begin
      trap_cause <= {28'b0, ECALL_MACHINE};
      trap_value <= '0;
    end
    else if (decode.sysop == EBREAK) begin
      trap_cause <= {28'b0, BREAKPOINT};
      trap_value <= decode.pc;
    end
  end
  else if (state == WFINTR) begin
    if (core_interrupt) begin
      trap_cause <= {1'b1, 27'b0, core_interrupt_cause};
      trap_value <= '0;
    end
  end
end

// ============================================================
// CSR
assign csr_vld = instr_vld || state == CSR;

kronos_csr #(
  .BOOT_ADDR     (BOOT_ADDR     ),
  .HARTID        (HARTID        ),
  .EN_COUNTERS   (EN_COUNTERS   ),
  .EN_COUNTERS64B(EN_COUNTERS64B)
) u_csr (
  .clk                 (clk                 ),
  .rstz                (rstz                ),
  .decode              (decode              ),
  .csr_vld             (csr_vld             ),
  .csr_rdy             (csr_rdy             ),
  .csr_data            (csr_data            ),
  .regwr_csr           (regwr_csr           ),
  .instret             (instret             ),
  .activate_trap       (activate_trap       ),
  .return_trap         (return_trap         ),
  .trap_cause          (trap_cause          ),
  .trap_value          (trap_value          ),
  .trap_handle         (trap_handle         ),
  .trap_jump           (trap_jump           ),
  .software_interrupt  (software_interrupt  ),
  .timer_interrupt     (timer_interrupt     ),
  .external_interrupt  (external_interrupt  ),
  .core_interrupt      (core_interrupt      ),
  .core_interrupt_cause(core_interrupt_cause)
);

assign activate_trap = state == TRAP;
assign return_trap = state == RETURN;

// instruction retired event
always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) instret <= 1'b0;
  else instret <= (decode_vld && decode_rdy)
              || (decode.system && trap_jump);
end

endmodule
