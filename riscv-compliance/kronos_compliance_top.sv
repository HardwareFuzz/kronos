// Copyright (c) 2020 Sonal Pinto
// SPDX-License-Identifier: Apache-2.0

module kronos_compliance_top #(
  parameter int unsigned NUM_CORES = 2,
  parameter STBUF_ENABLE = 0,
  parameter STBUF_ALLOW_LOAD_BYPASS = 0,
  parameter STBUF_CONFLICT_STALL = 1,
  parameter FENCE_DRAIN_STBUF = 1
) (
  input  logic        clk,
  input  logic        rstz,
  // IO probes
  output logic [31:0] instr_addr,
  output logic [31:0] instr_data,
  output logic        instr_req,
  output logic        instr_ack,
  output logic [31:0] data_addr,
  output logic [31:0] data_rd_data,
  output logic [31:0] data_wr_data,
  output logic [3:0]  data_mask,
  output logic        data_wr_en,
  output logic        data_req,
  output logic        data_ack
);

// Single-port memory command (synchronous read: response next cycle).
logic [31:0] mem_addr;
logic [31:0] mem_wr_data;
logic [31:0] mem_rd_data;
logic        mem_en;
logic        mem_wr_en;
logic [3:0]  mem_mask;

logic [31:0] instr_addr_c [NUM_CORES];
logic [31:0] instr_data_c [NUM_CORES];
logic        instr_req_c  [NUM_CORES];
logic        instr_ack_c  [NUM_CORES];
logic [31:0] data_addr_c  [NUM_CORES];
logic [31:0] data_rd_data_c [NUM_CORES];
logic [31:0] data_wr_data_c [NUM_CORES];
logic [3:0]  data_mask_c  [NUM_CORES];
logic        data_wr_en_c [NUM_CORES];
logic        data_req_c   [NUM_CORES];
logic        data_ack_c   [NUM_CORES];

assign instr_addr  = instr_addr_c[0];
assign instr_data  = instr_data_c[0];
assign instr_req   = instr_req_c[0];
assign instr_ack   = instr_ack_c[0];
// For multi-core runs, expose the arbitrated memory bus on the data probes.
// Note: the bus command (addr/data/mask/wr_en) reflects the *current* grant,
// while the ack reflects the *previous* cycle's grant (synchronous read).
assign data_addr    = mem_addr;
assign data_rd_data = mem_rd_data;
assign data_wr_data = mem_wr_data;
assign data_mask    = mem_mask;
assign data_wr_en   = mem_wr_en;
assign data_req     = (grant == GRANT_C0_DATA) ? 1'b1 :
                      (grant == GRANT_C1_DATA) ? 1'b1 : 1'b0;
assign data_ack     = (resp_grant_q == GRANT_C0_DATA) ? 1'b1 :
                      (resp_grant_q == GRANT_C1_DATA) ? 1'b1 : 1'b0;

