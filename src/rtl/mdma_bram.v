// Shared synchronous program and data memory. An accepted request at edge N
// has valid data or a write completion for the client to sample at edge N+1.
`ifndef MDMA_BRAM_PORTS
`define MDMA_BRAM_PORTS 1
`endif
module mdma_bram #(
    parameter integer PORTS = `MDMA_BRAM_PORTS,
    parameter INIT_FILE = ""
) (
    input wire clk, reset,
    input wire i_valid,
    input wire [14:0] i_addr,
    output wire i_ready,
    output reg i_reply,
    output wire [63:0] i_data,
    input wire d_valid, d_write,
    input wire [14:0] d_addr,
    input wire [63:0] d_data,
    input wire [7:0] d_mask,
    output wire d_ready,
    output reg d_reply,
    output reg [63:0] d_result
);
    // The interlock prevents cross-port read/write collisions.
    // This allows one physical EBR copy with native byte enables.
    (* ram_style = "block", no_rw_check *) reg [63:0] words [0:32767];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, words);

    assign d_ready = !reset;
    wire take_data = d_valid && d_ready;
    wire write_data = take_data && d_write;
    wire collision = write_data && (|d_mask) && i_addr == d_addr;
    assign i_ready = !reset && (PORTS == 2 ? !collision : !take_data);
    wire take_instruction = i_valid && i_ready;
    wire [14:0] port_a_addr = PORTS == 2 || take_data ? d_addr : i_addr;

    integer lane;
    always @(posedge clk) begin
        i_reply <= take_instruction;
        d_reply <= take_data;
        if (write_data)
            for (lane = 0; lane < 8; lane = lane + 1)
                if (d_mask[lane])
                    words[port_a_addr][8*lane +: 8] <= d_data[8*lane +: 8];
        if ((take_data && !d_write) || (PORTS == 1 && take_instruction))
            d_result <= words[port_a_addr];
    end

    generate if (PORTS == 2) begin: instruction_port
        reg [63:0] result;
        always @(posedge clk)
            if (take_instruction)
                result <= words[i_addr];
        assign i_data = result;
    end else begin: shared_port
        assign i_data = d_result;
    end endgenerate
endmodule
