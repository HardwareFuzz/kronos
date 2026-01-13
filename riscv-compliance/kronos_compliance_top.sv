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

logic [31:0] mem_addr;
logic [31:0] mem_wr_data;
logic [31:0] mem_rd_data;
logic mem_en, mem_wr_en;
logic [3:0] mem_mask;

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
assign data_addr   = data_addr_c[0];
assign data_rd_data = data_rd_data_c[0];
assign data_wr_data = data_wr_data_c[0];
assign data_mask   = data_mask_c[0];
assign data_wr_en  = data_wr_en_c[0];
assign data_req    = data_req_c[0];
assign data_ack    = data_ack_c[0];

for (genvar i = 0; i < NUM_CORES; i++) begin : gen_cores
  kronos_core #(
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

typedef enum logic [2:0] {
  GRANT_NONE    = 3'd0,
  GRANT_C0_DATA = 3'd1,
  GRANT_C1_DATA = 3'd2,
  GRANT_C0_INS  = 3'd3,
  GRANT_C1_INS  = 3'd4
} grant_e;

grant_e grant, read_grant;

// Priority: data0 > data1 > instr0 > instr1
always_comb begin
  grant = GRANT_NONE;
  if (data_req_c[0])
    grant = GRANT_C0_DATA;
  else if (data_req_c[1])
    grant = GRANT_C1_DATA;
  else if (instr_req_c[0])
    grant = GRANT_C0_INS;
  else if (instr_req_c[1])
    grant = GRANT_C1_INS;
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
  integer k;
  if (!rstz) begin
    for (k = 0; k < NUM_CORES; k++) begin
      instr_ack_c[k] <= 1'b0;
      data_ack_c[k] <= 1'b0;
    end
    read_grant <= GRANT_NONE;
  end else begin
    for (k = 0; k < NUM_CORES; k++) begin
      instr_ack_c[k] <= 1'b0;
      data_ack_c[k] <= 1'b0;
    end
    case (grant)
      GRANT_C0_INS: instr_ack_c[0] <= 1'b1;
      GRANT_C1_INS: instr_ack_c[1] <= 1'b1;
      GRANT_C0_DATA: data_ack_c[0] <= 1'b1;
      GRANT_C1_DATA: data_ack_c[1] <= 1'b1;
      default: ;
    endcase

    if (mem_en && !mem_wr_en)
      read_grant <= grant;
    else
      read_grant <= GRANT_NONE;
  end
end

always_comb begin
  integer j;
  for (j = 0; j < NUM_CORES; j++) begin
    instr_data_c[j] = 32'b0;
    data_rd_data_c[j] = 32'b0;
  end
  case (read_grant)
    GRANT_C0_INS: instr_data_c[0] = mem_rd_data;
    GRANT_C1_INS: instr_data_c[1] = mem_rd_data;
    GRANT_C0_DATA: data_rd_data_c[0] = mem_rd_data;
    GRANT_C1_DATA: data_rd_data_c[1] = mem_rd_data;
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
