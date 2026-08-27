// Copyright (c) 2026
//
// CV32E40X data-interface address router
//
// This module is placed immediately outside cv32e40x_core.data_*.
// It decodes CPU load/store addresses and forwards each transaction to either:
//   1. the DMA configuration-register (MMIO) slave; or
//   2. the normal-memory path, which can later feed a CPU/DMA memory arbiter.
//
// The first implementation intentionally permits only one outstanding CPU data
// transaction.  OBI responses carry no transaction ID, so serializing requests
// makes the delayed response routing unambiguous and is a useful correctness
// baseline before adding an owner FIFO for multiple outstanding transactions.

module cpu_data_router import cv32e40x_pkg::*;
#(
    // DMA occupies DMA_MMIO_SIZE_BYTES bytes starting at DMA_MMIO_BASE_ADDR.
    // The size must be a non-zero power of two and the base must be aligned to it.
    parameter logic [31:0] DMA_MMIO_BASE_ADDR  = 32'h4000_0000,
    parameter int unsigned DMA_MMIO_SIZE_BYTES = 32
)(
    input  logic clk,
    input  logic rst_n,

    // ------------------------------------------------------------------
    // CPU-facing data interface.
    // Connect these signals directly to cv32e40x_core.data_*.
    // The router behaves as a slave from the CPU's point of view.
    // ------------------------------------------------------------------
    input  logic        cpu_req_i,
    output logic        cpu_gnt_o,

    input  logic [31:0] cpu_addr_i,
    input  logic [3:0]  cpu_be_i,
    input  logic        cpu_we_i,
    input  logic [31:0] cpu_wdata_i,
    input  logic [1:0]  cpu_memtype_i,
    input  logic [2:0]  cpu_prot_i,
    input  logic        cpu_dbg_i,
    input  logic [5:0]  cpu_atop_i,

    output logic        cpu_rvalid_o,
    output logic [31:0] cpu_rdata_o,
    output logic        cpu_err_o,
    output logic        cpu_exokay_o,

    // Normal-memory path.  This is the CPU input of the later CPU/DMA
    // main-memory arbiter.
    cv32e40x_if_c_obi.master m_cpu_mem_if,

    // DMA MMIO path.  Connect this interface to dma.s_c_obi_cfg_if.
    cv32e40x_if_c_obi.master m_dma_cfg_if
);

    localparam logic [31:0] DMA_MMIO_ADDR_MASK =
        32'hffff_ffff << $clog2(DMA_MMIO_SIZE_BYTES);

    typedef enum logic {
        TARGET_MEMORY,
        TARGET_DMA
    } response_target_e;

    response_target_e response_target_q;
    logic              outstanding_q;

    logic dma_addr_hit;
    logic cpu_accept;
    logic selected_response_valid;

    // Compare the complete MMIO region rather than only the register offset.
    assign dma_addr_hit =
        (cpu_addr_i & DMA_MMIO_ADDR_MASK) ==
        (DMA_MMIO_BASE_ADDR & DMA_MMIO_ADDR_MASK);

    assign cpu_accept = cpu_req_i && cpu_gnt_o;

    // A delayed response must be routed according to the destination recorded
    // when the request was granted, not according to the CPU's current address.
    always_comb begin
        if (response_target_q == TARGET_DMA)
            selected_response_valid = m_dma_cfg_if.s_rvalid.rvalid;
        else
            selected_response_valid = m_cpu_mem_if.s_rvalid.rvalid;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            response_target_q <= TARGET_MEMORY;
            outstanding_q     <= 1'b0;
        end else begin
            if (cpu_accept) begin
                response_target_q <= dma_addr_hit ? TARGET_DMA : TARGET_MEMORY;
                outstanding_q     <= 1'b1;
            end else if (outstanding_q && selected_response_valid) begin
                outstanding_q <= 1'b0;
            end
        end
    end

    // Request demultiplexer.  While a response is outstanding, both downstream
    // request channels and cpu_gnt_o remain low, so the core cannot issue a
    // second data transaction through this baseline router.
    always_comb begin
        m_cpu_mem_if.s_req.req   = 1'b0;
        m_cpu_mem_if.req_payload = '0;
        m_dma_cfg_if.s_req.req   = 1'b0;
        m_dma_cfg_if.req_payload = '0;
        cpu_gnt_o                = 1'b0;

        // Both destinations receive the full CPU payload.  Only the selected
        // destination sees req=1, so the payload on the other path is ignored.
        m_cpu_mem_if.req_payload.addr    = cpu_addr_i;
        m_cpu_mem_if.req_payload.atop    = cpu_atop_i;
        m_cpu_mem_if.req_payload.we      = cpu_we_i;
        m_cpu_mem_if.req_payload.be      = cpu_be_i;
        m_cpu_mem_if.req_payload.wdata   = cpu_wdata_i;
        m_cpu_mem_if.req_payload.memtype = cpu_memtype_i;
        m_cpu_mem_if.req_payload.prot    = cpu_prot_i;
        m_cpu_mem_if.req_payload.dbg     = cpu_dbg_i;

        m_dma_cfg_if.req_payload.addr    = cpu_addr_i;
        m_dma_cfg_if.req_payload.atop    = cpu_atop_i;
        m_dma_cfg_if.req_payload.we      = cpu_we_i;
        m_dma_cfg_if.req_payload.be      = cpu_be_i;
        m_dma_cfg_if.req_payload.wdata   = cpu_wdata_i;
        m_dma_cfg_if.req_payload.memtype = cpu_memtype_i;
        m_dma_cfg_if.req_payload.prot    = cpu_prot_i;
        m_dma_cfg_if.req_payload.dbg     = cpu_dbg_i;

        if (!outstanding_q && cpu_req_i) begin
            if (dma_addr_hit) begin
                m_dma_cfg_if.s_req.req = 1'b1;
                cpu_gnt_o              = m_dma_cfg_if.s_gnt.gnt;
            end else begin
                m_cpu_mem_if.s_req.req = 1'b1;
                cpu_gnt_o              = m_cpu_mem_if.s_gnt.gnt;
            end
        end
    end

    // Response multiplexer.  The CV32E40X top-level data interface exposes only
    // err[0]; err[1] is reconstructed inside the core's response filter.
    always_comb begin
        cpu_rvalid_o = 1'b0;
        cpu_rdata_o  = '0;
        cpu_err_o    = 1'b0;
        cpu_exokay_o = 1'b0;

        if (outstanding_q) begin
            if (response_target_q == TARGET_DMA) begin
                cpu_rvalid_o = m_dma_cfg_if.s_rvalid.rvalid;
                cpu_rdata_o  = m_dma_cfg_if.resp_payload.rdata;
                cpu_err_o    = m_dma_cfg_if.resp_payload.err[0];
                cpu_exokay_o = m_dma_cfg_if.resp_payload.exokay;
            end else begin
                cpu_rvalid_o = m_cpu_mem_if.s_rvalid.rvalid;
                cpu_rdata_o  = m_cpu_mem_if.resp_payload.rdata;
                cpu_err_o    = m_cpu_mem_if.resp_payload.err[0];
                cpu_exokay_o = m_cpu_mem_if.resp_payload.exokay;
            end
        end
    end

    // Elaboration-time parameter checks.  Power-of-two sizing makes the mask
    // decoder exact and avoids a comparator on the address critical path.
    initial begin
        assert (DMA_MMIO_SIZE_BYTES > 0)
            else $error("DMA_MMIO_SIZE_BYTES must be non-zero");
        assert ((DMA_MMIO_SIZE_BYTES & (DMA_MMIO_SIZE_BYTES - 1)) == 0)
            else $error("DMA_MMIO_SIZE_BYTES must be a power of two");
        assert ((DMA_MMIO_BASE_ADDR & (DMA_MMIO_SIZE_BYTES - 1)) == 0)
            else $error("DMA_MMIO_BASE_ADDR must be aligned to DMA_MMIO_SIZE_BYTES");
    end

endmodule
