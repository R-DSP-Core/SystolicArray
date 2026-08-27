
module systolic_array import cv32e40x_pkg::*;
#(
    parameter int DIM = 8,
    parameter int INPUT_WIDTH = 8,
    parameter int ACC_WIDTH = 32

)
(
    input logic clk,
    input logic rst_n,

    // 使能位
    input logic en,
    // 清空位
    input logic clear,

    input logic [DIM-1:0] a_valid,
    input logic [DIM-1:0] b_valid,
    input logic [DIM-1:0] c_valid,

    // 脉动阵列行方向的输入
    input logic signed [INPUT_WIDTH-1:0] row_input [0:DIM-1],

    // 脉动阵列列方向的输入
    input logic signed [ACC_WIDTH-1:0] col_input [0:DIM-1],
    input logic signed [ACC_WIDTH-1:0] d_input [0:DIM-1],
    input prop_mode_e prop_mode,
    input dataflow_e dataflow,
    output logic signed [ACC_WIDTH-1:0] result_data [0:DIM-1],
    output logic [DIM-1:0] result_valid
);
    // 行输入打拍处理
    logic [INPUT_WIDTH-1:0] delay_row [0:DIM-1][0:DIM-1];

    // skew后的行输入
    logic [INPUT_WIDTH-1:0] row_buffer [0:DIM-1];

    // 行valid skew延迟
    logic delay_row_valid [0:DIM-1][0:DIM-1];
    logic [DIM-1:0] row_buffer_valid;

    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0) begin
            for (int i = 0; i < DIM; i++) begin
                for (int j = 0; j < DIM; j++) begin
                    delay_row[i][j] <= '0;
                    delay_row_valid[i][j] <= '0;
                end
            end
        end
        else if(clear == 1'b1) begin
            for (int i = 0; i < DIM; i++) begin
                for (int j = 0; j < DIM; j++) begin
                    delay_row[i][j] <= '0;
                    delay_row_valid[i][j] <= '0;
                end
            end
        end
        else if(en) begin
            // 第i行需要延迟i个阵列推进周期，因此使用i级寄存器：
            // stage 0～stage i-1。新数据从stage i-1进入并向stage 0移动。
            for(int i = 1;i < DIM; i++) begin
                // 第i行需要延迟i个阵列推进周期，因此使用i级寄存器：
                // stage 0～stage i-1。新数据从stage i-1进入并向stage 0移动。
                delay_row[i][i - 1] <= row_input[i];
                delay_row_valid[i][i - 1] <= a_valid[i];
                // 三角形，避免综合出多余的无效寄存器
                for(int j = 0;j < i - 1;j++) begin
                    delay_row[i][j] <= delay_row[i][j + 1];
                    delay_row_valid[i][j] <= delay_row_valid[i][j + 1];
                end
            end
        end
    end

    always_comb begin
        for(int i = 0;i < DIM;i++) begin
            row_buffer[i] = (i == 0)? row_input[0]:delay_row[i][0];
            row_buffer_valid[i] = (i == 0)? a_valid[0]:delay_row_valid[i][0];
        end
    end


    // 列输入打拍处理
    logic [ACC_WIDTH-1:0] delay_col [0:DIM-1][0:DIM-1];

    // skew后的行输入
    logic [ACC_WIDTH-1:0] col_buffer [0:DIM-1];


    // 列valid skew延迟
    logic delay_col_valid [0:DIM-1][0:DIM-1];
    logic [DIM-1:0] col_buffer_valid;

    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0) begin
            for (int i = 0; i < DIM; i++) begin
                for (int j = 0; j < DIM; j++) begin
                    delay_col[i][j] <= '0;
                    delay_col_valid[i][j] <= '0;
                end
            end
        end
        else if(clear == 1'b1) begin
            for (int i = 0; i < DIM; i++) begin
                for (int j = 0; j < DIM; j++) begin
                    delay_col[i][j] <= '0;
                    delay_col_valid[i][j] <= '0;
                end
            end
        end
        else if(en) begin
            for(int i = 1;i < DIM; i++) begin
                delay_col[i][i - 1] <= col_input[i];
                delay_col_valid[i][i - 1] <= b_valid[i];
                for(int j = 0;j < i - 1;j++) begin
                    delay_col[i][j] <= delay_col[i][j + 1];
                    delay_col_valid[i][j] <= delay_col_valid[i][j + 1];
                end
            end
        end
    end

    always_comb begin
        for(int i = 0;i < DIM;i++) begin
            col_buffer[i] = (i == 0)? col_input[0]:delay_col[i][0];
            col_buffer_valid[i] = (i == 0)? b_valid[0]:delay_col_valid[i][0];
        end
    end

    // systolic array大小为DIM*DIM
    logic signed [INPUT_WIDTH-1:0] a_i [0:DIM-1][0:DIM-1];
    logic signed [ACC_WIDTH-1:0] b_i [0:DIM-1][0:DIM-1];
    logic signed [ACC_WIDTH-1:0] d_i [0:DIM-1][0:DIM-1];
    logic a_valid_i [0:DIM-1][0:DIM-1];
    logic b_valid_i [0:DIM-1][0:DIM-1];
    logic c_valid_i [0:DIM-1][0:DIM-1];

    logic signed [INPUT_WIDTH-1:0] a_o [0:DIM-1][0:DIM-1];
    logic signed [ACC_WIDTH-1:0] b_o [0:DIM-1][0:DIM-1];
    logic signed [ACC_WIDTH-1:0] c_o [0:DIM-1][0:DIM-1];
    logic a_valid_o [0:DIM-1][0:DIM-1];
    logic b_valid_o [0:DIM-1][0:DIM-1];
    logic c_valid_o [0:DIM-1][0:DIM-1];

    // pe间信号连接方式
    genvar row, col;
    generate
        for(row = 0; row < DIM; row++) begin : gen_interconnect_row
            for(col = 0; col < DIM; col++) begin : gen_interconnect_col
                if (col > 0) begin : gen_a_from_left
                    // 激活值从左向右传播。
                    assign a_i[row][col] = a_o[row][col-1];
                    assign a_valid_i[row][col] = a_valid_o[row][col-1];
                end
                else begin
                    // 最左侧（第一列）PE连接到行输入
                    assign a_i[row][col] = row_buffer[row];

                    // 行valid信号传播
                    assign a_valid_i[row][col] = row_buffer_valid[row];
                end

                if (row > 0) begin : gen_bd_from_above
                    // 权重/部分和以及d/c通道从上向下传播。
                    assign b_i[row][col] = b_o[row-1][col];
                    assign d_i[row][col] = c_o[row-1][col];

                    // 列valid信号传播
                    assign b_valid_i[row][col] = b_valid_o[row-1][col];
                    assign c_valid_i[row][col] = c_valid_o[row-1][col];

                end
                else begin
                    // 最上方（第一行）PE连接到列输入
                    assign b_i[row][col] = col_buffer[col];
                    assign d_i[row][col] = d_input[col];
                    assign b_valid_i[row][col] = col_buffer_valid[col];
                    assign c_valid_i[row][col] = c_valid[col];

                end
            end
        end
    endgenerate

    // pe批量生成
    genvar i,j;

    generate
        for (i = 0; i < DIM; i++) begin : gen_submodule
            for (j = 0; j < DIM; j++) begin : gen_submodule_col
                pe #(
                    .INPUT_WIDTH(INPUT_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) pe_u(
                    .clk(clk),
                    .rst_n(rst_n),
                    .en_i(en),
                    .clear_i(clear),
                    .a_valid_i(a_valid_i[i][j]),
                    .b_valid_i(b_valid_i[i][j]),
                    .c_valid_i(c_valid_i[i][j]),

                    .a_valid_o(a_valid_o[i][j]),
                    .b_valid_o(b_valid_o[i][j]),
                    .c_valid_o(c_valid_o[i][j]),
                    .a_i(a_i[i][j]),
                    .b_i(b_i[i][j]),
                    .d_i(d_i[i][j]),
                    .dataflow_i(dataflow),
                    .prop_mode_i(prop_mode),
                    .a_o(a_o[i][j]),
                    .b_o(b_o[i][j]),
                    .c_o(c_o[i][j])
                );
            end
        end
    endgenerate

    // 输出逻辑。使用逐列连续赋值，明确表达每个输出位都有唯一驱动。
    for (genvar result_col = 0; result_col < DIM; result_col++) begin : gen_result
        assign result_data[result_col] =
            (dataflow == WEIGHT_STATIONARY) ? b_o[DIM-1][result_col]
                                            : c_o[DIM-1][result_col];
        assign result_valid[result_col] =
            (dataflow == WEIGHT_STATIONARY) ? b_valid_o[DIM-1][result_col]
                                            : c_valid_o[DIM-1][result_col];
    end

endmodule
