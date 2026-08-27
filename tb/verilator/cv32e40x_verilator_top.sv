// Copyright 2026
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Thin structural wrapper for Verilator.
//
// cv32e40x_core cannot be used directly as a Verilator top because its XIF
// ports are SystemVerilog interfaces.  This module terminates the disabled
// XIF interface and exposes every ordinary core signal as a plain top-level
// port.  All simulation behavior (clock/reset, OBI memory, UART and tohost)
// lives in sim_main.cpp.

module cv32e40x_verilator_top (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        scan_cg_en_i,

  input  logic [31:0] boot_addr_i,
  input  logic [31:0] dm_exception_addr_i,
  input  logic [31:0] dm_halt_addr_i,
  input  logic [31:0] mhartid_i,
  input  logic [3:0]  mimpid_patch_i,
  input  logic [31:0] mtvec_addr_i,

  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  output logic [1:0]  instr_memtype_o,
  output logic [2:0]  instr_prot_o,
  output logic        instr_dbg_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic [31:0] data_addr_o,
  output logic [3:0]  data_be_o,
  output logic        data_we_o,
  output logic [31:0] data_wdata_o,
  output logic [1:0]  data_memtype_o,
  output logic [2:0]  data_prot_o,
  output logic        data_dbg_o,
  output logic [5:0]  data_atop_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,
  input  logic        data_exokay_i,

  output logic [63:0] mcycle_o,
  input  logic [63:0] time_i,

  input  logic [31:0] irq_i,
  input  logic        wu_wfe_i,
  input  logic        clic_irq_i,
  input  logic [4:0]  clic_irq_id_i,
  input  logic [7:0]  clic_irq_level_i,
  input  logic [1:0]  clic_irq_priv_i,
  input  logic        clic_irq_shv_i,

  output logic        fencei_flush_req_o,
  input  logic        fencei_flush_ack_i,

  input  logic        debug_req_i,
  output logic        debug_havereset_o,
  output logic        debug_running_o,
  output logic        debug_halted_o,
  output logic        debug_pc_valid_o,
  output logic [31:0] debug_pc_o,

  input  logic        fetch_enable_i,
  output logic        core_sleep_o
);
  import cv32e40x_pkg::*;

  cv32e40x_if_xif #(
    .X_NUM_RS    (2),
    .X_ID_WIDTH  (4),
    .X_MEM_WIDTH (32),
    .X_RFR_WIDTH (32),
    .X_RFW_WIDTH (32)
  ) xif();

  // XIF前端与阵列控制器之间的内部命令通道。
  logic        npu_cmd_valid;
  logic        npu_cmd_ready;
  logic [2:0]  npu_cmd_opcode;
  logic [31:0] npu_cmd_arg0;
  logic [31:0] npu_cmd_arg1;
  logic        npu_rsp_valid;
  logic        npu_rsp_ready;
  logic [31:0] npu_rsp_data;
  logic        npu_rsp_error;

  localparam logic [31:0] DMA_MMIO_BASE = 32'h4000_0000;
  localparam logic [31:0] A_SPM_BASE    = 32'h5000_0000;
  localparam logic [31:0] B_SPM_BASE    = 32'h5001_0000;
  localparam logic [31:0] C_SPM_BASE    = 32'h5002_0000;
  localparam int unsigned SPM_DEPTH     = 256;

  // 核的原始data_*先进入地址router；顶层公开的data_*现在代表CPU和DMA
  // 仲裁后的统一主存端口，仍由sim_main.cpp中的内存模型响应。
  logic        core_data_req, core_data_gnt, core_data_rvalid;
  logic [31:0] core_data_addr, core_data_wdata, core_data_rdata;
  logic [3:0]  core_data_be;
  logic        core_data_we, core_data_err, core_data_exokay;
  logic [1:0]  core_data_memtype;
  logic [2:0]  core_data_prot;
  logic        core_data_dbg;
  logic [5:0]  core_data_atop;

  cv32e40x_if_c_obi #(
    .REQ_TYPE(obi_data_req_t), .RESP_TYPE(obi_data_resp_t)
  ) cpu_mem_if();
  cv32e40x_if_c_obi #(
    .REQ_TYPE(obi_data_req_t), .RESP_TYPE(obi_data_resp_t)
  ) dma_cfg_if();
  cv32e40x_if_c_obi #(
    .REQ_TYPE(obi_data_req_t), .RESP_TYPE(obi_data_resp_t)
  ) dma_mem_if();
  cv32e40x_if_c_obi #(
    .REQ_TYPE(obi_data_req_t), .RESP_TYPE(obi_data_resp_t)
  ) fabric_mem_if();

  cpu_data_router #(
    .DMA_MMIO_BASE_ADDR(DMA_MMIO_BASE)
  ) cpu_data_router_i (
    .clk(clk_i), .rst_n(rst_ni),
    .cpu_req_i(core_data_req), .cpu_gnt_o(core_data_gnt),
    .cpu_addr_i(core_data_addr), .cpu_be_i(core_data_be),
    .cpu_we_i(core_data_we), .cpu_wdata_i(core_data_wdata),
    .cpu_memtype_i(core_data_memtype), .cpu_prot_i(core_data_prot),
    .cpu_dbg_i(core_data_dbg), .cpu_atop_i(core_data_atop),
    .cpu_rvalid_o(core_data_rvalid), .cpu_rdata_o(core_data_rdata),
    .cpu_err_o(core_data_err), .cpu_exokay_o(core_data_exokay),
    .m_cpu_mem_if(cpu_mem_if.master), .m_dma_cfg_if(dma_cfg_if.master)
  );

  logic dma_spm_valid, dma_spm_ready, dma_spm_we;
  logic [31:0] dma_spm_addr, dma_spm_wdata;
  logic dma_spm_rsp_ready, dma_spm_rsp_valid;
  logic [31:0] dma_spm_rsp_rdata;

  dma dma_i (
    .clk(clk_i), .rst_n(rst_ni),
    .s_c_obi_cfg_if(dma_cfg_if.slave), .m_c_obi_mem_if(dma_mem_if.master),
    .spm_req_valid(dma_spm_valid), .spm_req_addr(dma_spm_addr),
    .spm_req_we(dma_spm_we), .spm_req_wdata(dma_spm_wdata),
    .spm_req_ready(dma_spm_ready),
    .spm_rsp_ready(dma_spm_rsp_ready),
    .spm_rsp_valid(dma_spm_rsp_valid),
    .spm_rsp_rdata(dma_spm_rsp_rdata)
  );

  obi_mem_arbiter obi_mem_arbiter_i (
    .clk(clk_i), .rst_n(rst_ni),
    .s_cpu_if(cpu_mem_if.slave), .s_dma_if(dma_mem_if.slave),
    .m_mem_if(fabric_mem_if.master)
  );

  assign data_req_o     = fabric_mem_if.s_req.req;
  assign data_addr_o    = fabric_mem_if.req_payload.addr;
  assign data_atop_o    = fabric_mem_if.req_payload.atop;
  assign data_we_o      = fabric_mem_if.req_payload.we;
  assign data_be_o      = fabric_mem_if.req_payload.be;
  assign data_wdata_o   = fabric_mem_if.req_payload.wdata;
  assign data_memtype_o = fabric_mem_if.req_payload.memtype;
  assign data_prot_o    = fabric_mem_if.req_payload.prot;
  assign data_dbg_o     = fabric_mem_if.req_payload.dbg;
  assign fabric_mem_if.s_gnt.gnt = data_gnt_i;
  assign fabric_mem_if.s_rvalid.rvalid = data_rvalid_i;
  assign fabric_mem_if.resp_payload.rdata = data_rdata_i;
  assign fabric_mem_if.resp_payload.err = {1'b0, data_err_i};
  assign fabric_mem_if.resp_payload.exokay = data_exokay_i;

  // DMA请求按地址分发到A/B SPM。adapter负责32bit与4个8bit bank之间
  // 的拆分/拼接，并为同步读数据生成响应valid。
  logic a_dma_valid, a_dma_ready, b_dma_valid, b_dma_ready;
  logic c_dma_valid, c_dma_ready;
  logic a_dma_we, b_dma_we, c_dma_we;
  logic [31:0] a_dma_addr, a_dma_wdata, b_dma_addr, b_dma_wdata;
  logic [31:0] c_dma_addr, c_dma_wdata;
  logic a_dma_rsp_ready, a_dma_rsp_valid;
  logic b_dma_rsp_ready, b_dma_rsp_valid;
  logic c_dma_rsp_ready, c_dma_rsp_valid;
  logic [31:0] a_dma_rsp_rdata, b_dma_rsp_rdata, c_dma_rsp_rdata;
  logic unused_bad_spm_addr;
  logic [7:0] a_spm_wen, b_spm_wen;
  logic [$clog2(SPM_DEPTH)-1:0] a_spm_waddr, b_spm_waddr;
  logic [7:0] a_spm_wdata [0:7];
  logic [7:0] b_spm_wdata [0:7];

  logic [7:0] a_dma_ren, b_dma_ren;
  logic [$clog2(SPM_DEPTH)-1:0] a_dma_raddr, b_dma_raddr;
  logic [7:0] a_ctrl_ren, b_ctrl_ren;
  logic [$clog2(SPM_DEPTH)-1:0] a_ctrl_raddr, b_ctrl_raddr;
  logic [7:0] a_spm_ren, b_spm_ren;
  logic [$clog2(SPM_DEPTH)-1:0] a_spm_raddr, b_spm_raddr;
  logic [7:0] a_spm_rdata [0:7];
  logic [7:0] b_spm_rdata [0:7];
  logic systolic_controller_busy;
  logic a_adapter_valid, a_adapter_ready;
  logic b_adapter_valid, b_adapter_ready;
  logic c_adapter_valid, c_adapter_ready;

  spm_write_router #(
    .A_SPM_BASE(A_SPM_BASE), .B_SPM_BASE(B_SPM_BASE),
    .C_SPM_BASE(C_SPM_BASE),
    .SPM_SIZE_BYTES(8 * SPM_DEPTH)
  ) spm_write_router_i (
    .clk(clk_i), .rst_n(rst_ni),
    .dma_valid_i(dma_spm_valid), .dma_addr_i(dma_spm_addr),
    .dma_we_i(dma_spm_we), .dma_wdata_i(dma_spm_wdata),
    .dma_ready_o(dma_spm_ready),
    .dma_rsp_ready_i(dma_spm_rsp_ready),
    .dma_rsp_valid_o(dma_spm_rsp_valid),
    .dma_rsp_rdata_o(dma_spm_rsp_rdata),
    .invalid_addr_o(unused_bad_spm_addr),
    .a_valid_o(a_dma_valid), .a_addr_o(a_dma_addr), .a_we_o(a_dma_we),
    .a_wdata_o(a_dma_wdata), .a_ready_i(a_dma_ready),
    .a_rsp_ready_o(a_dma_rsp_ready), .a_rsp_valid_i(a_dma_rsp_valid),
    .a_rsp_rdata_i(a_dma_rsp_rdata),
    .b_valid_o(b_dma_valid), .b_addr_o(b_dma_addr), .b_we_o(b_dma_we),
    .b_wdata_o(b_dma_wdata), .b_ready_i(b_dma_ready),
    .b_rsp_ready_o(b_dma_rsp_ready), .b_rsp_valid_i(b_dma_rsp_valid),
    .b_rsp_rdata_i(b_dma_rsp_rdata),
    .c_valid_o(c_dma_valid), .c_addr_o(c_dma_addr), .c_we_o(c_dma_we),
    .c_wdata_o(c_dma_wdata), .c_ready_i(c_dma_ready),
    .c_rsp_ready_o(c_dma_rsp_ready), .c_rsp_valid_i(c_dma_rsp_valid),
    .c_rsp_rdata_i(c_dma_rsp_rdata)
  );

  // A/B的读口由controller独占。adapter本身恒ready，因此必须在它
  // 之前同时门控valid和返回给router的ready，防止被遮蔽的请求误握手。
  assign a_adapter_valid = a_dma_valid && (a_dma_we || !systolic_controller_busy);
  assign a_dma_ready = a_adapter_ready && (a_dma_we || !systolic_controller_busy);
  assign b_adapter_valid = b_dma_valid && (b_dma_we || !systolic_controller_busy);
  assign b_dma_ready = b_adapter_ready && (b_dma_we || !systolic_controller_busy);

  spm_adapter #(.BANK_NUM(8), .BANK_DEPTH(SPM_DEPTH), .DATA_WIDTH(8))
      a_spm_adapter_i (
    .clk(clk_i), .rst_n(rst_ni),
    .spm_req_valid(a_adapter_valid), .spm_req_addr(a_dma_addr),
    .spm_req_we(a_dma_we), .spm_req_wdata(a_dma_wdata),
    .spm_req_ready(a_adapter_ready), .spm_rsp_ready(a_dma_rsp_ready),
    .spm_rsp_valid(a_dma_rsp_valid), .spm_rsp_rdata(a_dma_rsp_rdata),
    .wen(a_spm_wen), .waddr(a_spm_waddr), .wdata(a_spm_wdata),
    .ren(a_dma_ren), .raddr(a_dma_raddr), .rdata(a_spm_rdata)
  );
  spm_adapter #(.BANK_NUM(8), .BANK_DEPTH(SPM_DEPTH), .DATA_WIDTH(8))
      b_spm_adapter_i (
    .clk(clk_i), .rst_n(rst_ni),
    .spm_req_valid(b_adapter_valid), .spm_req_addr(b_dma_addr),
    .spm_req_we(b_dma_we), .spm_req_wdata(b_dma_wdata),
    .spm_req_ready(b_adapter_ready), .spm_rsp_ready(b_dma_rsp_ready),
    .spm_rsp_valid(b_dma_rsp_valid), .spm_rsp_rdata(b_dma_rsp_rdata),
    .wen(b_spm_wen), .waddr(b_spm_waddr), .wdata(b_spm_wdata),
    .ren(b_dma_ren), .raddr(b_dma_raddr), .rdata(b_spm_rdata)
  );

  // controller工作期间独占SPM读口；DMA读请求会在adapter处看到
  // ready=0。DMA写口与controller读口独立，仍可并行工作。
  always_comb begin
    a_spm_ren   = a_ctrl_ren;
    a_spm_raddr = a_ctrl_raddr;
    b_spm_ren   = b_ctrl_ren;
    b_spm_raddr = b_ctrl_raddr;

    if (!systolic_controller_busy && (|a_dma_ren)) begin
      a_spm_ren   = a_dma_ren;
      a_spm_raddr = a_dma_raddr;
    end
    if (!systolic_controller_busy && (|b_dma_ren)) begin
      b_spm_ren   = b_dma_ren;
      b_spm_raddr = b_dma_raddr;
    end
  end

  scratchpad #(.BANK_NUM(8), .BANK_DEPTH(SPM_DEPTH), .DATA_WIDTH(8)) a_spm_i (
    .clk(clk_i), .rst_n(rst_ni),
    .wen(a_spm_wen), .waddr(a_spm_waddr), .wdata(a_spm_wdata),
    .ren(a_spm_ren), .raddr(a_spm_raddr), .rdata(a_spm_rdata)
  );
  scratchpad #(.BANK_NUM(8), .BANK_DEPTH(SPM_DEPTH), .DATA_WIDTH(8)) b_spm_i (
    .clk(clk_i), .rst_n(rst_ni),
    .wen(b_spm_wen), .waddr(b_spm_waddr), .wdata(b_spm_wdata),
    .ren(b_spm_ren), .raddr(b_spm_raddr), .rdata(b_spm_rdata)
  );

  // C_SPM：每个bank保存一个32位累加结果；线性地址中的word低3位
  // 选择列bank，其余位选择row。
  logic [7:0] c_dma_wen, c_dma_ren;
  logic [$clog2(SPM_DEPTH)-1:0] c_dma_waddr, c_dma_raddr;
  logic [31:0] c_dma_bank_wdata [0:7];
  logic [31:0] c_spm_rdata [0:7];
  logic [7:0] c_result_wen;
  logic [$clog2(SPM_DEPTH)-1:0] c_result_waddr;
  logic [31:0] c_result_wdata [0:7];
  logic [7:0] c_spm_wen;
  logic [$clog2(SPM_DEPTH)-1:0] c_spm_waddr;
  logic [31:0] c_spm_wdata [0:7];

  assign c_adapter_valid = c_dma_valid && !systolic_controller_busy;
  assign c_dma_ready = c_adapter_ready && !systolic_controller_busy;

  spm_adapter #(
    .BANK_NUM(8), .BANK_DEPTH(SPM_DEPTH), .DATA_WIDTH(32)
  ) c_spm_adapter_i (
    .clk(clk_i), .rst_n(rst_ni),
    .spm_req_valid(c_adapter_valid), .spm_req_addr(c_dma_addr),
    .spm_req_we(c_dma_we), .spm_req_wdata(c_dma_wdata),
    .spm_req_ready(c_adapter_ready),
    .spm_rsp_ready(c_dma_rsp_ready), .spm_rsp_valid(c_dma_rsp_valid),
    .spm_rsp_rdata(c_dma_rsp_rdata),
    .wen(c_dma_wen), .waddr(c_dma_waddr), .wdata(c_dma_bank_wdata),
    .ren(c_dma_ren), .raddr(c_dma_raddr), .rdata(c_spm_rdata)
  );

  always_comb begin
    c_spm_wen   = c_dma_wen;
    c_spm_waddr = c_dma_waddr;
    for (int i = 0; i < 8; i++)
      c_spm_wdata[i] = c_dma_bank_wdata[i];

    if (|c_result_wen) begin
      c_spm_wen   = c_result_wen;
      c_spm_waddr = c_result_waddr;
      for (int i = 0; i < 8; i++)
        c_spm_wdata[i] = c_result_wdata[i];
    end
  end

  scratchpad #(.BANK_NUM(8), .BANK_DEPTH(SPM_DEPTH), .DATA_WIDTH(32)) c_spm_i (
    .clk(clk_i), .rst_n(rst_ni),
    .wen(c_spm_wen), .waddr(c_spm_waddr), .wdata(c_spm_wdata),
    .ren(c_dma_ren), .raddr(c_dma_raddr), .rdata(c_spm_rdata)
  );

  accelerator_ctl accelerator_ctl_i (
    .clk           (clk_i),
    .rst_n         (rst_ni),

    .sa_issue      (xif.coproc_issue),
    .sa_commit     (xif.coproc_commit),
    .sa_mem        (xif.coproc_mem),
    .sa_mem_result (xif.coproc_mem_result),
    .sa_result     (xif.coproc_result),

    .npu_cmd_valid_o  (npu_cmd_valid),
    .npu_cmd_ready_i  (npu_cmd_ready),
    .npu_cmd_opcode_o (npu_cmd_opcode),
    .npu_cmd_arg0_o   (npu_cmd_arg0),
    .npu_cmd_arg1_o   (npu_cmd_arg1),
    .npu_rsp_valid_i  (npu_rsp_valid),
    .npu_rsp_ready_o  (npu_rsp_ready),
    .npu_rsp_data_i   (npu_rsp_data),
    .npu_rsp_error_i  (npu_rsp_error)
  );

  logic array_en, array_clear;
  dataflow_e array_dataflow;
  prop_mode_e array_prop_mode;
  logic [7:0] array_a_valid, array_b_valid, array_c_valid;
  logic signed [7:0]  array_row_input [0:7];
  logic signed [31:0] array_b_input [0:7];
  logic signed [31:0] array_d_input [0:7];
  logic signed [31:0] array_result_data [0:7];
  logic [7:0] array_result_valid;
  logic result_writer_start;
  logic [$clog2(SPM_DEPTH)-1:0] result_writer_base;

  systolic_controller #(
    .ARRAY_DIM (8),
    .SPM_DEPTH (SPM_DEPTH)
  ) systolic_controller_i (
    .clk              (clk_i),
    .rst_n            (rst_ni),
    .cmd_valid_i      (npu_cmd_valid),
    .cmd_ready_o      (npu_cmd_ready),
    .cmd_opcode_i     (npu_cmd_opcode),
    .cmd_arg0_i       (npu_cmd_arg0),
    .cmd_arg1_i       (npu_cmd_arg1),
    .rsp_valid_o      (npu_rsp_valid),
    .rsp_ready_i      (npu_rsp_ready),
    .rsp_data_o       (npu_rsp_data),
    .rsp_error_o      (npu_rsp_error),
    .busy_o           (systolic_controller_busy),
    .done_o           (),
    .error_o          (),
    .a_spm_ren_o      (a_ctrl_ren),
    .a_spm_raddr_o    (a_ctrl_raddr),
    .a_spm_rdata_i    (a_spm_rdata),
    .b_spm_ren_o      (b_ctrl_ren),
    .b_spm_raddr_o    (b_ctrl_raddr),
    .b_spm_rdata_i    (b_spm_rdata),
    .array_en_o       (array_en),
    .array_clear_o    (array_clear),
    .array_dataflow_o (array_dataflow),
    .array_prop_mode_o(array_prop_mode),
    .array_a_valid_o  (array_a_valid),
    .array_b_valid_o  (array_b_valid),
    .array_c_valid_o  (array_c_valid),
    .array_row_input_o(array_row_input),
    .array_b_input_o  (array_b_input),
    .array_d_input_o  (array_d_input),
    .array_result_data_i(array_result_data),
    .array_result_valid_i(array_result_valid),
    .result_base_o    (result_writer_base),
    .result_start_o   (result_writer_start)
  );

  systolic_array #(.DIM(8), .INPUT_WIDTH(8), .ACC_WIDTH(32)) systolic_array_i (
    .clk(clk_i), .rst_n(rst_ni), .en(array_en), .clear(array_clear),
    .a_valid(array_a_valid), .b_valid(array_b_valid),
    .c_valid(array_c_valid), .row_input(array_row_input),
    .col_input(array_b_input), .d_input(array_d_input),
    .prop_mode(array_prop_mode), .dataflow(array_dataflow),
    .result_data(array_result_data), .result_valid(array_result_valid)
  );

  c_spm_result_writer #(.ARRAY_DIM(8), .SPM_DEPTH(SPM_DEPTH), .ACC_WIDTH(32))
      c_spm_result_writer_i (
    .clk(clk_i), .rst_n(rst_ni),
    .start_i(result_writer_start), .base_row_i(result_writer_base),
    .result_valid_i(array_result_valid), .result_data_i(array_result_data),
    .wen_o(c_result_wen), .waddr_o(c_result_waddr), .wdata_o(c_result_wdata)
  );

  // 当前不支持XIF压缩指令。
  assign xif.compressed_ready = 1'b0;
  assign xif.compressed_resp  = '0;
  // assign xif.issue_ready      = 1'b0;
  // assign xif.issue_resp       = '0;
  // assign xif.mem_valid        = 1'b0;
  // assign xif.mem_req          = '0;
  // assign xif.result_valid     = 1'b0;
  // assign xif.result           = '0;

  cv32e40x_core #(
    .X_EXT (1'b1),
    .M_EXT (M),
    .DEBUG (1'b0)
  ) core (
    .clk_i,
    .rst_ni,
    .scan_cg_en_i,
    .boot_addr_i,
    .dm_exception_addr_i,
    .dm_halt_addr_i,
    .mhartid_i,
    .mimpid_patch_i,
    .mtvec_addr_i,
    .instr_req_o,
    .instr_gnt_i,
    .instr_rvalid_i,
    .instr_addr_o,
    .instr_memtype_o,
    .instr_prot_o,
    .instr_dbg_o,
    .instr_rdata_i,
    .instr_err_i,
    .data_req_o       (core_data_req),
    .data_gnt_i       (core_data_gnt),
    .data_rvalid_i    (core_data_rvalid),
    .data_addr_o      (core_data_addr),
    .data_be_o        (core_data_be),
    .data_we_o        (core_data_we),
    .data_wdata_o     (core_data_wdata),
    .data_memtype_o   (core_data_memtype),
    .data_prot_o      (core_data_prot),
    .data_dbg_o       (core_data_dbg),
    .data_atop_o      (core_data_atop),
    .data_rdata_i     (core_data_rdata),
    .data_err_i       (core_data_err),
    .data_exokay_i    (core_data_exokay),
    .mcycle_o,
    .time_i,
    .xif_compressed_if (xif.cpu_compressed),
    .xif_issue_if      (xif.cpu_issue),
    .xif_commit_if     (xif.cpu_commit),
    .xif_mem_if        (xif.cpu_mem),
    .xif_mem_result_if (xif.cpu_mem_result),
    .xif_result_if     (xif.cpu_result),
    .irq_i,
    .wu_wfe_i,
    .clic_irq_i,
    .clic_irq_id_i,
    .clic_irq_level_i,
    .clic_irq_priv_i,
    .clic_irq_shv_i,
    .fencei_flush_req_o,
    .fencei_flush_ack_i,
    .debug_req_i,
    .debug_havereset_o,
    .debug_running_o,
    .debug_halted_o,
    .debug_pc_valid_o,
    .debug_pc_o,
    .fetch_enable_i,
    .core_sleep_o
  );

endmodule
