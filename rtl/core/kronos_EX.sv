// Copyright (c) 2020 Sonal Pinto
// SPDX-License-Identifier: Apache-2.0

/*
Kronos Execution Unit
*/

module kronos_EX
  import kronos_types::*;
#(
  parameter logic [31:0]  BOOT_ADDR = 32'h0,
  parameter EN_COUNTERS = 1,
  parameter EN_COUNTERS64B = 1
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

logic lsu_vld, lsu_rdy;
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

logic [31:0] exec_pc;
logic [31:0] exec_ir;
logic [4:0]  exec_rd;
logic [63:0] cycle_counter /* verilator public_flat */;
logic [63:0] exec_start_cycle;
logic [63:0] exec_token;
logic [63:0] next_alloc_token;
logic [63:0] next_terminal_seq;
logic [63:0] next_instret_seq;
logic [31:0] exec_mem_addr;
logic [31:0] exec_mem_data;
logic [3:0]  exec_mem_mask;
logic [31:0] log_inst_pc /* verilator public_flat */;
logic [31:0] log_inst_ir /* verilator public_flat */;
logic        log_inst_pc_vld /* verilator public_flat */;
logic [63:0] log_inst_start_cycle /* verilator public_flat */;
logic [63:0] log_inst_token /* verilator public_flat */;
logic [63:0] log_inst_term_seq /* verilator public_flat */;
logic [63:0] log_inst_instret_seq /* verilator public_flat */;
logic [31:0] log_reg_pc /* verilator public_flat */;
logic        log_reg_pc_vld /* verilator public_flat */;
logic [4:0]  log_reg_rd /* verilator public_flat */;
logic [31:0] log_reg_data /* verilator public_flat */;
logic [63:0] log_reg_start_cycle /* verilator public_flat */;
logic [63:0] log_reg_token /* verilator public_flat */;
logic [31:0] log_mem_pc /* verilator public_flat */;
logic        log_mem_pc_vld /* verilator public_flat */;
logic [31:0] log_mem_addr /* verilator public_flat */;
logic [31:0] log_mem_data /* verilator public_flat */;
logic [3:0]  log_mem_mask /* verilator public_flat */;
logic [63:0] log_mem_start_cycle /* verilator public_flat */;
logic [63:0] log_mem_token /* verilator public_flat */;
logic [31:0] log_trap_pc /* verilator public_flat */;
logic [31:0] log_trap_ir /* verilator public_flat */;
logic        log_trap_pc_vld /* verilator public_flat */;
logic [63:0] log_trap_start_cycle /* verilator public_flat */;
logic [63:0] log_trap_token /* verilator public_flat */;
logic [63:0] log_trap_term_seq /* verilator public_flat */;
logic [63:0] log_trap_instret_seq /* verilator public_flat */;
logic        log_trap_token_vld /* verilator public_flat */;
logic        log_trap_irq /* verilator public_flat */;
logic        regwr_fire;
logic [31:0] regwr_log_pc;
logic [4:0]  regwr_log_rd;
logic [31:0] regwr_log_data;
logic [63:0] regwr_log_start_cycle;
logic [63:0] regwr_log_token;
logic        memwr_fire;
logic [31:0] memwr_log_pc;
logic [63:0] memwr_log_start_cycle;
logic [63:0] memwr_log_token;
logic        trap_log_fire;
logic [31:0] trap_log_pc;
logic [31:0] trap_log_ir;
logic [63:0] trap_log_start_cycle;
logic [63:0] trap_log_token;
logic        trap_log_token_vld;
logic        trap_log_irq;
logic        alloc_fire;
logic        inst_log_fire;
logic [31:0] inst_log_pc;
logic [31:0] inst_log_ir;
logic [63:0] inst_log_start_cycle;
logic [63:0] inst_log_token;

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
      else if (decode.load || decode.store) next_state = LSU;
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
// Allocation is the first cycle in which EX accepts the decoded instruction.
// An interrupt wins before allocation and is an independent event, so it does
// not consume an instruction token. A synchronous exception does allocate a
// token and later terminates as a precise trap.
assign alloc_fire = decode_vld && state == STEADY && ~core_interrupt;

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) cycle_counter <= '0;
  else cycle_counter <= cycle_counter + 64'd1;
end

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    next_alloc_token <= '0;
    next_terminal_seq <= '0;
    next_instret_seq <= '0;
  end
  else begin
    if (alloc_fire) next_alloc_token <= next_alloc_token + 64'd1;
    if (inst_log_fire || (trap_log_fire && trap_log_token_vld))
      next_terminal_seq <= next_terminal_seq + 64'd1;
    if (inst_log_fire) next_instret_seq <= next_instret_seq + 64'd1;
  end
