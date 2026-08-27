

module pe import cv32e40x_pkg::*;
#(
    parameter int unsigned INPUT_WIDTH = 8,
    parameter int unsigned ACC_WIDTH = 32
)
(
    input logic clk,
    input logic rst_n,

    // 使能、清空、有效位
    input logic en_i,
    input logic clear_i,
    input logic a_valid_i,
    input logic b_valid_i,
    input logic c_valid_i,

    output logic a_valid_o,
    output logic b_valid_o,
    output logic c_valid_o,


    // 乘数a，横向传播
    input logic signed [INPUT_WIDTH - 1:0] a_i,

    // 乘数b，在OS下纵向传播，在WS时作为部分和传播
    input logic signed [ACC_WIDTH - 1:0] b_i,

    // OS下作为bias，初始注入驻留寄存器，WS下作为权重装载通道
    input logic signed [ACC_WIDTH - 1:0] d_i,

    // 数据流模式：WS/OS
    input dataflow_e dataflow_i,

    // 寄存器切换信号
    input prop_mode_e prop_mode_i,

    // 无论何种模式，a_o = a_i，即原样输出
    output logic signed [INPUT_WIDTH - 1:0] a_o,

    //
    output logic signed [ACC_WIDTH - 1:0] b_o,
    output logic signed [ACC_WIDTH - 1:0] c_o

);
    // 双缓冲寄存器，用于保存偏置和传播部分和
    logic signed [ACC_WIDTH - 1:0] c1,c2;
    logic c1_valid,c2_valid;
    assign c_o = (prop_mode_i == PROPAGATE) ? c1 : c2;
    assign c_valid_o = (prop_mode_i == PROPAGATE) ? c1_valid : c2_valid;
    always_ff @(posedge clk, negedge rst_n) begin
        if (rst_n == 1'b0) begin
            c1 <= '0;
            c2 <= '0;
            a_o <= '0;
            b_o <= '0;
            a_valid_o <= 1'b0;
            b_valid_o <= 1'b0;

            c1_valid <= 1'b0;
            c2_valid <= 1'b0;
        end
        else if (clear_i == 1'b1) begin
            c1 <= '0;
            c2 <= '0;
            a_o <= '0;
            b_o <= '0;
            a_valid_o <= 1'b0;
            b_valid_o <= 1'b0;

            c1_valid <= 1'b0;
            c2_valid <= 1'b0;
        end
        else if(en_i)begin
            a_o <= a_i;
            a_valid_o <= a_valid_i;
            b_valid_o <= b_valid_i;
            // OS模式下，计算结果驻留在PE内部寄存器，权重（b）纵向传播
            if(dataflow_i == OUTPUT_STATIONARY) begin
                // OS模式下，权重矩阵B有效时无条件传播
                if(b_valid_i)
                    b_o <= b_i;
                if(prop_mode_i == PROPAGATE) begin
                    // PROPAGATE模式下，c1寄存器用来传播偏置，c2寄存器用来存放乘加结果
                    // 只有行列同时有效的情况下才能进行乘加运算
                    if(a_valid_i && b_valid_i) begin
                        c2 <= c2 + a_i * b_i;
                        c2_valid <= 1'b1;
                    end

                    // 偏置有效时传播
                    if(c_valid_i)
                        c1 <= d_i;

                    // 双缓冲式valid传播
                    c1_valid <= c_valid_i;
                end
                else if(prop_mode_i == COMPUTE) begin
                    // COMPUTE模式下，c2寄存器用来传播偏置，c1寄存器用来存放乘加结果
                    if(a_valid_i && b_valid_i) begin
                        c1 <= c1 + a_i * b_i;
                        c1_valid <= 1'b1;
                    end

                    if(c_valid_i)
                        c2 <= d_i;

                    c2_valid <= c_valid_i;
                end
            end
            else if(dataflow_i == WEIGHT_STATIONARY) begin
                // WS模式下，权重矩阵装载在PE中，部分和沿着bi/bo通道移动
                if(prop_mode_i == PROPAGATE) begin
                    // PROPAGATE模式
                    if(b_valid_i) begin
                        // 如果行输入无效，则相当于把行输入视为0，其余数据原样继续传播
                        if(a_valid_i && c2_valid)
                            b_o <= b_i + a_i * c2;
                        else
                            b_o <= b_i;
                    end
                    if(c_valid_i)
                        c1 <= d_i;

                    c1_valid <= c_valid_i;
                end
                else if(prop_mode_i == COMPUTE) begin
                    // COMPUTE模式下，c2寄存器用来传播偏置，c1寄存器用来存放乘加结果
                    if(b_valid_i) begin
                        if(a_valid_i && c1_valid)
                            b_o <= b_i + a_i * c1;
                        else
                            b_o <= b_i;
                    end
                    if(c_valid_i)
                        c2 <= d_i;

                    c2_valid <= c_valid_i;
                end
            end
        end
    end

endmodule
