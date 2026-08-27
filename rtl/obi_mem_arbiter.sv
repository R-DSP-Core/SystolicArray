typedef enum logic {
      ARB_IDLE,
      ARB_WAIT_RESPONSE
} arb_state_e;

typedef enum logic [1:0]{
      OWNER_CPU,
      OWNER_DMA,
      OWNER_NONE
} owner_e;

// 主存仲裁器：仲裁来自于DMA和主存侧的访存请求
// 主存侧暂定为单端口
module obi_mem_arbiter import cv32e40x_pkg::*; (
      input logic clk,
      input logic rst_n,

      // CPU普通主存请求
      cv32e40x_if_c_obi.slave  s_cpu_if,

      // DMA主存请求
      cv32e40x_if_c_obi.slave  s_dma_if,

      // 仲裁后的主存请求
      cv32e40x_if_c_obi.master m_mem_if
  );

    // 状态更新逻辑
    arb_state_e state, next_state;

    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0) begin
            state <= ARB_IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    logic arbReqFire;
    assign arbReqFire = m_mem_if.s_req.req && m_mem_if.s_gnt.gnt;

    // 状态转移逻辑
    always_comb begin
        next_state = state;
        unique case(state)
            ARB_IDLE:begin
                if(arbReqFire) begin
                    next_state = ARB_WAIT_RESPONSE;
                end
            end
            ARB_WAIT_RESPONSE:begin
                if(m_mem_if.s_rvalid.rvalid) begin
                    next_state = ARB_IDLE;
                end
            end
            default:begin
            end
        endcase
    end

    // 每次请求记录来源
    owner_e current_owner,resp_owner;
    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0)
            resp_owner <= OWNER_NONE;
        else
            if(arbReqFire) begin
                resp_owner <= current_owner;
            end

    end

    // 组合逻辑选择
    always_comb begin
        current_owner = resp_owner;
        if(state == ARB_IDLE) begin
            unique case({s_cpu_if.s_req.req, s_dma_if.s_req.req})
                2'b00:begin
                    current_owner = OWNER_NONE;
                end
                2'b01:begin
                    current_owner = OWNER_DMA;
                end
                2'b10:begin
                    current_owner = OWNER_CPU;
                end
                2'b11:begin
                    // 冲突时轮流选择
                    current_owner =
                    (resp_owner == OWNER_CPU) ? OWNER_DMA : OWNER_CPU;
                end
                default:begin
                end
            endcase
        end
    end

    // 组合逻辑输出
    always_comb begin
        m_mem_if.s_req.req = 1'b0;
        m_mem_if.req_payload = '0;

        s_dma_if.s_gnt.gnt = 1'b0;
        s_cpu_if.s_gnt.gnt = 1'b0;

        s_cpu_if.s_rvalid.rvalid = 1'b0;
        s_cpu_if.resp_payload    = '0;

        s_dma_if.s_rvalid.rvalid = 1'b0;
        s_dma_if.resp_payload    = '0;

        unique case(state)
            ARB_IDLE:begin
                unique case({s_cpu_if.s_req.req, s_dma_if.s_req.req})
                    2'b00:begin

                    end
                    2'b01:begin
                        m_mem_if.s_req.req = 1'b1;
                        m_mem_if.req_payload = s_dma_if.req_payload;

                        if(m_mem_if.s_gnt.gnt)
                            s_dma_if.s_gnt.gnt = 1'b1;
                    end
                    2'b10:begin
                        m_mem_if.s_req.req = 1'b1;
                        m_mem_if.req_payload = s_cpu_if.req_payload;

                        if(m_mem_if.s_gnt.gnt)
                            s_cpu_if.s_gnt.gnt = 1'b1;
                    end
                    2'b11:begin
                        if(current_owner == OWNER_CPU) begin
                            m_mem_if.s_req.req = 1'b1;
                            m_mem_if.req_payload = s_cpu_if.req_payload;

                            s_cpu_if.s_gnt.gnt = m_mem_if.s_gnt.gnt;
                        end
                        else if(current_owner == OWNER_DMA) begin
                            m_mem_if.s_req.req = 1'b1;
                            m_mem_if.req_payload = s_dma_if.req_payload;

                            s_dma_if.s_gnt.gnt = m_mem_if.s_gnt.gnt;
                        end
                    end
                endcase
            end
            ARB_WAIT_RESPONSE:begin
                if (resp_owner == OWNER_CPU) begin
                    s_cpu_if.s_rvalid.rvalid = m_mem_if.s_rvalid.rvalid;
                    s_cpu_if.resp_payload    = m_mem_if.resp_payload;
                end
                else begin
                    s_dma_if.s_rvalid.rvalid = m_mem_if.s_rvalid.rvalid;
                    s_dma_if.resp_payload    = m_mem_if.resp_payload;
                end
            end
            default:begin
            end
        endcase

    end

endmodule
