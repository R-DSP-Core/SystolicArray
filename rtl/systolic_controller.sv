// Copyright (c) 2026
//
// Systolic Array 基础控制器
//
// 设计边界：
//   1. 上游不是直接连接CV32E40X XIF，而是一个简单的命令握手接口。
//      后续可以由独立的XIF frontend负责issue/commit/id/result协议，并把
//      已经commit的命令转换为本模块的cmd_*接口。
//   2. 本模块负责产生SPM读请求、等待同步读响应，并控制阵列的
//      clear/enable/dataflow/prop_mode。
//   3. 当前版本只提供最基础的WS/OS控制时序框架，尚未实现输入skew、
//      输出valid追踪和C_SPM结果写回；这些功能适合分别放到feeder和
//      result writer中。

module systolic_controller import cv32e40x_pkg::*;
#(
    parameter int unsigned ARRAY_DIM       = DIM,
    parameter int unsigned INPUT_WIDTH     = 8,
    parameter int unsigned ACC_WIDTH       = 32,
    parameter int unsigned SPM_DEPTH       = 256,

    // 最后一组输入送入阵列以后继续推进多少周期。
    // 这是基础版本的保守占位值；最终应由valid流水线/Result Writer给出
    // 真正的计算完成条件，而不是只依靠固定周期。
    parameter int unsigned DRAIN_CYCLES    = 2 * ARRAY_DIM
)(
    input  logic clk,
    input  logic rst_n,

    // ------------------------------------------------------------------
    // 上游命令接口（由未来的XIF frontend或者testbench驱动）
    // ------------------------------------------------------------------
    input  logic        cmd_valid_i,
    output logic        cmd_ready_o,
    input  logic [2:0]  cmd_opcode_i,
    input  logic [31:0] cmd_arg0_i,
    input  logic [31:0] cmd_arg1_i,

    // 命令完成响应。rsp_valid置位后，在rsp_ready到来前保持响应稳定。
    output logic        rsp_valid_o,
    input  logic        rsp_ready_i,
    output logic [31:0] rsp_data_o,
    output logic        rsp_error_o,

    output logic        busy_o,
    output logic        done_o,
    output logic        error_o,

    // ------------------------------------------------------------------
    // A_SPM同步读口：bank i应保存A[i][k]，所有bank共享row地址k。
    // ------------------------------------------------------------------
    output logic [ARRAY_DIM-1:0]                 a_spm_ren_o,
    output logic [$clog2(SPM_DEPTH)-1:0]         a_spm_raddr_o,
    input  logic [INPUT_WIDTH-1:0]               a_spm_rdata_i [0:ARRAY_DIM-1],

    // ------------------------------------------------------------------
    // B_SPM同步读口：bank j应保存B[k][j]，所有bank共享row地址k。
    // ------------------------------------------------------------------
    output logic [ARRAY_DIM-1:0]                 b_spm_ren_o,
    output logic [$clog2(SPM_DEPTH)-1:0]         b_spm_raddr_o,
    input  logic [INPUT_WIDTH-1:0]               b_spm_rdata_i [0:ARRAY_DIM-1],

    // ------------------------------------------------------------------
    // 阵列控制与边界输入
    // 这些端口直接连接systolic_array的enable、clear、valid和边界数据。
    // b_input和d_input分开，是因为WS下二者分别表示部分和与权重装载。
    // ------------------------------------------------------------------
    output logic                                  array_en_o,
    output logic                                  array_clear_o,
    output dataflow_e                             array_dataflow_o,
    output prop_mode_e                            array_prop_mode_o,
    output logic [ARRAY_DIM-1:0]                  array_a_valid_o,
    output logic [ARRAY_DIM-1:0]                  array_b_valid_o,
    output logic [ARRAY_DIM-1:0]                  array_c_valid_o,
    output logic signed [INPUT_WIDTH-1:0]         array_row_input_o [0:ARRAY_DIM-1],
    output logic signed [ACC_WIDTH-1:0]           array_b_input_o   [0:ARRAY_DIM-1],
    output logic signed [ACC_WIDTH-1:0]           array_d_input_o   [0:ARRAY_DIM-1],

    // 在尚未加入C_SPM前，由阵列底边返回结果。控制器计算所有有效
    // 结果的32位校验和，并将其作为COMPUTE命令响应，供软件端到端验证。
    input  logic signed [ACC_WIDTH-1:0]           array_result_data_i [0:ARRAY_DIM-1],
    input  logic [ARRAY_DIM-1:0]                  array_result_valid_i,

    // COMPUTE命令提供的C_SPM起始row，交给未来的Result Writer使用。
    output logic [$clog2(SPM_DEPTH)-1:0]          result_base_o,
    output logic                                  result_start_o
);

    localparam int unsigned SPM_ADDR_WIDTH = $clog2(SPM_DEPTH);
    localparam int unsigned DRAIN_WIDTH =
        (DRAIN_CYCLES <= 1) ? 1 : $clog2(DRAIN_CYCLES + 1);

    // 基础命令编码。XIF frontend只需要把自定义指令译码成这些命令。
    localparam logic [2:0] CMD_CONFIG      = 3'd0;
    localparam logic [2:0] CMD_LOAD_WEIGHT = 3'd1;
    localparam logic [2:0] CMD_COMPUTE     = 3'd2;
    localparam logic [2:0] CMD_WAIT        = 3'd3;

    typedef enum logic [3:0] {
        CTRL_IDLE,
        CTRL_CLEAR,
        CTRL_WEIGHT_REQ,
        CTRL_WEIGHT_WAIT,
        CTRL_WEIGHT_FEED,
        CTRL_COMPUTE_REQ,
        CTRL_COMPUTE_WAIT,
        CTRL_COMPUTE_FEED,
        CTRL_DRAIN,
        CTRL_RESPONSE
    } ctrl_state_e;

    ctrl_state_e state_q, state_d;

    // 当前A_SPM按“一个矩阵行对应一个SPM row”布局，因此该寄存器表示
    // 一次COMPUTE需要读取并送入阵列的A矩阵行数，也就是M维运行长度。
    logic [31:0] m_size_q;
    logic [31:0] remaining_q;
    logic [SPM_ADDR_WIDTH-1:0] weight_addr_q;
    logic [SPM_ADDR_WIDTH-1:0] activation_addr_q;
    logic [SPM_ADDR_WIDTH-1:0] result_base_q;
    logic [DRAIN_WIDTH-1:0] drain_count_q;

    dataflow_e  dataflow_q;
    prop_mode_e prop_mode_q;

    logic [31:0] rsp_data_q;
    logic        rsp_error_q;
    logic [31:0] result_sum_q;
    logic [31:0] result_cycle_sum;
    logic        result_start_q;

    logic cmd_fire;

    assign cmd_fire = cmd_valid_i && cmd_ready_o;

    assign cmd_ready_o = (state_q == CTRL_IDLE);
    assign rsp_valid_o = (state_q == CTRL_RESPONSE);
    assign rsp_data_o  = rsp_data_q;
    assign rsp_error_o = rsp_error_q;

    assign busy_o  = (state_q != CTRL_IDLE);
    assign done_o  = (state_q == CTRL_RESPONSE) && !rsp_error_q;
    assign error_o = (state_q == CTRL_RESPONSE) && rsp_error_q;

    assign array_dataflow_o  = dataflow_q;
    assign array_prop_mode_o = prop_mode_q;
    assign result_base_o     = result_base_q;
    assign result_start_o    = result_start_q;

    always_comb begin
        result_cycle_sum = '0;
        for (int result_lane = 0; result_lane < ARRAY_DIM; result_lane++) begin
            if (array_result_valid_i[result_lane])
                result_cycle_sum = result_cycle_sum + array_result_data_i[result_lane];
        end
    end

    // ------------------------------------------------------------------
    // 状态转移
    // ------------------------------------------------------------------
    always_comb begin
        state_d = state_q;

        unique case (state_q)
            CTRL_IDLE: begin
                if (cmd_fire) begin
                    unique case (cmd_opcode_i)
                        CMD_CONFIG: begin
                            state_d = CTRL_RESPONSE;
                        end

                        CMD_LOAD_WEIGHT: begin
                            // 非法参数同样进入RESPONSE，由rsp_error说明失败。
                            if ((cmd_arg1_i == 0) ||
                                (cmd_arg1_i > ARRAY_DIM) ||
                                (cmd_arg0_i >= SPM_DEPTH) ||
                                (cmd_arg1_i > SPM_DEPTH) ||
                                (cmd_arg0_i > SPM_DEPTH - cmd_arg1_i))
                                state_d = CTRL_RESPONSE;
                            else
                                state_d = CTRL_CLEAR;
                        end

                        CMD_COMPUTE: begin
                            if ((m_size_q == 0) ||
                                (cmd_arg0_i >= SPM_DEPTH) ||
                                (m_size_q > SPM_DEPTH) ||
                                (cmd_arg0_i > SPM_DEPTH - m_size_q) ||
                                (cmd_arg1_i >= SPM_DEPTH))
                                state_d = CTRL_RESPONSE;
                            else
                                state_d = CTRL_COMPUTE_REQ;
                        end

                        CMD_WAIT: begin
                            // 本基础控制器一次只接受一个阻塞命令，因此能接受
                            // WAIT时已经处于IDLE，可立即成功响应。
                            state_d = CTRL_RESPONSE;
                        end

                        default: begin
                            state_d = CTRL_RESPONSE;
                        end
                    endcase
                end
            end

            // 在装载新权重之前清除PE内部旧状态。
            CTRL_CLEAR: begin
                state_d = CTRL_WEIGHT_REQ;
            end

            // scratchpad没有read-ready，因此REQ状态拉高ren一个周期即可。
            CTRL_WEIGHT_REQ: begin
                state_d = CTRL_WEIGHT_WAIT;
            end

            CTRL_WEIGHT_WAIT: begin
                // scratchpad为固定一周期同步读：REQ上升沿后数据已写入
                // rdata，WAIT提供一个明确的时序边界，下一状态即可消费。
                state_d = CTRL_WEIGHT_FEED;
            end

            CTRL_WEIGHT_FEED: begin
                if (remaining_q == 32'd1)
                    state_d = CTRL_RESPONSE;
                else
                    state_d = CTRL_WEIGHT_REQ;
            end

            CTRL_COMPUTE_REQ: begin
                state_d = CTRL_COMPUTE_WAIT;
            end

            CTRL_COMPUTE_WAIT: begin
                state_d = CTRL_COMPUTE_FEED;
            end

            CTRL_COMPUTE_FEED: begin
                if (remaining_q == 32'd1)
                    state_d = CTRL_DRAIN;
                else
                    state_d = CTRL_COMPUTE_REQ;
            end

            CTRL_DRAIN: begin
                if (drain_count_q <= DRAIN_WIDTH'(1))
                    state_d = CTRL_RESPONSE;
            end

            CTRL_RESPONSE: begin
                if (rsp_ready_i)
                    state_d = CTRL_IDLE;
            end

            default: begin
                state_d = CTRL_IDLE;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // 数据寄存器、地址生成器和响应状态
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q           <= CTRL_IDLE;
            m_size_q          <= '0;
            remaining_q       <= '0;
            weight_addr_q     <= '0;
            activation_addr_q <= '0;
            result_base_q     <= '0;
            drain_count_q     <= '0;
            dataflow_q        <= WEIGHT_STATIONARY;
            prop_mode_q       <= COMPUTE;
            rsp_data_q        <= '0;
            rsp_error_q       <= 1'b0;
            result_sum_q      <= '0;
            result_start_q    <= 1'b0;
        end else begin
            state_q <= state_d;
            result_start_q <= 1'b0;

            if (cmd_fire) begin
                // 每条新命令先清除上一条命令的响应信息。
                rsp_data_q  <= '0;
                rsp_error_q <= 1'b0;

                unique case (cmd_opcode_i)
                    CMD_CONFIG: begin
                        // arg0：M维运行长度（需要读取的A_SPM row数）；
                        // arg1[0]：dataflow；arg1[1]：prop_mode。
                        if ((cmd_arg0_i == 0) || (cmd_arg0_i > SPM_DEPTH)) begin
                            rsp_error_q <= 1'b1;
                            rsp_data_q  <= 32'h0000_0001;
                        end else begin
                            m_size_q    <= cmd_arg0_i;
                            dataflow_q  <= dataflow_e'(cmd_arg1_i[0]);
                            prop_mode_q <= prop_mode_e'(cmd_arg1_i[1]);
                        end
                    end

                    CMD_LOAD_WEIGHT: begin
                        if ((cmd_arg1_i == 0) ||
                            (cmd_arg1_i > ARRAY_DIM) ||
                            (cmd_arg0_i >= SPM_DEPTH) ||
                            (cmd_arg1_i > SPM_DEPTH) ||
                            (cmd_arg0_i > SPM_DEPTH - cmd_arg1_i)) begin
                            rsp_error_q <= 1'b1;
                            rsp_data_q  <= 32'h0000_0002;
                        end else begin
                            // 权重沿d/c通道从顶部向下装载，因此逆序读取
                            // B_SPM，使B[k][j]最终落到物理第k行。
                            weight_addr_q <= SPM_ADDR_WIDTH'(
                                cmd_arg0_i + cmd_arg1_i - 1'b1
                            );
                            remaining_q   <= cmd_arg1_i;
                        end
                    end

                    CMD_COMPUTE: begin
                        if ((m_size_q == 0) ||
                            (cmd_arg0_i >= SPM_DEPTH) ||
                            (m_size_q > SPM_DEPTH) ||
                            (cmd_arg0_i > SPM_DEPTH - m_size_q) ||
                            (cmd_arg1_i >= SPM_DEPTH)) begin
                            rsp_error_q <= 1'b1;
                            rsp_data_q  <= 32'h0000_0003;
                        end else begin
                            activation_addr_q <= cmd_arg0_i[SPM_ADDR_WIDTH-1:0];
                            result_base_q     <= cmd_arg1_i[SPM_ADDR_WIDTH-1:0];
                            remaining_q       <= m_size_q;
                            result_sum_q      <= '0;
                            result_start_q    <= 1'b1;
                        end
                    end

                    CMD_WAIT: begin
                        rsp_data_q <= 32'h0000_0001;
                    end

                    default: begin
                        rsp_error_q <= 1'b1;
                        rsp_data_q  <= 32'hffff_ffff;
                    end
                endcase
            end

            if (state_q == CTRL_WEIGHT_FEED) begin
                // 权重从阵列顶部向下移动。为了让B[k][j]最终落在物理
                // 第k行，SPM按K-1、K-2...0的顺序读出。
                if (remaining_q != 32'd1)
                    weight_addr_q <= weight_addr_q - 1'b1;
                remaining_q   <= remaining_q - 1'b1;

                if (remaining_q == 32'd1) begin
                    rsp_data_q <= 32'h0000_0001;

                    // WS的一个缓冲器负责通过d/c通道装载权重，另一个
                    // 缓冲器被乘法器使用。装载结束后交换两者角色。
                    if (dataflow_q == WEIGHT_STATIONARY)
                        prop_mode_q <= (prop_mode_q == PROPAGATE) ?
                                       COMPUTE : PROPAGATE;
                end
            end

            if (state_q == CTRL_COMPUTE_FEED) begin
                activation_addr_q <= activation_addr_q + 1'b1;
                remaining_q       <= remaining_q - 1'b1;

                if (remaining_q == 32'd1)
                    drain_count_q <= DRAIN_WIDTH'(DRAIN_CYCLES);
            end

            if ((state_q == CTRL_COMPUTE_REQ) ||
                (state_q == CTRL_COMPUTE_WAIT) ||
                (state_q == CTRL_COMPUTE_FEED) ||
                (state_q == CTRL_DRAIN)) begin
                result_sum_q <= result_sum_q + result_cycle_sum;
            end

            if ((state_q == CTRL_DRAIN) && (drain_count_q != '0)) begin
                drain_count_q <= drain_count_q - 1'b1;

                if (drain_count_q == DRAIN_WIDTH'(1))
                    // 同一拍仍可能出现最后一组结果，因此响应必须包含
                    // 当前拍的result_cycle_sum。
                    rsp_data_q <= result_sum_q + result_cycle_sum;
            end
        end
    end

    // ------------------------------------------------------------------
    // 输出控制
    // ------------------------------------------------------------------
    always_comb begin
        a_spm_ren_o   = '0;
        a_spm_raddr_o = activation_addr_q;
        b_spm_ren_o   = '0;
        b_spm_raddr_o = weight_addr_q;

        array_en_o    = 1'b0;
        array_clear_o = 1'b0;
        array_a_valid_o = '0;
        array_b_valid_o = '0;
        array_c_valid_o = '0;

        for (int i = 0; i < ARRAY_DIM; i++) begin
            array_row_input_o[i] = '0;
            array_b_input_o[i]   = '0;
            array_d_input_o[i]   = '0;
        end

        unique case (state_q)
            CTRL_CLEAR: begin
                array_clear_o = 1'b1;
            end

            CTRL_WEIGHT_REQ: begin
                b_spm_ren_o = '1;
            end

            CTRL_WEIGHT_FEED: begin
                array_en_o = 1'b1;
                // d_input通过c通道逐行装载权重，因此有效位使用c_valid。
                array_c_valid_o = '1;

                // B_SPM保存8位权重，送入32位权重通道时做有符号扩展。
                for (int i = 0; i < ARRAY_DIM; i++) begin
                    array_d_input_o[i] = {
                        {(ACC_WIDTH-INPUT_WIDTH){b_spm_rdata_i[i][INPUT_WIDTH-1]}},
                        b_spm_rdata_i[i]
                    };
                end
            end

            CTRL_COMPUTE_REQ: begin
                a_spm_ren_o = '1;
            end

            CTRL_COMPUTE_FEED: begin
                array_en_o = 1'b1;
                // WS下每个A_SPM bank提供一个K方向激活值，顶部b输入为
                // 零部分和。两类token都必须标记为有效，才能在PE中乘加。
                array_a_valid_o = '1;
                array_b_valid_o = '1;

                for (int i = 0; i < ARRAY_DIM; i++) begin
                    array_row_input_o[i] = $signed(a_spm_rdata_i[i]);
                end
            end

            CTRL_DRAIN: begin
                // 输入置零但继续推进阵列，使在途数据流到底部。
                array_en_o = 1'b1;
            end

            default: begin
            end
        endcase
    end

endmodule
