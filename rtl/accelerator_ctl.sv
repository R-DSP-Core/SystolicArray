// SPDX-License-Identifier: Apache-2.0

//==============================================================================
// CV32E40X XIF -> systolic controller 命令前端
//
// 本模块只负责“CPU/XIF协议”和“自定义指令译码”，不负责脉动阵列的逐周期
// 控制。译码后的命令通过 npu_cmd_* 交给 systolic_controller：
//
//   CV32E40X XIF
//       -> accelerator_ctl（本模块：issue/commit/result）
//       -> systolic_controller（cmd/rsp、SPM与阵列控制）
//
// 当前一次只允许一条XIF指令在途，符合第一版顺序、阻塞式控制器的目标。
//==============================================================================

module accelerator_ctl import cv32e40x_pkg::*;
(
  input logic clk,
  input logic rst_n,

  cv32e40x_if_xif.coproc_issue      sa_issue,
  cv32e40x_if_xif.coproc_commit     sa_commit,
  cv32e40x_if_xif.coproc_mem        sa_mem,
  cv32e40x_if_xif.coproc_mem_result sa_mem_result,
  cv32e40x_if_xif.coproc_result     sa_result,

  // 译码后送往 systolic_controller 的顺序命令接口。
  output logic        npu_cmd_valid_o,
  input  logic        npu_cmd_ready_i,
  output logic [2:0]  npu_cmd_opcode_o,
  output logic [31:0] npu_cmd_arg0_o,
  output logic [31:0] npu_cmd_arg1_o,

  // systolic_controller 的命令完成响应。
  input  logic        npu_rsp_valid_i,
  output logic        npu_rsp_ready_o,
  input  logic [31:0] npu_rsp_data_i,
  input  logic        npu_rsp_error_i
);

  // --------------------------------------------------------------------------
  // 自定义指令编码
  // --------------------------------------------------------------------------
  // R-type：
  //
  //   .insn r CUSTOM_0, funct3, funct7, rd, rs1, rs2
  //
  // NPU命令统一使用 opcode=CUSTOM_0、funct3=0，funct7选择具体命令：
  //
  //   funct7=0  CONFIG       rs1=M维运行长度（A_SPM行数），rs2=模式标志
  //   funct7=1  LOAD_WEIGHT  rs1=B_SPM起始row，rs2=row数量
  //   funct7=2  COMPUTE      rs1=A_SPM起始row，rs2=C_SPM起始row
  //   funct7=3  WAIT         rs1/rs2保留
  //
  // funct3=1、funct7=2的旧custom-add暂时保留，以免破坏已有hello程序。
  localparam logic [6:0] CUSTOM_0_OPCODE = 7'h0b;
  localparam logic [2:0] NPU_FUNCT3       = 3'd0;

  localparam logic [6:0] NPU_FUNCT7_CONFIG      = 7'd0;
  localparam logic [6:0] NPU_FUNCT7_LOAD_WEIGHT = 7'd1;
  localparam logic [6:0] NPU_FUNCT7_COMPUTE     = 7'd2;
  localparam logic [6:0] NPU_FUNCT7_WAIT        = 7'd3;

  localparam logic [2:0] CMD_CONFIG      = 3'd0;
  localparam logic [2:0] CMD_LOAD_WEIGHT = 3'd1;
  localparam logic [2:0] CMD_COMPUTE     = 3'd2;
  localparam logic [2:0] CMD_WAIT        = 3'd3;

  localparam logic [2:0] LEGACY_ADD_FUNCT3 = 3'd1;
  localparam logic [6:0] LEGACY_ADD_FUNCT7 = 7'd2;

  typedef enum logic [2:0] {
    XIF_IDLE,
    XIF_WAIT_COMMIT,
    XIF_DISPATCH,
    XIF_WAIT_NPU_RESPONSE,
    XIF_EXECUTE_LEGACY_ADD,
    XIF_SEND_RESULT
  } xif_state_e;

  xif_state_e state_q;

  logic [3:0]  instruction_id_q;
  logic [4:0]  destination_q;
  logic [2:0]  command_opcode_q;
  logic [31:0] operand_a_q;
  logic [31:0] operand_b_q;
  logic [31:0] result_q;
  logic        legacy_add_q;

  logic recognized_instruction;
  logic decoded_legacy_add;
  logic decoded_npu_command;
  logic [2:0] decoded_command_opcode;
  logic issue_handshake;
  logic command_handshake;
  logic response_handshake;
  logic result_handshake;

  // --------------------------------------------------------------------------
  // Issue译码
  // --------------------------------------------------------------------------
  always_comb begin
    decoded_npu_command    = 1'b0;
    decoded_legacy_add     = 1'b0;
    decoded_command_opcode = CMD_CONFIG;

    if ((sa_issue.issue_req.instr[6:0] == CUSTOM_0_OPCODE) &&
        (sa_issue.issue_req.instr[14:12] == NPU_FUNCT3)) begin
      unique case (sa_issue.issue_req.instr[31:25])
        NPU_FUNCT7_CONFIG: begin
          decoded_npu_command    = 1'b1;
          decoded_command_opcode = CMD_CONFIG;
        end
        NPU_FUNCT7_LOAD_WEIGHT: begin
          decoded_npu_command    = 1'b1;
          decoded_command_opcode = CMD_LOAD_WEIGHT;
        end
        NPU_FUNCT7_COMPUTE: begin
          decoded_npu_command    = 1'b1;
          decoded_command_opcode = CMD_COMPUTE;
        end
        NPU_FUNCT7_WAIT: begin
          decoded_npu_command    = 1'b1;
          decoded_command_opcode = CMD_WAIT;
        end
        default: begin
        end
      endcase
    end

    decoded_legacy_add =
        (sa_issue.issue_req.instr[6:0]   == CUSTOM_0_OPCODE) &&
        (sa_issue.issue_req.instr[14:12] == LEGACY_ADD_FUNCT3) &&
        (sa_issue.issue_req.instr[31:25] == LEGACY_ADD_FUNCT7);
  end

  assign recognized_instruction = decoded_npu_command || decoded_legacy_add;

  // 只有IDLE能够保存一条新指令。对于不认识的指令，ready仍可拉高，但
  // accept保持0，让CPU继续走非法指令/其他扩展的处理路径。
  assign sa_issue.issue_ready = (state_q == XIF_IDLE);
  assign issue_handshake = sa_issue.issue_valid && sa_issue.issue_ready;

  always_comb begin
    sa_issue.issue_resp = '0;
    if (recognized_instruction) begin
      sa_issue.issue_resp.accept    = 1'b1;
      sa_issue.issue_resp.writeback = 1'b1;
      sa_issue.issue_resp.dualwrite = 1'b0;
      sa_issue.issue_resp.dualread  = 3'b000;
      sa_issue.issue_resp.loadstore = 1'b0;
      sa_issue.issue_resp.ecswrite  = 1'b0;
      sa_issue.issue_resp.exc       = 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // 下游命令接口
  // --------------------------------------------------------------------------
  // 在收到commit_kill=0之前不允许把命令交给controller，因为SPM写入、阵列
  // 启动等都属于不能由被kill指令留下的副作用。
  assign npu_cmd_valid_o  = (state_q == XIF_DISPATCH);
  assign npu_cmd_opcode_o = command_opcode_q;
  assign npu_cmd_arg0_o   = operand_a_q;
  assign npu_cmd_arg1_o   = operand_b_q;
  assign command_handshake = npu_cmd_valid_o && npu_cmd_ready_i;

  assign npu_rsp_ready_o = (state_q == XIF_WAIT_NPU_RESPONSE);
  assign response_handshake = npu_rsp_valid_i && npu_rsp_ready_o;

  // 当前NPU命令不通过XIF memory通道访存；矩阵搬运由独立DMA完成。
  assign sa_mem.mem_valid = 1'b0;
  assign sa_mem.mem_req   = '0;

  // mem_result是输入通道，当前没有XIF memory请求，因此无需使用。
  logic unused_mem_result;
  assign unused_mem_result = sa_mem_result.mem_result_valid |
                             (|sa_mem_result.mem_result);

  // --------------------------------------------------------------------------
  // Result通道
  // --------------------------------------------------------------------------
  assign sa_result.result_valid = (state_q == XIF_SEND_RESULT);
  assign result_handshake = sa_result.result_valid && sa_result.result_ready;

  always_comb begin
    sa_result.result         = '0;
    sa_result.result.id      = instruction_id_q;
    sa_result.result.data    = result_q;
    sa_result.result.rd      = destination_q;
    sa_result.result.we      = 1'b1;
    sa_result.result.ecsdata = '0;
    sa_result.result.ecswe   = '0;
    sa_result.result.exc     = 1'b0;
    sa_result.result.exccode = '0;
    sa_result.result.err     = 1'b0;
    sa_result.result.dbg     = 1'b0;
  end

  // --------------------------------------------------------------------------
  // 顺序、单在途XIF状态机
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q           <= XIF_IDLE;
      instruction_id_q  <= '0;
      destination_q     <= '0;
      command_opcode_q  <= CMD_CONFIG;
      operand_a_q       <= '0;
      operand_b_q       <= '0;
      result_q          <= '0;
      legacy_add_q      <= 1'b0;
    end else begin
      unique case (state_q)
        XIF_IDLE: begin
          if (issue_handshake && recognized_instruction) begin
            instruction_id_q <= sa_issue.issue_req.id;
            destination_q    <= sa_issue.issue_req.instr[11:7];
            command_opcode_q <= decoded_command_opcode;
            operand_a_q      <= sa_issue.issue_req.rs[0];
            operand_b_q      <= sa_issue.issue_req.rs[1];
            legacy_add_q     <= decoded_legacy_add;
            state_q          <= XIF_WAIT_COMMIT;
          end
        end

        XIF_WAIT_COMMIT: begin
          if (sa_commit.commit_valid &&
              (sa_commit.commit.id == instruction_id_q)) begin
            if (sa_commit.commit.commit_kill) begin
              // 被kill的指令从未发送给下游，因此不会留下NPU副作用。
              state_q <= XIF_IDLE;
            end else if (legacy_add_q) begin
              state_q <= XIF_EXECUTE_LEGACY_ADD;
            end else begin
              state_q <= XIF_DISPATCH;
            end
          end
        end

        XIF_DISPATCH: begin
          if (command_handshake)
            state_q <= XIF_WAIT_NPU_RESPONSE;
        end

        XIF_WAIT_NPU_RESPONSE: begin
          if (response_handshake) begin
            // controller参数错误不是XIF总线错误，用返回值最高位表示失败，
            // 低31位保留controller给出的错误码。
            if (npu_rsp_error_i)
              result_q <= 32'h8000_0000 | npu_rsp_data_i;
            else
              result_q <= npu_rsp_data_i;
            state_q <= XIF_SEND_RESULT;
          end
        end

        XIF_EXECUTE_LEGACY_ADD: begin
          result_q <= operand_a_q + operand_b_q;
          state_q  <= XIF_SEND_RESULT;
        end

        XIF_SEND_RESULT: begin
          if (result_handshake)
            state_q <= XIF_IDLE;
        end

        default: begin
          state_q <= XIF_IDLE;
        end
      endcase
    end
  end

endmodule
