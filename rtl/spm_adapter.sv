// adapter用于连接dma和spm，应为纯组合逻辑
module spm_adapter import cv32e40x_pkg::*;
#(
    // bank参数
    parameter int BANK_NUM = DIM,
    parameter int BANK_DEPTH = 256,
    parameter int DATA_WIDTH = 8
 )
(
    input logic clk,
    input logic rst_n,
    // DMA侧接口
    input logic spm_req_valid,
    input logic [31:0] spm_req_addr,
    input logic spm_req_we,
    input logic [31:0] spm_req_wdata,
    output logic spm_req_ready,

    input logic spm_rsp_ready,
    output logic [31:0] spm_rsp_rdata,
    output logic spm_rsp_valid,

    // SPM侧写接口
    output logic [BANK_NUM - 1:0] wen,
    output logic [$clog2(BANK_DEPTH)-1:0] waddr,
    output logic [DATA_WIDTH - 1:0] wdata [0:BANK_NUM-1],

    // SPM侧读接口
    output logic [BANK_NUM - 1:0] ren,
    output logic [$clog2(BANK_DEPTH)-1:0] raddr,
    // input logic [BANK_NUM - 1:0] rvalid,
    input logic [DATA_WIDTH - 1:0] rdata [0:BANK_NUM-1]
);
    // 读写起始bank
    logic [$clog2(BANK_NUM) - 1:0] write_bank_base_8bits, read_bank_base_8bits;
    logic [$clog2(BANK_NUM) - 1:0] write_bank_base_32bits, read_bank_base_32bits;

    // // 这里不区分读写请求直接把事务请求的地址赋给w/raddr，靠w/ren来区分
    // assign waddr = spm_req_addr[$clog2(BANK_DEPTH)+$clog2(BANK_NUM)-1 -:$clog2(BANK_DEPTH)];
    // assign raddr = spm_req_addr[$clog2(BANK_DEPTH)+$clog2(BANK_NUM)-1 -:$clog2(BANK_DEPTH)];

    // dma一次写入32位数据，而spm数据位宽是8位，需要采用interleaved blocking写入
    // 32位数据需要在一拍内写入spm，也即一次同时写4个bank。DMA侧传来的地址要映射到4个连续的bank地址
    // 对于地址，DMA侧的地址为32位，而SPM有效地址为bank深度位宽（bank数由wen选定），因此需要从DMA访存地址中取低位
    // 每次填4个bank，需要让wen从8'b00001111到8'b11110000来回切换。用地址第2位来判断


    always_comb begin
        // 取地址低3位（由于低2位为0，因此bank_base只能为0或4）
        // 按字节编址的情况下，地址是一字节对齐，写入的地址应当用低$clog2(BANK_NUM)位作为写入的bank索引，一次读写4个bank
        write_bank_base_8bits = spm_req_addr[$clog2(BANK_NUM) - 1:0];
        read_bank_base_8bits = spm_req_addr[$clog2(BANK_NUM) - 1:0];

        // 32位宽的情况下，一次写一个bank，直接取对应位宽作为bank地址
        write_bank_base_32bits = spm_req_addr[$clog2(DATA_WIDTH/8) + $clog2(BANK_NUM) - 1 -:$clog2(BANK_NUM)];
        read_bank_base_32bits = spm_req_addr[$clog2(DATA_WIDTH/8) + $clog2(BANK_NUM) - 1 -:$clog2(BANK_NUM)];

        spm_rsp_rdata = '0;

        waddr = '0;
        raddr = '0;

        wen = '0;
        ren = '0;

        for (int i = 0; i < BANK_NUM; i++) begin
            wdata[i] = '0;
        end

        if (spm_req_valid  && spm_req_ready) begin
            // 写请求
            if(spm_req_we) begin
                // A/B SPM：SPM bank位宽为8，一次写入32位数据写4个bank
                // SPM共8个bank，每次写入选中的bank在前后4个bank共两组之间切换
                if(DATA_WIDTH == 8) begin
                    // 8位SPM位宽下的SPM总地址: bank深度位宽+bank数位宽（8位-1字节，不需要额外地址偏移）
                    // 写入spm的地址，再对总地址取高$clog2(BANK_DEPTH)位即可
                    waddr = spm_req_addr[$clog2(BANK_DEPTH)+$clog2(BANK_NUM) - 1 -:$clog2(BANK_DEPTH)];
                    for (int k = 0; k < 4; k++) begin
                        wen[write_bank_base_8bits+k] = 1'b1;
                        wdata[write_bank_base_8bits+k] = spm_req_wdata[8*k +: 8];
                    end
                end
                // 写C_SPM：SPM bank位宽为32，一次写32位数据只写一个bank
                else if(DATA_WIDTH == 32) begin
                    // 8位SPM位宽下的SPM总地址: bank深度位宽+bank数位宽+2（32位-4字节，需要额外地址偏移2位）
                    waddr = spm_req_addr[$clog2(DATA_WIDTH/8) + $clog2(BANK_NUM) + $clog2(BANK_DEPTH) - 1 -:$clog2(BANK_DEPTH)];
                    wen[write_bank_base_32bits] = 1'b1;
                    wdata[write_bank_base_32bits] = spm_req_wdata;
                end
            end
            // 读请求，只给出raddr和ren。因为是同步读，rdata在下一周期返回结果
            else begin
                if(DATA_WIDTH == 8) begin
                    raddr = spm_req_addr[$clog2(BANK_DEPTH)+$clog2(BANK_NUM)-1 -:$clog2(BANK_DEPTH)];
                    for (int k = 0; k < 4; k++) begin
                        ren[read_bank_base_8bits+k] = 1'b1;
                    end
                end
                else if(DATA_WIDTH == 32) begin
                    raddr = spm_req_addr[$clog2(DATA_WIDTH/8) + $clog2(BANK_NUM) + $clog2(BANK_DEPTH) - 1 -:$clog2(BANK_DEPTH)];
                    ren[read_bank_base_32bits] = 1'b1;
                end
            end
        end

        // 响应握手后，把同步读回来的SPM数据转发回去
        // 此时的bank base是上一个周期寄存过的
        if(spm_rsp_valid) begin
            if(DATA_WIDTH == 8) begin
                for (int k = 0; k < 4; k++) begin

                    spm_rsp_rdata[8*k +: 8] = rdata[read_bank_base_8bits_q+k];
                end
            end
            else if(DATA_WIDTH == 32) begin
                spm_rsp_rdata = rdata[read_bank_base_32bits_q];
            end
        end

    end

    // spm始终ready
    assign spm_req_ready = 1'b1;
    // assign spm_rsp_valid = 1'b1;
    logic [$clog2(BANK_NUM) - 1:0]read_bank_base_8bits_q, read_bank_base_32bits_q;

    // // TODO:设置一个C_SPM的bank base计数寄存器，每次写完C_SPM自增一次
    // logic [$clog2(BANK_NUM) - 1:0]write_acc_base_q;
    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0) begin
            spm_rsp_valid <='0;
            read_bank_base_8bits_q <= '0;
            read_bank_base_32bits_q <= '0;
        end
        else begin


            // 响应被接收，valid拉低

            if(spm_rsp_valid && spm_rsp_ready)
                spm_rsp_valid <= 1'b0;

            // spm_rsp_valid置位放在后面，防止出现旧响应被接收同一个周期接收新请求后，清零会覆盖新置位的问题
            if (spm_req_valid  && spm_req_ready) begin
                if(!spm_req_we) begin

                    spm_rsp_valid <= 1'b1;
                    read_bank_base_8bits_q <= read_bank_base_8bits;
                    read_bank_base_32bits_q <= read_bank_base_32bits;
                end
            end
        end
    end



endmodule
