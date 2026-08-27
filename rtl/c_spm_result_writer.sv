// 将阵列底边的32位结果写入banked C_SPM。
//
// 阵列底边的第j列比第0列晚j拍到达，因此本模块先对较早
// 到达的列增加 ARRAY_DIM-1-j 拍延迟。反向skew后，同一个逻辑
// 结果行的所有列在同一拍有效，才能使用scratchpad的“共享row地址
// + 每bank独立wen”写口正确写入一整行。
module c_spm_result_writer #(
    parameter int unsigned ARRAY_DIM = 8,
    parameter int unsigned SPM_DEPTH = 256,
    parameter int unsigned ACC_WIDTH = 32
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start_i,
    input  logic [$clog2(SPM_DEPTH)-1:0] base_row_i,
    input  logic [ARRAY_DIM-1:0] result_valid_i,
    input  logic signed [ACC_WIDTH-1:0] result_data_i [0:ARRAY_DIM-1],

    output logic [ARRAY_DIM-1:0] wen_o,
    output logic [$clog2(SPM_DEPTH)-1:0] waddr_o,
    output logic [ACC_WIDTH-1:0] wdata_o [0:ARRAY_DIM-1]
);
    logic [$clog2(SPM_DEPTH)-1:0] row_q;
    logic [ARRAY_DIM-1:0] valid_pipe [0:ARRAY_DIM-1];
    logic signed [ACC_WIDTH-1:0]
        data_pipe [0:ARRAY_DIM-1][0:ARRAY_DIM-1];

    assign waddr_o = row_q;

    always_comb begin
        for (int lane = 0; lane < ARRAY_DIM; lane++) begin
            // lane j使用长度ARRAY_DIM-j的寄存器链。包含统一的
            // 一拍输入寄存后，各lane的额外延迟仍相差j拍。
            wen_o[lane]   = valid_pipe[lane][ARRAY_DIM-1-lane];
            wdata_o[lane] = data_pipe[lane][ARRAY_DIM-1-lane];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_q <= '0;
            for (int lane = 0; lane < ARRAY_DIM; lane++) begin
                valid_pipe[lane] <= '0;
                for (int stage = 0; stage < ARRAY_DIM; stage++)
                    data_pipe[lane][stage] <= '0;
            end
        end else begin
            for (int lane = 0; lane < ARRAY_DIM; lane++) begin
                valid_pipe[lane][0] <= result_valid_i[lane];
                data_pipe[lane][0]  <= result_data_i[lane];

                for (int stage = 1; stage < ARRAY_DIM; stage++) begin
                    valid_pipe[lane][stage] <= valid_pipe[lane][stage-1];
                    data_pipe[lane][stage]  <= data_pipe[lane][stage-1];
                end
            end

            if (start_i)
                row_q <= base_row_i;
            else if (|wen_o)
                row_q <= row_q + 1'b1;
        end
    end
endmodule