end

// Basic instructions
assign basic_rdy = instr_vld && decode.basic;

// Next instructions
assign decode_rdy = |{basic_rdy, lsu_rdy, csr_rdy};

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    exec_pc <= '0;
    exec_ir <= '0;
    exec_rd <= '0;
    exec_start_cycle <= '0;
    exec_token <= '0;
  end
  else if (alloc_fire) begin
    exec_pc <= decode.pc;
    exec_ir <= decode.ir;
    exec_rd <= rd;
    exec_start_cycle <= cycle_counter + 64'd1;
    exec_token <= next_alloc_token;
  end
end

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    exec_mem_addr <= '0;
    exec_mem_data <= '0;
    exec_mem_mask <= '0;
  end
  else if (decode_vld && state == STEADY && (decode.load || decode.store)) begin
    exec_mem_addr <= {decode.addr[31:2], 2'b0};
    exec_mem_data <= decode.op2;
    exec_mem_mask <= decode.mask;
  end
end

always_comb begin
  inst_log_fire = 1'b0;
  inst_log_pc = exec_pc;
  inst_log_ir = exec_ir;
  inst_log_start_cycle = exec_start_cycle;
  inst_log_token = exec_token;

  if (basic_rdy) begin
    inst_log_fire = 1'b1;
    inst_log_pc = decode.pc;
    inst_log_ir = decode.ir;
    inst_log_start_cycle = cycle_counter + 64'd1;
    inst_log_token = next_alloc_token;
  end
  else if (lsu_rdy || csr_rdy) begin
    inst_log_fire = 1'b1;
    if (state == STEADY) begin
      inst_log_pc = decode.pc;
      inst_log_ir = decode.ir;
      inst_log_start_cycle = cycle_counter + 64'd1;
      inst_log_token = next_alloc_token;
    end
  end
  else if (decode.system && trap_jump &&
           (decode.sysop == MRET || decode.sysop == WFI)) begin
    inst_log_fire = 1'b1;
  end
end

always_comb begin
  regwr_fire = 1'b0;
  regwr_log_pc = exec_pc;
  regwr_log_rd = exec_rd;
  regwr_log_data = '0;
  regwr_log_start_cycle = exec_start_cycle;
  regwr_log_token = exec_token;

  if (instr_vld && decode.regwr_alu) begin
    regwr_fire = 1'b1;
    regwr_log_pc = decode.pc;
    regwr_log_rd = rd;
    regwr_log_data = result;
    regwr_log_start_cycle = cycle_counter + 64'd1;
    regwr_log_token = next_alloc_token;
  end
  else if (lsu_rdy && regwr_lsu) begin
    regwr_fire = 1'b1;
    regwr_log_data = load_data;
    if (state == STEADY) begin
      regwr_log_pc = decode.pc;
      regwr_log_rd = rd;
      regwr_log_start_cycle = cycle_counter + 64'd1;
      regwr_log_token = next_alloc_token;
    end
  end
  else if (csr_rdy && regwr_csr) begin
    regwr_fire = 1'b1;
    regwr_log_data = csr_data;
    if (state == STEADY) begin
      regwr_log_pc = decode.pc;
      regwr_log_rd = rd;
      regwr_log_start_cycle = cycle_counter + 64'd1;
      regwr_log_token = next_alloc_token;
    end
  end
end

always_comb begin
  memwr_fire = 1'b0;
  memwr_log_pc = exec_pc;
  memwr_log_start_cycle = exec_start_cycle;
  memwr_log_token = exec_token;

  if (lsu_rdy && decode.store) begin
    memwr_fire = 1'b1;
    if (state == STEADY) begin
      memwr_log_pc = decode.pc;
      memwr_log_start_cycle = cycle_counter + 64'd1;
      memwr_log_token = next_alloc_token;
    end
  end
end

always_comb begin
  trap_log_fire = 1'b0;
  trap_log_pc = exec_pc;
  trap_log_ir = exec_ir;
  trap_log_start_cycle = exec_start_cycle;
  trap_log_token = exec_token;
  trap_log_token_vld = 1'b0;
  trap_log_irq = 1'b0;

  if (state == STEADY && decode_vld && (core_interrupt || exception
      || (decode.system && (decode.sysop == ECALL || decode.sysop == EBREAK)))) begin
    trap_log_fire = 1'b1;
    trap_log_pc = decode.pc;
    trap_log_ir = decode.ir;
    trap_log_irq = core_interrupt;
    trap_log_start_cycle = cycle_counter + 64'd1;
    if (core_interrupt) begin
      trap_log_token = '0;
    end
    else begin
      trap_log_token = next_alloc_token;
      trap_log_token_vld = 1'b1;
    end
  end
  else if (state == WFINTR && core_interrupt) begin
    trap_log_fire = 1'b1;
    trap_log_start_cycle = cycle_counter + 64'd1;
    trap_log_token = '0;
    trap_log_irq = 1'b1;
  end
end

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_inst_pc <= '0;
    log_inst_ir <= '0;
    log_inst_pc_vld <= 1'b0;
    log_inst_start_cycle <= '0;
    log_inst_token <= '0;
    log_inst_term_seq <= '0;
    log_inst_instret_seq <= '0;
  end
  else begin
    log_inst_pc_vld <= inst_log_fire;
    if (inst_log_fire) begin
      log_inst_pc <= inst_log_pc;
      log_inst_ir <= inst_log_ir;
      log_inst_start_cycle <= inst_log_start_cycle;
      log_inst_token <= inst_log_token;
      log_inst_term_seq <= next_terminal_seq;
      log_inst_instret_seq <= next_instret_seq;
    end
    if (inst_log_fire && (inst_log_start_cycle == 0 ||
                          cycle_counter + 64'd1 < inst_log_start_cycle))
      $error("Kronos commit timing invariant failed: token=%0d start=%0d end=%0d",
             inst_log_token, inst_log_start_cycle, cycle_counter + 64'd1);
  end
end

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_reg_pc <= '0;
    log_reg_pc_vld <= 1'b0;
    log_reg_rd <= '0;
    log_reg_data <= '0;
    log_reg_start_cycle <= '0;
    log_reg_token <= '0;
  end
  else begin
    log_reg_pc_vld <= regwr_fire;
    if (regwr_fire) begin
      log_reg_pc <= regwr_log_pc;
      log_reg_rd <= regwr_log_rd;
      log_reg_data <= regwr_log_data;
      log_reg_start_cycle <= regwr_log_start_cycle;
      log_reg_token <= regwr_log_token;
    end
  end
end

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_mem_pc <= '0;
    log_mem_pc_vld <= 1'b0;
    log_mem_addr <= '0;
    log_mem_data <= '0;
    log_mem_mask <= '0;
    log_mem_start_cycle <= '0;
    log_mem_token <= '0;
  end
  else begin
    log_mem_pc_vld <= memwr_fire;
    if (memwr_fire) begin
      log_mem_pc <= memwr_log_pc;
      if (state == STEADY) begin
        log_mem_addr <= {decode.addr[31:2], 2'b0};
        log_mem_data <= decode.op2;
        log_mem_mask <= decode.mask;
      end
      else begin
        log_mem_addr <= exec_mem_addr;
        log_mem_data <= exec_mem_data;
        log_mem_mask <= exec_mem_mask;
      end
      log_mem_start_cycle <= memwr_log_start_cycle;
      log_mem_token <= memwr_log_token;
    end
  end
end

always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    log_trap_pc <= '0;
    log_trap_ir <= '0;
    log_trap_pc_vld <= 1'b0;
    log_trap_start_cycle <= '0;
    log_trap_token <= '0;
    log_trap_term_seq <= '0;
    log_trap_instret_seq <= '0;
    log_trap_token_vld <= 1'b0;
    log_trap_irq <= 1'b0;
  end
  else begin
    log_trap_pc_vld <= trap_log_fire;
    if (trap_log_fire) begin
      log_trap_pc <= trap_log_pc;
      log_trap_ir <= trap_log_ir;
      log_trap_start_cycle <= trap_log_start_cycle;
      log_trap_token <= trap_log_token;
      log_trap_term_seq <= next_terminal_seq;
      log_trap_instret_seq <= next_instret_seq;
      log_trap_token_vld <= trap_log_token_vld;
      log_trap_irq <= trap_log_irq;
    end
    if (trap_log_fire && trap_log_token_vld &&
        (trap_log_start_cycle == 0 || cycle_counter + 64'd1 < trap_log_start_cycle))
      $error("Kronos trap timing invariant failed: token=%0d start=%0d end=%0d",
             trap_log_token, trap_log_start_cycle, cycle_counter + 64'd1);
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

kronos_lsu u_lsu (
  .decode      (decode      ),
  .lsu_vld     (lsu_vld     ),
  .lsu_rdy     (lsu_rdy     ),
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
              || (decode.system && trap_jump &&
                  (decode.sysop == MRET || decode.sysop == WFI));
end

endmodule
