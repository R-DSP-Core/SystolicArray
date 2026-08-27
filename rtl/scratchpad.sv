// SPM模块，用于systolic array内的数据高速读写
// SPM应为双端口，一端接到DMA一端接到systolic array的端口
// 同时，SPM为伪双端口，也即一个读口一个写口。
// 在systolic array中，A/B/C三个矩阵的读写方向不同。A B矩阵从SPM读数据，因此A/B SPM被DMA写入，被systolic array读出。C矩阵作为结果矩阵恰好相反
module scratchpad import cv32e40x_pkg::*;
#(
    // bank参数
    parameter int BANK_NUM = DIM,
    parameter int BANK_DEPTH = 256,
    parameter int DATA_WIDTH = 8
 )
(
    input logic clk,
    input logic rst_n,

    // 写端口
    input logic [BANK_NUM - 1:0] wen,
    input logic [$clog2(BANK_DEPTH) - 1:0] waddr,
    input logic [DATA_WIDTH - 1:0] wdata [0:BANK_NUM-1],

    // 读端口
    input logic [BANK_NUM - 1:0] ren,
    input logic [$clog2(BANK_DEPTH)-1:0] raddr,
    // output logic [BANK_NUM - 1:0] rvalid,
    output logic [DATA_WIDTH - 1:0] rdata [0:BANK_NUM-1]
);

    // banked SPM
    logic [DATA_WIDTH-1:0] mem [0:BANK_NUM-1][0:BANK_DEPTH-1];

    // 写SPM
    always_ff @(posedge clk) begin
        for (int i = 0; i < BANK_NUM; i++) begin
            if(wen[i])
                mem[i][waddr] <= wdata[i];
        end
    end

    // 读SPM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // rvalid <= '0;

            for (int i = 0; i < BANK_NUM; i++) begin
                rdata[i] <= '0;
            end
        end else begin
            // rvalid <= ren;

            for (int i = 0; i < BANK_NUM; i++) begin
                if (ren[i]) begin
                    if (wen[i] && waddr == raddr)
                        rdata[i] <= wdata[i];
                    else
                        rdata[i] <= mem[i][raddr];
                end
            end
        end
    end

endmodule