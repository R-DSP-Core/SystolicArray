// DMA到A/B SPM的双向请求路由器。
//
// 写请求只需要转发req通道。读请求返回时DMA已经不再保持原地址，因此
// 路由器必须在读请求握手时记录目标SPM，并用该记录选择响应。当前DMA
// 只允许一个SPM读outstanding，所以一个owner寄存器就足够。
module spm_write_router #(
    parameter logic [31:0] A_SPM_BASE = 32'h5000_0000,
    parameter logic [31:0] B_SPM_BASE = 32'h5001_0000,
    parameter logic [31:0] C_SPM_BASE = 32'h5002_0000,
    parameter int unsigned SPM_SIZE_BYTES = 2048
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        dma_valid_i,
    input  logic [31:0] dma_addr_i,
    input  logic        dma_we_i,
    input  logic [31:0] dma_wdata_i,
    output logic        dma_ready_o,

    input  logic        dma_rsp_ready_i,
    output logic        dma_rsp_valid_o,
    output logic [31:0] dma_rsp_rdata_o,
    output logic        invalid_addr_o,

    output logic        a_valid_o,
    output logic [31:0] a_addr_o,
    output logic        a_we_o,
    output logic [31:0] a_wdata_o,
    input  logic        a_ready_i,
    output logic        a_rsp_ready_o,
    input  logic        a_rsp_valid_i,
    input  logic [31:0] a_rsp_rdata_i,

    output logic        b_valid_o,
    output logic [31:0] b_addr_o,
    output logic        b_we_o,
    output logic [31:0] b_wdata_o,
    input  logic        b_ready_i,
    output logic        b_rsp_ready_o,
    input  logic        b_rsp_valid_i,
    input  logic [31:0] b_rsp_rdata_i,

    output logic        c_valid_o,
    output logic [31:0] c_addr_o,
    output logic        c_we_o,
    output logic [31:0] c_wdata_o,
    input  logic        c_ready_i,
    output logic        c_rsp_ready_o,
    input  logic        c_rsp_valid_i,
    input  logic [31:0] c_rsp_rdata_i
);
    typedef enum logic [1:0] {
        SPM_OWNER_NONE,
        SPM_OWNER_A,
        SPM_OWNER_B,
        SPM_OWNER_C
    } spm_owner_e;

    logic a_hit, b_hit, c_hit;
    logic request_fire;
    logic response_fire;
    logic read_outstanding_q;
    spm_owner_e response_owner_q;

    assign a_hit = (dma_addr_i >= A_SPM_BASE) &&
                   (dma_addr_i < A_SPM_BASE + SPM_SIZE_BYTES);
    assign b_hit = (dma_addr_i >= B_SPM_BASE) &&
                   (dma_addr_i < B_SPM_BASE + SPM_SIZE_BYTES);
    assign c_hit = (dma_addr_i >= C_SPM_BASE) &&
                   (dma_addr_i < C_SPM_BASE + (4 * SPM_SIZE_BYTES));
    assign request_fire  = dma_valid_i && dma_ready_o;
    assign response_fire = dma_rsp_valid_o && dma_rsp_ready_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_outstanding_q <= 1'b0;
            response_owner_q   <= SPM_OWNER_NONE;
        end else begin
            if (response_fire) begin
                read_outstanding_q <= 1'b0;
                response_owner_q   <= SPM_OWNER_NONE;
            end

            if (request_fire && !dma_we_i) begin
                read_outstanding_q <= 1'b1;
                if (a_hit)
                    response_owner_q <= SPM_OWNER_A;
                else if (b_hit)
                    response_owner_q <= SPM_OWNER_B;
                else
                    response_owner_q <= SPM_OWNER_C;
            end
        end
    end

    always_comb begin
        dma_ready_o     = 1'b0;
        invalid_addr_o  = dma_valid_i && !a_hit && !b_hit && !c_hit;
        dma_rsp_valid_o = 1'b0;
        dma_rsp_rdata_o = '0;

        a_valid_o = 1'b0;
        a_addr_o  = dma_addr_i - A_SPM_BASE;
        a_we_o    = dma_we_i;
        a_wdata_o = dma_wdata_i;
        a_rsp_ready_o = 1'b0;

        b_valid_o = 1'b0;
        b_addr_o  = dma_addr_i - B_SPM_BASE;
        b_we_o    = dma_we_i;
        b_wdata_o = dma_wdata_i;
        b_rsp_ready_o = 1'b0;

        c_valid_o = 1'b0;
        c_addr_o  = dma_addr_i - C_SPM_BASE;
        c_we_o    = dma_we_i;
        c_wdata_o = dma_wdata_i;
        c_rsp_ready_o = 1'b0;

        // DMA本身也只发一个SPM读outstanding。这里额外阻止请求可避免
        // 将来更换master后覆盖response_owner_q。
        if (!read_outstanding_q) begin
            if (a_hit) begin
                a_valid_o   = dma_valid_i;
                dma_ready_o = a_ready_i;
            end else if (b_hit) begin
                b_valid_o   = dma_valid_i;
                dma_ready_o = b_ready_i;
            end else if (c_hit) begin
                c_valid_o   = dma_valid_i;
                dma_ready_o = c_ready_i;
            end
        end

        unique case (response_owner_q)
            SPM_OWNER_A: begin
                dma_rsp_valid_o = a_rsp_valid_i;
                dma_rsp_rdata_o = a_rsp_rdata_i;
                a_rsp_ready_o   = dma_rsp_ready_i;
            end
            SPM_OWNER_B: begin
                dma_rsp_valid_o = b_rsp_valid_i;
                dma_rsp_rdata_o = b_rsp_rdata_i;
                b_rsp_ready_o   = dma_rsp_ready_i;
            end
            SPM_OWNER_C: begin
                dma_rsp_valid_o = c_rsp_valid_i;
                dma_rsp_rdata_o = c_rsp_rdata_i;
                c_rsp_ready_o   = dma_rsp_ready_i;
            end
            default: begin
            end
        endcase
    end

    initial begin
        assert (SPM_SIZE_BYTES > 0)
            else $error("SPM_SIZE_BYTES must be non-zero");
        assert ((A_SPM_BASE + SPM_SIZE_BYTES <= B_SPM_BASE) ||
                (B_SPM_BASE + SPM_SIZE_BYTES <= A_SPM_BASE))
            else $error("A_SPM and B_SPM address regions overlap");
        assert ((B_SPM_BASE + SPM_SIZE_BYTES <= C_SPM_BASE) ||
                (C_SPM_BASE + 4 * SPM_SIZE_BYTES <= B_SPM_BASE))
            else $error("B_SPM and C_SPM address regions overlap");
    end
endmodule
