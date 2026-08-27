typedef enum logic [2:0] {
    DMA_MEM_IDLE,
    DMA_READ_MEM_REQ,
    DMA_READ_MEM_WAIT,

    DMA_WRITE_MEM_REQ,
    DMA_WRITE_MEM_WAIT,
    DMA_MEM_FAIL

} mem_access_state_t;

typedef enum logic [2:0]{
    DMA_SPM_IDLE,
    DMA_WRITE_SPM_ACTIVE,

    DMA_READ_SPM_REQ,
    DMA_READ_SPM_WAIT,

    DMA_SPM_FAIL

} spm_access_state_t;


// npu的DMA模块
module dma import cv32e40x_pkg::*;
#(
    // FIFO深度
    parameter int unsigned DEPTH = 256
)
(
    input logic clk,
    input logic rst_n,
    // slave接口，与CPU侧地址仲裁器连接，用于接受CPU侧读写DMA MMIO寄存器的请求
    cv32e40x_if_c_obi.slave s_c_obi_cfg_if,

    // master接口，连接主存，用于从主存读写数据
    cv32e40x_if_c_obi.master m_c_obi_mem_if,

    // master接口，连接SPM，用于从SPM读写数据
    output logic spm_req_valid,
    output logic [31:0] spm_req_addr,
    output logic spm_req_we,
    output logic [31:0] spm_req_wdata,

    // 响应握手
    output logic spm_rsp_ready,
    input logic [31:0] spm_rsp_rdata,
    input logic spm_rsp_valid,

    input logic spm_req_ready
);
    // 4个DMA状态
    localparam logic [31:0] DMA_STATUS_IDLE  = 32'd0;
    localparam logic [31:0] DMA_STATUS_BUSY  = 32'd1;
    localparam logic [31:0] DMA_STATUS_DONE  = 32'd2;

    localparam logic [31:0] DMA_STATUS_ERROR = 32'd4;

    logic [31:0] src_reg,dst_reg,len_reg,dir_reg,status_reg;

    logic [31:0] dma_regdata, dma_regaddr;

    // 当前地址寄存器
    logic [31:0] current_mem_addr;

    // 剩余字节数寄存器
    logic [31:0] remain_mem_reg;

    logic mem_accept;
    mem_access_state_t mem_state, next_mem_state;
    spm_access_state_t spm_state, next_spm_state;
    logic [31:0] current_spm_addr;
    logic [31:0] remain_spm_reg;
    logic fifoEmpty;
    logic fifoFull;

    logic cfg_accept;
    logic cfg_write,cfg_read;

    // CPU侧写数据请求只是MMIO寄存器的读写，DMA侧可以恒ready
    assign s_c_obi_cfg_if.s_gnt.gnt = 1'b1;

    // obi握手，req等价于axi接口valid，gnt等价于axi接口ready
    assign cfg_accept =
        s_c_obi_cfg_if.s_req.req &&
        s_c_obi_cfg_if.s_gnt.gnt;

    // 握手成功且为写请求
    assign cfg_write =
        cfg_accept &&
        s_c_obi_cfg_if.req_payload.we;

    // 握手成功且为读请求
    assign cfg_read =
        cfg_accept &&
        !s_c_obi_cfg_if.req_payload.we;

    assign dma_regdata = s_c_obi_cfg_if.req_payload.wdata;
    assign dma_regaddr = s_c_obi_cfg_if.req_payload.addr;

    // 写start寄存器，用于判定DMA启动
    logic start_fire;
    assign start_fire = cfg_write && dma_regdata[0] && (dma_regaddr[4:0] == 5'h14);

    // MMIO寄存器读写
    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0) begin
            src_reg <= '0;
            dst_reg <= '0;
            len_reg <= '0;
            status_reg <= DMA_STATUS_IDLE;
            // start寄存器没有必要存在，因为start是一个事件，通过组合逻辑检测即可，不需要寄存
            // start_reg <= '0;
            dir_reg <= '0;

            s_c_obi_cfg_if.s_rvalid.rvalid <= '0;
            s_c_obi_cfg_if.resp_payload <= '0;
        end
        else begin
            // 每次默认没有错误发生
            s_c_obi_cfg_if.s_rvalid.rvalid <= 1'b0;
            s_c_obi_cfg_if.resp_payload.rdata <= 32'b0;
            s_c_obi_cfg_if.resp_payload.err <= 2'b00;
            s_c_obi_cfg_if.resp_payload.exokay <= 1'b0;
            if(cfg_write) begin
                // TODO:DMA寄存器地址暂定如下
                // status寄存器不可写
                unique case(dma_regaddr[4:0])
                    5'h00: src_reg <= dma_regdata;
                    5'h04: dst_reg <= dma_regdata;
                    5'h08: len_reg <= dma_regdata;
                    // DMA方向寄存器，0:读主存写SPM 1.读SPM写主存
                    5'h0c: dir_reg <= dma_regdata;
                    5'h14:begin

                    end
                    default: begin
                        // 未知写地址应及时报错
                        s_c_obi_cfg_if.resp_payload.err <= 2'b11;
                    end
                endcase
                s_c_obi_cfg_if.s_rvalid.rvalid <= 1'b1;

            end
            else if(cfg_read) begin
                s_c_obi_cfg_if.s_rvalid.rvalid <= 1'b1;
                // 只能读状态寄存器
                if(dma_regaddr[4:0] == 5'h10) begin
                    s_c_obi_cfg_if.resp_payload.rdata <= status_reg;
                end
                else begin
                    s_c_obi_cfg_if.resp_payload.err <= 2'b01;
                    s_c_obi_cfg_if.resp_payload.rdata <= 32'b0;
                end

            end

            if (start_fire) begin
                if ((status_reg == DMA_STATUS_BUSY) ||
                    (mem_state != DMA_MEM_IDLE) ||
                    (spm_state != DMA_SPM_IDLE)) begin
                    status_reg <= DMA_STATUS_ERROR;
                end
                else if (!cfg_valid) begin
                    status_reg <= DMA_STATUS_ERROR;
                end
                else begin
                    // 新启动同时清除旧DONE/ERROR。
                    status_reg <= DMA_STATUS_BUSY;
                end
            end
            else if (status_reg == DMA_STATUS_BUSY) begin
                if ((mem_state == DMA_MEM_FAIL) ||
                    (spm_state == DMA_SPM_FAIL)) begin
                    status_reg <= DMA_STATUS_ERROR;
                end
                else if ((mem_state == DMA_MEM_IDLE) &&
                        (spm_state == DMA_SPM_IDLE) &&
                        fifoEmpty &&
                        (remain_mem_reg == 0) &&
                        (remain_spm_reg == 0)) begin
                    status_reg <= DMA_STATUS_DONE;
                end
            end



        end
    end

    // FIFO部分
    logic [31:0] dmaBuffer [0:DEPTH-1];

    // 计数器范围0-16，指针范围0-15
    localparam int unsigned PTR_WIDTH   = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam int unsigned COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam logic [PTR_WIDTH-1:0] PTR_LAST = PTR_WIDTH'(DEPTH - 1);
    localparam logic [COUNT_WIDTH-1:0] DEPTH_COUNT = COUNT_WIDTH'(DEPTH);
    logic [PTR_WIDTH-1:0] wrPtr;
    logic [PTR_WIDTH-1:0] rdPtr;
    logic [COUNT_WIDTH-1:0] counter;

    logic enqFire;
    logic deqFire;

    assign fifoEmpty = (counter == '0);
    assign fifoFull  = (counter == DEPTH_COUNT);

    // // SPM侧尚未实现，临时拉低不允许出队
    // assign deqFire = 1'b0;

    logic read_mem_fire, read_spm_fire;
    assign read_mem_fire = (mem_state == DMA_READ_MEM_WAIT) && m_c_obi_mem_if.s_rvalid.rvalid && m_c_obi_mem_if.resp_payload.err == 2'b00;
    assign read_spm_fire = (spm_state == DMA_READ_SPM_WAIT) && spm_rsp_valid && spm_rsp_ready;
    // 读主存或者读SPM时，允许入队
    assign enqFire = read_mem_fire || read_spm_fire;

    logic write_mem_fire, write_spm_fire;

    // TODO:目前mem的写fire，实际上并不是请求握手，而是有响应
    assign write_mem_fire = (mem_state == DMA_WRITE_MEM_WAIT) && m_c_obi_mem_if.s_rvalid.rvalid && m_c_obi_mem_if.resp_payload.err == 2'b00;
    assign write_spm_fire = (spm_state == DMA_WRITE_SPM_ACTIVE) && spm_req_valid && spm_req_ready;

    // 写主存或者写SPM时，允许出队
    assign deqFire = write_mem_fire || write_spm_fire;

    // 响应有效且未报错
    logic mem_rsp_fire;
    assign mem_rsp_fire = m_c_obi_mem_if.s_rvalid.rvalid && m_c_obi_mem_if.resp_payload.err != 2'b00;


    function automatic logic [PTR_WIDTH-1:0] ptr_next(input logic [PTR_WIDTH-1:0] ptr);
        if (ptr == PTR_LAST) begin
            return '0;
        end
        return ptr + 1'b1;
    endfunction

    // DMA读主存中间寄存器更新逻辑
    always_ff @(posedge clk, negedge rst_n) begin
        if (rst_n == 1'b0) begin
            wrPtr   <= '0;
            rdPtr   <= '0;
            counter <= '0;

            current_mem_addr <= '0;
            remain_mem_reg <= '0;
        end else begin
            // 入队逻辑
            // 哪个读响应有效选哪个
            if(read_mem_fire) begin
                dmaBuffer[wrPtr] <= m_c_obi_mem_if.resp_payload.rdata;
                wrPtr <= ptr_next(wrPtr);
            end
            else if(read_spm_fire) begin
                dmaBuffer[wrPtr] <= spm_rsp_rdata;
                wrPtr <= ptr_next(wrPtr);
            end

            if (deqFire) begin
                rdPtr <= ptr_next(rdPtr);
            end
            unique case(mem_state)
                DMA_MEM_IDLE:begin
                    // CPU拉高DMA start寄存器后，此时往访存地址寄存器中装入源地址作为初始访存地址
                    if(start_fire) begin
                        current_mem_addr <= dir_reg[0] ? dst_reg : src_reg;
                        remain_mem_reg <= len_reg;
                    end
                end
                DMA_READ_MEM_WAIT:begin
                    if(mem_rsp_fire) begin
                        // TODO:目前响应完成后，访存地址按4递增，实际上至少应该支持连续地址访问和stride访问两种模式
                        current_mem_addr <= current_mem_addr + 32'd4;
                        // 每次读取4个字节
                        remain_mem_reg <= remain_mem_reg - 32'd4;
                    end
                end
                DMA_WRITE_MEM_WAIT:begin
                    if(mem_rsp_fire) begin
                        current_mem_addr <= current_mem_addr + 32'd4;
                        // 每次读取4个字节
                        remain_mem_reg <= remain_mem_reg - 32'd4;
                    end
                end
                default:begin
                end
            endcase

            unique case ({enqFire, deqFire})
                2'b10: counter <= counter + 1'b1;
                2'b01: counter <= counter - 1'b1;
                default: counter <= counter;
            endcase
        end
    end

    // DMA访问主存
    assign mem_accept = m_c_obi_mem_if.s_req.req && m_c_obi_mem_if.s_gnt.gnt;

    // DMA访问主存的状态更新时序逻辑
    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0)
            mem_state <= DMA_MEM_IDLE;
        else
            mem_state <= next_mem_state;
    end

    logic cfg_valid;

    // 目前只支持4字节对齐访问，源地址和目的地址都必须是4字节对齐，寄存器长度也必须是4字节对齐且不为零
    assign cfg_valid = src_reg[1:0] == 2'b00 && dst_reg[1:0] == 2'b00 && len_reg[1:0] == 2'b00 && len_reg != 0;
    // DMA访问主存的状态转移逻辑
    always_comb begin
        next_mem_state = mem_state;
        unique case(mem_state)
            DMA_MEM_IDLE: begin
                // 不能直接用start_reg来作为状态转移的条件，否则会浪费一个时钟周期
                if(start_fire) begin
                    if(cfg_valid)
                        next_mem_state = dir_reg[0] ? DMA_WRITE_MEM_REQ : DMA_READ_MEM_REQ;
                    else
                        next_mem_state = DMA_MEM_FAIL;
                end
            end
            DMA_READ_MEM_REQ:begin
                // 处理握手
                if(mem_accept)
                    next_mem_state = DMA_READ_MEM_WAIT;
            end
            DMA_READ_MEM_WAIT: begin
                // 当响应有效时，判断响应是否正确，否则等待响应生效
                if(m_c_obi_mem_if.s_rvalid.rvalid) begin
                    if(m_c_obi_mem_if.resp_payload.err == 2'b00)
                        next_mem_state = DMA_MEM_FAIL;
                    else begin
                        if(remain_mem_reg == 32'd4)
                        // 响应生效且正确时，应当检查地址生成器给出的访存地址，如果访存地址达到目的地址边界，才能跳转下一状态
                            next_mem_state = DMA_MEM_IDLE;
                        else
                            next_mem_state = DMA_READ_MEM_REQ;
                    end
                end
            end
            DMA_MEM_FAIL:begin
                // TODO:暂时没想好失败怎么处理，暂定直接跳转回初始状态
                next_mem_state = DMA_MEM_IDLE;
            end

            DMA_WRITE_MEM_REQ:begin
                if(mem_accept)
                    next_mem_state = DMA_WRITE_MEM_WAIT;
            end

            DMA_WRITE_MEM_WAIT:begin
                if(m_c_obi_mem_if.s_rvalid.rvalid) begin
                    if(m_c_obi_mem_if.resp_payload.err == 2'b00)
                        next_mem_state = DMA_MEM_FAIL;
                    else begin
                        // 下个周期为0
                        if(remain_mem_reg == 32'd4)
                        // 响应生效且正确时，应当检查地址生成器给出的访存地址，如果访存地址达到目的地址边界，才能跳转下一状态
                            next_mem_state = DMA_MEM_IDLE;
                        else
                            next_mem_state = DMA_WRITE_MEM_REQ;
                    end
                end
            end

            default: begin

            end
        endcase
    end

    // 握手信号，通过组合逻辑输出
    always_comb begin
        m_c_obi_mem_if.s_req.req = 1'b0;
        m_c_obi_mem_if.req_payload = '0;

        unique case(mem_state)
            DMA_READ_MEM_REQ:begin
                // FIFO未满的情况下，发起请求
                if(!fifoFull && remain_mem_reg != 0) begin
                    m_c_obi_mem_if.s_req.req = 1'b1;
                    m_c_obi_mem_if.req_payload.addr = current_mem_addr;
                    m_c_obi_mem_if.req_payload.be   = 4'b1111;
                end
            end

            DMA_WRITE_MEM_REQ:begin
                // TODO：确定判断形式
                if(!fifoEmpty && remain_mem_reg != 0) begin
                    m_c_obi_mem_if.s_req.req = 1'b1;
                    m_c_obi_mem_if.req_payload.we = 1'b1;
                    m_c_obi_mem_if.req_payload.addr = current_mem_addr;
                    m_c_obi_mem_if.req_payload.wdata = dmaBuffer[rdPtr];
                    m_c_obi_mem_if.req_payload.be   = 4'b1111;
                end
            end
            default: begin
            end
        endcase
    end

    // DMA写SPM的状态机
    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0)
            spm_state <= DMA_SPM_IDLE;
        else
            spm_state <= next_spm_state;
    end

    // 写SPM握手
    logic spm_accept;
    assign spm_accept = spm_req_valid && spm_req_ready;

    // 状态转移状态机
    always_comb begin
        next_spm_state = spm_state;
        unique case(spm_state)
            DMA_SPM_IDLE:begin
                // 同读主存一样，只有start寄存器拉高且目的地址对齐才开启SPM写
                if(start_fire) begin
                    if(cfg_valid)
                        next_spm_state = dir_reg[0] ? DMA_READ_SPM_REQ : DMA_WRITE_SPM_ACTIVE;
                    else
                        next_spm_state = DMA_SPM_FAIL;
                end
            end
            DMA_WRITE_SPM_ACTIVE:begin
                // 握手成功后回到初始IDLE状态
                // 这里检查条件为剩余字节数等于4，这是因为该状态下仍然发起了一次SPM请求和寄存器递减的操作
                if(spm_accept && remain_spm_reg == 32'd4) begin
                    next_spm_state = DMA_SPM_IDLE;
                end
            end
            DMA_READ_SPM_REQ:begin
                if(spm_accept)
                    next_spm_state = DMA_READ_SPM_WAIT;

            end
            DMA_READ_SPM_WAIT:begin
                if(spm_rsp_valid && spm_rsp_ready) begin
                    // 响应生效且正确时，应当检查地址生成器给出的访存地址，如果访存地址达到目的地址边界，才能跳转下一状态
                    next_spm_state = remain_spm_reg == 0 ? DMA_SPM_IDLE : DMA_READ_SPM_REQ;
                end
            end
            DMA_SPM_FAIL:begin
                // TODO:暂时没想好失败怎么处理，暂定直接跳转回初始状态
                next_spm_state = DMA_SPM_IDLE;
            end
            default:begin
            end
        endcase
    end

    // 组合逻辑输出
    always_comb begin
        spm_req_valid = '0;
        spm_req_addr = '0;
        spm_req_we = '0;
        spm_req_wdata = '0;
        spm_rsp_ready = '0;

        unique case(spm_state)
            // DMA_SPM_IDLE:begin

            // end
            DMA_WRITE_SPM_ACTIVE:begin
                // FIFO非空情况下，DMA发起握手
                if(!fifoEmpty && remain_spm_reg != 0) begin
                    spm_req_valid = 1'b1;
                    spm_req_we = 1'b1;
                    spm_req_addr = current_spm_addr;
                    spm_req_wdata = dmaBuffer[rdPtr];
                end
            end
            DMA_READ_SPM_REQ:begin
                if(!fifoFull && remain_spm_reg != 0) begin
                    spm_req_valid = 1'b1;
                    spm_req_we = 1'b0;
                    spm_req_addr = current_spm_addr;
                end
            end
            DMA_READ_SPM_WAIT:begin
                // 请求被adapter接收后才进入WAIT。响应可能被adapter保持，
                // 因而ready必须在WAIT状态拉高，不能只在REQ状态打一拍。
                spm_rsp_ready = !fifoFull;
            end
            default:begin
            end
        endcase
    end

    always_ff @(posedge clk, negedge rst_n) begin
        if(rst_n == 1'b0) begin
            current_spm_addr <= '0;
            remain_spm_reg <= '0;
        end
        else begin
            unique case(spm_state)
                DMA_SPM_IDLE:begin
                    if(start_fire) begin
                        // TODO:可能需要一个地址检查，判断是否属于SPM地址空间
                        current_spm_addr <= dir_reg[0] ? src_reg : dst_reg;
                        remain_spm_reg <= len_reg;
                    end
                end
                DMA_READ_SPM_REQ:begin
                    if(spm_accept) begin
                        remain_spm_reg <= remain_spm_reg - 32'd4;
                        current_spm_addr <= current_spm_addr + 32'd4;
                    end
                end
                DMA_WRITE_SPM_ACTIVE:begin
                    if(spm_accept) begin
                        remain_spm_reg <= remain_spm_reg - 32'd4;
                        current_spm_addr <= current_spm_addr + 32'd4;
                    end
                end
                default:begin
                end
            endcase
        end
    end

endmodule