for (genvar i = 0; i < NUM_CORES; i++) begin : gen_cores
  kronos_core #(
    .HARTID(i),
    .STBUF_ENABLE(STBUF_ENABLE),
    .STBUF_ALLOW_LOAD_BYPASS(STBUF_ALLOW_LOAD_BYPASS),
    .STBUF_CONFLICT_STALL(STBUF_CONFLICT_STALL),
    .FENCE_DRAIN_STBUF(FENCE_DRAIN_STBUF)
  ) u_core (
    .clk               (clk              ),
    .rstz              (rstz             ),
    .instr_addr        (instr_addr_c[i]  ),
    .instr_data        (instr_data_c[i]  ),
    .instr_req         (instr_req_c[i]   ),
    .instr_ack         (instr_ack_c[i]   ),
    .data_addr         (data_addr_c[i]   ),
    .data_rd_data      (data_rd_data_c[i]),
    .data_wr_data      (data_wr_data_c[i]),
    .data_mask         (data_mask_c[i]   ),
    .data_wr_en        (data_wr_en_c[i]  ),
    .data_req          (data_req_c[i]    ),
    .data_ack          (data_ack_c[i]    ),
    .software_interrupt(1'b0             ),
    .timer_interrupt   (1'b0             ),
    .external_interrupt(1'b0             )
  );
end

// ------------------------------------------------------------
// Trace monitors (per core)
// Exposed via `public_flat` so the C++ runner can log dual-hart traces.
logic [31:0] trace_reg_pc   [NUM_CORES] /* verilator public_flat */;
logic        trace_reg_vld  [NUM_CORES] /* verilator public_flat */;
logic [4:0]  trace_reg_rd   [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_reg_data [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_reg_ir   [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_reg_op1  [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_reg_op2  [NUM_CORES] /* verilator public_flat */;

logic [31:0] trace_mem_pc   [NUM_CORES] /* verilator public_flat */;
logic        trace_mem_vld  [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_mem_addr [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_mem_data [NUM_CORES] /* verilator public_flat */;
logic [3:0]  trace_mem_mask [NUM_CORES] /* verilator public_flat */;

logic [31:0] trace_trap_pc    [NUM_CORES] /* verilator public_flat */;
logic        trace_trap_vld   [NUM_CORES] /* verilator public_flat */;
logic [31:0] trace_trap_cause [NUM_CORES] /* verilator public_flat */;

for (genvar t = 0; t < NUM_CORES; t++) begin : gen_trace
  // Register writeback
  assign trace_reg_pc[t] = gen_cores[t].u_core.u_ex.log_reg_pc;
  assign trace_reg_vld[t] = gen_cores[t].u_core.u_ex.log_reg_pc_vld;
  // Use EX-stage writeback signals so {pc,rd,data} stay aligned.
  assign trace_reg_rd[t] = gen_cores[t].u_core.u_ex.regwr_sel;
  assign trace_reg_data[t] = gen_cores[t].u_core.u_ex.regwr_data;
  assign trace_reg_ir[t] = gen_cores[t].u_core.u_ex.log_reg_ir;
  assign trace_reg_op1[t] = gen_cores[t].u_core.u_ex.log_reg_op1;
  assign trace_reg_op2[t] = gen_cores[t].u_core.u_ex.log_reg_op2;

  // Architectural store events
  assign trace_mem_pc[t] = gen_cores[t].u_core.u_ex.log_mem_pc;
  assign trace_mem_vld[t] = gen_cores[t].u_core.u_ex.log_mem_pc_vld;
  assign trace_mem_addr[t] = gen_cores[t].u_core.u_ex.log_mem_addr;
  assign trace_mem_data[t] = gen_cores[t].u_core.u_ex.log_mem_data;
  assign trace_mem_mask[t] = gen_cores[t].u_core.u_ex.log_mem_mask;

  // Trap/exception events
  assign trace_trap_pc[t] = gen_cores[t].u_core.u_ex.log_trap_pc;
  assign trace_trap_vld[t] = gen_cores[t].u_core.u_ex.log_trap_pc_vld;
  assign trace_trap_cause[t] = gen_cores[t].u_core.u_ex.trap_cause;
end

typedef enum logic [2:0] {
  GRANT_NONE    = 3'd0,
  GRANT_C0_DATA = 3'd1,
  GRANT_C1_DATA = 3'd2,
  GRANT_C0_INS  = 3'd3,
  GRANT_C1_INS  = 3'd4
} grant_e;

grant_e grant;
grant_e resp_grant_q;

// Global fairness (avoid starving instruction fetch when one core streams data).
// Round-robin across {c0_data, c1_data, c0_ins, c1_ins}.
logic [1:0] last_req;
logic req_c0_data, req_c1_data, req_c0_ins, req_c1_ins;

always_comb begin
  req_c0_data = data_req_c[0];
  req_c1_data = data_req_c[1];
  req_c0_ins  = instr_req_c[0];
  req_c1_ins  = instr_req_c[1];
end

always_comb begin
  grant = GRANT_NONE;

  // Next after last_req, wrap around.
  unique case (last_req)
    2'd0: begin
      if (req_c1_data) grant = GRANT_C1_DATA;
      else if (req_c0_ins) grant = GRANT_C0_INS;
      else if (req_c1_ins) grant = GRANT_C1_INS;
      else if (req_c0_data) grant = GRANT_C0_DATA;
    end
    2'd1: begin
      if (req_c0_ins) grant = GRANT_C0_INS;
      else if (req_c1_ins) grant = GRANT_C1_INS;
      else if (req_c0_data) grant = GRANT_C0_DATA;
      else if (req_c1_data) grant = GRANT_C1_DATA;
    end
    2'd2: begin
      if (req_c1_ins) grant = GRANT_C1_INS;
      else if (req_c0_data) grant = GRANT_C0_DATA;
      else if (req_c1_data) grant = GRANT_C1_DATA;
      else if (req_c0_ins) grant = GRANT_C0_INS;
    end
    default: begin // 2'd3
      if (req_c0_data) grant = GRANT_C0_DATA;
      else if (req_c1_data) grant = GRANT_C1_DATA;
      else if (req_c0_ins) grant = GRANT_C0_INS;
      else if (req_c1_ins) grant = GRANT_C1_INS;
    end
  endcase
end

always_comb begin
  mem_en = (grant != GRANT_NONE);
  mem_wr_en = 1'b0;
  mem_addr = 32'b0;
  mem_wr_data = 32'b0;
  mem_mask = 4'b0;

  case (grant)
    GRANT_C0_DATA: begin
      mem_wr_en = data_req_c[0] && data_wr_en_c[0];
      mem_addr = data_addr_c[0];
      mem_wr_data = data_wr_data_c[0];
      mem_mask = data_mask_c[0];
    end
    GRANT_C1_DATA: begin
      mem_wr_en = data_req_c[1] && data_wr_en_c[1];
      mem_addr = data_addr_c[1];
      mem_wr_data = data_wr_data_c[1];
      mem_mask = data_mask_c[1];
    end
    GRANT_C0_INS: begin
      mem_addr = instr_addr_c[0];
    end
    GRANT_C1_INS: begin
      mem_addr = instr_addr_c[1];
    end
    default: begin end
  endcase
end

always_ff @(posedge clk or negedge rstz) begin
  if (!rstz) begin
    resp_grant_q <= GRANT_NONE;
    last_req <= 2'd0;
  end else begin
    // Latch the grant used for the memory command in the *previous* cycle.
    // This aligns with the synchronous `generic_spram` read data output.
    resp_grant_q <= grant;

    if (grant != GRANT_NONE) begin
      unique case (grant)
        GRANT_C0_DATA: last_req <= 2'd0;
        GRANT_C1_DATA: last_req <= 2'd1;
        GRANT_C0_INS: last_req <= 2'd2;
        GRANT_C1_INS: last_req <= 2'd3;
        default: last_req <= last_req;
      endcase
    end
  end
end

always_comb begin
  integer j;
  for (j = 0; j < NUM_CORES; j++) begin
    instr_data_c[j] = 32'b0;
    data_rd_data_c[j] = 32'b0;
    instr_ack_c[j] = 1'b0;
    data_ack_c[j] = 1'b0;
  end
  case (resp_grant_q)
    GRANT_C0_INS: begin
      instr_ack_c[0] = 1'b1;
      instr_data_c[0] = mem_rd_data;
    end
    GRANT_C1_INS: begin
      instr_ack_c[1] = 1'b1;
      instr_data_c[1] = mem_rd_data;
    end
    GRANT_C0_DATA: begin
      data_ack_c[0] = 1'b1;
      data_rd_data_c[0] = mem_rd_data;
    end
    GRANT_C1_DATA: begin
      data_ack_c[1] = 1'b1;
      data_rd_data_c[1] = mem_rd_data;
    end
    default: ;
  endcase
end

generic_spram #(.KB(8)) u_mem (
  .clk  (clk        ),
  .addr (mem_addr   ),
  .wdata(mem_wr_data),
  .rdata(mem_rd_data),
  .en   (mem_en     ),
  .wr_en(mem_wr_en  ),
  .mask (mem_mask   )
);

logic [31:0] commit_pc_mon /* verilator public_flat */;
always_comb commit_pc_mon = gen_cores[0].u_core.decode.pc;

endmodule
