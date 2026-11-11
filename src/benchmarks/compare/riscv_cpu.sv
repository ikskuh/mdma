// Adapt RV32 transfers to the existing byte-masked, 64-bit SoC ports.
module mdma_compare_riscv (
    input wire clk, reset,
    output wire i_req_valid,
    output wire [63:0] i_req_addr,
    input wire i_req_ready, i_rsp_valid, i_rsp_error,
    input wire [63:0] i_rsp_data,
    output wire d_req_valid, d_req_write,
    output wire [63:0] d_req_addr, d_req_data,
    output wire [7:0] d_req_mask,
    input wire d_req_ready, d_rsp_valid, d_rsp_error,
    input wire [63:0] d_rsp_data,
    output reg halted,
    output reg [3:0] fault,
    output reg [31:0] ticks
);
    wire i_request, d_request, d_write, core_trap;
    wire [31:0] i_address, d_address, d_write_data;
    wire [3:0] d_bytes;
    reg i_high, d_high, marker_reply, write_reply;
    reg [31:0] exit_code;
    wire active = !reset && !halted;

    // VexRiscv's upstream generator boots at 0x80000000. Its linked RAM
    // window aliases the same physical BRAM used by the other cores.
    function automatic [63:0] physical(input [31:0] address);
        `ifdef MDMA_COMPARE_VEX
        if (address[31:18] == 14'h2000)
            physical = {46'b0, address[17:0]};
        else
        `endif
            physical = {32'b0, address};
    endfunction

    wire marker = d_write && (d_address == 32'hffffffd0 ||
                             d_address == 32'hffffffd4 || d_address == 32'hffffffd8);
    wire i_gnt = i_req_valid && i_req_ready;
    wire d_gnt = active && d_request && (marker || d_req_ready);
    wire d_done = marker_reply || d_rsp_valid;
    wire bench_start = d_gnt && marker && d_address[3:2] == 0;
    wire bench_end = d_gnt && marker && d_address[3:2] == 1;
    wire bench_exit = d_gnt && marker && d_address[3:2] == 2;
    wire [31:0] i_data = i_high ? i_rsp_data[63:32] : i_rsp_data[31:0];
    wire [31:0] d_data = d_high ? d_rsp_data[63:32] : d_rsp_data[31:0];

    assign i_req_valid = active && i_request;
    assign i_req_addr = physical({i_address[31:3], 3'b0});
    assign d_req_valid = active && d_request && !marker;
    assign d_req_write = d_write;
    // BRAM indexes by 64-bit word, while MMIO decodes the full address.
    assign d_req_addr = physical({d_address[31:2], 2'b0});
    assign d_req_data = {d_write_data, d_write_data};
    assign d_req_mask = d_address[2] ? {d_bytes, 4'b0} : {4'b0, d_bytes};

    always @(posedge clk) begin
        if (reset) begin
            i_high <= 0;
            d_high <= 0;
            marker_reply <= 0;
            write_reply <= 0;
            halted <= 0;
            fault <= 0;
            ticks <= 0;
            exit_code <= 0;
        end else begin
            marker_reply <= d_gnt && marker;
            write_reply <= d_gnt && d_write;
            if (i_gnt) i_high <= i_address[2];
            if (d_gnt) d_high <= d_address[2];
            if (!halted) begin
                ticks <= ticks + 1;
                if (core_trap || (d_rsp_valid && d_rsp_error) ||
                    (i_rsp_valid && i_rsp_error)) begin
                    halted <= 1;
                    fault <= 4'd1;
                end else if (bench_exit) begin
                    halted <= 1;
                    exit_code <= d_write_data;
                end
            end
        end
    end

    `ifdef MDMA_COMPARE_PICO
    wire mem_valid, mem_instr;
    wire [31:0] mem_addr;
    reg busy;
    wire mem_ready = i_rsp_valid || d_done;
    always @(posedge clk)
        if (reset || mem_ready) busy <= 0;
        else if (i_gnt || d_gnt) busy <= 1;

    assign i_request = mem_valid && mem_instr && !busy;
    assign d_request = mem_valid && !mem_instr && !busy;
    assign i_address = mem_addr;
    assign d_address = mem_addr;
    assign d_write = |d_bytes;

    picorv32 #(
        .PROGADDR_RESET(32'h80), .BARREL_SHIFTER(1),
        .ENABLE_FAST_MUL(1), .ENABLE_DIV(1)
    ) core (
        .clk(clk), .resetn(!reset), .trap(core_trap), .irq(32'b0),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(d_write_data), .mem_wstrb(d_bytes),
        .mem_rdata(mem_instr ? i_data : d_data), .pcpi_wr(1'b0),
        .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0)
    );

    `elsif MDMA_COMPARE_SERV
    wire i_cycle, d_cycle;
    reg i_busy, d_busy;
    always @(posedge clk) begin
        if (reset || i_rsp_valid) i_busy <= 0;
        else if (i_gnt) i_busy <= 1;
        if (reset || d_done) d_busy <= 0;
        else if (d_gnt) d_busy <= 1;
    end
    assign i_request = i_cycle && !i_busy;
    assign d_request = d_cycle && !d_busy;
    assign core_trap = 0;

    serv_rf_top #(.RESET_PC(32'h80), .W(1), .WITH_CSR(0)) core (
        .clk(clk), .i_rst(reset), .i_timer_irq(1'b0),
        .o_ibus_adr(i_address), .o_ibus_cyc(i_cycle),
        .i_ibus_rdt(i_data), .i_ibus_ack(i_rsp_valid),
        .o_dbus_adr(d_address), .o_dbus_cyc(d_cycle), .o_dbus_we(d_write),
        .o_dbus_dat(d_write_data), .o_dbus_sel(d_bytes),
        .i_dbus_rdt(d_data), .i_dbus_ack(d_done),
        .i_ext_rd(32'b0), .i_ext_ready(1'b0)
    );

    `elsif MDMA_COMPARE_IBEX
    wire double_fault;
    assign core_trap = double_fault;

    ibex_top #(
        .RV32M(ibex_pkg::RV32MFast), .RegFile(ibex_pkg::RegFileFF),
        .BranchTargetALU(1), .WritebackStage(1), .ICache(0)
    ) core (
        .clk_i(clk), .rst_ni(!reset), .test_en_i(1'b1),
        .hart_id_i(32'b0), .boot_addr_i(32'b0),
        .cheriot_enable_i(ibex_pkg::IbexMuBiOff),
        .ram_cfg_icache_tag_i('0), .ram_cfg_icache_data_i('0),
        .trvk_heap_base_addr_i(32'b0), .trvk_revbm_gnt_i(1'b0),
        .trvk_revbm_rvalid_i(1'b0), .trvk_revbm_rdata_i(32'b0),
        .trvk_revbm_rdata_intg_i(7'b0), .trvk_revbm_err_i(1'b0),
        .fetch_enable_i(ibex_pkg::IbexMuBiOn),
        .mcounteren_writable_i(ibex_pkg::IbexMuBiOff),
        .scan_rst_ni(!reset), .double_fault_seen_o(double_fault),
        .instr_req_o(i_request), .instr_addr_o(i_address),
        .instr_gnt_i(i_gnt), .instr_rvalid_i(i_rsp_valid),
        .instr_rdata_i(i_data), .instr_rdata_intg_i(7'b0), .instr_err_i(i_rsp_error),
        .data_req_o(d_request), .data_addr_o(d_address), .data_we_o(d_write),
        .data_be_o(d_bytes), .data_wdata_o(d_write_data), .data_gnt_i(d_gnt),
        .data_rvalid_i(d_done), .data_rdata_i(d_data), .data_rdata_intg_i(7'b0),
        .data_tag_i(1'b0), .data_err_i(d_rsp_error),
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
        .irq_fast_i(15'b0), .irq_nm_i(1'b0), .debug_req_i(1'b0),
        .scramble_key_valid_i(1'b0), .scramble_key_i('0), .scramble_nonce_i('0)
    );

    `elsif MDMA_COMPARE_VEX
    assign core_trap = 0;

    VexRiscv core (
        .clk(clk), .reset(reset),
        .timerInterrupt(1'b0), .softwareInterrupt(1'b0), .externalInterrupt(1'b0),
        .debugReset(reset), .debug_bus_cmd_valid(1'b0), .debug_bus_cmd_payload_wr(1'b0),
        .debug_bus_cmd_payload_address('0), .debug_bus_cmd_payload_data('0),
        .iBus_cmd_valid(i_request), .iBus_cmd_ready(active && i_req_ready),
        .iBus_cmd_payload_pc(i_address), .iBus_rsp_valid(i_rsp_valid),
        .iBus_rsp_payload_inst(i_data), .iBus_rsp_payload_error(i_rsp_error),
        .dBus_cmd_valid(d_request), .dBus_cmd_ready(active && (marker || d_req_ready)),
        .dBus_cmd_payload_address(d_address), .dBus_cmd_payload_wr(d_write),
        .dBus_cmd_payload_data(d_write_data), .dBus_cmd_payload_mask(d_bytes),
        .dBus_rsp_ready(d_done && !write_reply), .dBus_rsp_data(d_data),
        .dBus_rsp_error(d_rsp_error)
    );
    `endif
endmodule
