// Copyright (c) 2020 Sonal Pinto
// SPDX-License-Identifier: Apache-2.0

/*
Kronos Load Store Unit

Control unit that interfaces with "Data" memory and fulfills
Load/Store instructions

Memory Access needs to be aligned.

*/

module kronos_lsu
  import kronos_types::*;
#(
  parameter STBUF_ENABLE = 0,
  parameter STBUF_ALLOW_LOAD_BYPASS = 0,
  parameter STBUF_CONFLICT_STALL = 1
)(
  // ID/EX
  input  logic        clk,
  input  logic        rstz,
  input  pipeIDEX_t   decode,
  input  logic        lsu_vld,
  output logic        lsu_rdy,
  output logic        stbuf_empty,
  // Register write-back
  output logic [31:0] load_data,
  output logic        regwr_lsu,
  // Memory interface
  output logic [31:0] data_addr,
  input  logic [31:0] data_rd_data,
  output logic [31:0] data_wr_data,
  output logic [3:0]  data_mask,
  output logic        data_wr_en,
  output logic        data_req,
  input  logic        data_ack
);

logic [4:0] rd;
logic [1:0] byte_addr;
logic [1:0] data_size;
logic load_uns;

logic [3:0][7:0] ldata;
logic [31:0] word_data, half_data, byte_data;

logic stbuf_valid;
logic stbuf_req_active;
logic [31:0] stbuf_addr;
logic [31:0] stbuf_data;
logic [3:0]  stbuf_mask;

wire decode_load = lsu_vld && decode.load;
wire decode_store = lsu_vld && decode.store;
wire decode_mem = decode_load || decode_store;

wire stbuf_conflict = stbuf_valid && (decode.addr[31:2] == stbuf_addr[31:2]);
wire load_blocked = STBUF_ENABLE && stbuf_valid &&
                    (!STBUF_ALLOW_LOAD_BYPASS || (STBUF_CONFLICT_STALL && stbuf_conflict));
wire store_buffered = STBUF_ENABLE && decode_store && !stbuf_valid;
wire store_blocked = STBUF_ENABLE && decode_store && stbuf_valid;
wire decode_req_active = decode_mem && !load_blocked && !store_buffered && !store_blocked && !stbuf_req_active;
wire use_stbuf_req = stbuf_req_active;

assign stbuf_empty = ~(stbuf_valid || stbuf_req_active);

// ============================================================
// IR Segments
assign byte_addr = decode.addr[1:0];
assign data_size = decode.ir[13:12];
assign load_uns = decode.ir[14];
assign rd  = decode.ir[11:7];

// ============================================================
// Memory interface
assign data_addr = use_stbuf_req ? {stbuf_addr[31:2], 2'b0} : {decode.addr[31:2], 2'b0};
assign data_wr_data = use_stbuf_req ? stbuf_data : decode.op2;
assign data_mask = use_stbuf_req ? stbuf_mask : decode.mask;
assign data_wr_en = ~data_ack && (use_stbuf_req || (decode_req_active && decode.store));
assign data_req = ~data_ack && (use_stbuf_req || decode_req_active);

// response controls
assign lsu_rdy = store_buffered || (decode_req_active && data_ack);
assign regwr_lsu = decode.load && rd != '0;

// ============================================================
// Store buffer control
always_ff @(posedge clk or negedge rstz) begin
  if (~rstz) begin
    stbuf_valid <= 1'b0;
    stbuf_req_active <= 1'b0;
  end
  else begin
    if (stbuf_req_active && data_ack) begin
      stbuf_req_active <= 1'b0;
      stbuf_valid <= 1'b0;
    end

    if (store_buffered) begin
      stbuf_valid <= 1'b1;
      stbuf_addr <= decode.addr;
      stbuf_data <= decode.op2;
      stbuf_mask <= decode.mask;
    end

    if (!stbuf_req_active && stbuf_valid && !decode_req_active && !store_buffered) begin
      stbuf_req_active <= 1'b1;
    end
  end
end

// ============================================================
// Load

// byte cast read data
assign ldata = data_rd_data;

always_comb begin
  // Barrel Rotate Right read data bytes as per offset
  case(byte_addr)
    2'b00: word_data = ldata;
    2'b01: word_data = {ldata[0]  , ldata[3:1]};
    2'b10: word_data = {ldata[1:0], ldata[3:2]};
    2'b11: word_data = {ldata[2:0], ldata[3]};
  endcase
end

always_comb begin
  // select BYTE data, sign extend if needed
  if (load_uns) byte_data = {24'b0, word_data[7:0]};
  else byte_data = {{24{word_data[7]}}, word_data[7:0]};

  // Select HALF data, sign extend if needed
  if (load_uns) half_data = {16'b0, word_data[15:0]};
  else half_data = {{16{word_data[15]}}, word_data[15:0]};
end

// Finally, mux load data
always_comb begin
  if (data_size == BYTE) load_data = byte_data;
  else if (data_size == HALF) load_data = half_data;
  else load_data = word_data;
end


// ------------------------------------------------------------
`ifdef verilator
logic _unused = &{1'b0
  , decode
};
`endif

endmodule
