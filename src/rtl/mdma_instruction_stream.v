// Raw ordered words only. The consumer chooses how many words to remove.
module mdma_instruction_stream (
    input wire clk, reset, enable, flush,
    input wire [63:0] restart_address,
    input wire [1:0] pop_count,
    output reg [63:0] head_address,
    output wire [63:0] word0, word1,
    output wire [1:0] valid, error,
    output reg [6:0] count,
    output wire wb_cyc, wb_stb,
    output wire [63:0] wb_adr,
    input wire wb_stall,
    input wire [63:0] wb_dat,
    input wire wb_ack, wb_err
);
    (* ram_style = "distributed" *) reg [64:0] even_words [0:31];
    (* ram_style = "distributed" *) reg [64:0] odd_words [0:31];
    reg [5:0] read_pointer, write_pointer;
    reg [6:0] outstanding;
    reg [63:0] request_address;
    reg cancel_cycle, fetch_failed;
    wire [5:0] second_pointer = read_pointer + 1'b1;
    wire [64:0] even_head = even_words[read_pointer[0] ? second_pointer[5:1] : read_pointer[5:1]];
    wire [64:0] odd_head = odd_words[read_pointer[5:1]];
    wire [64:0] first = read_pointer[0] ? odd_head : even_head;
    wire [64:0] second = read_pointer[0] ? even_head : odd_head;
    assign word0 = first[63:0];
    assign word1 = second[63:0];
    assign error = {second[64], first[64]};
    assign valid = {count >= 2, count != 0};
    assign wb_cyc = enable && !reset && !cancel_cycle;
    assign wb_stb = wb_cyc && !fetch_failed && count + outstanding < 64;
    assign wb_adr = request_address;
    wire request = wb_cyc && wb_stb && !wb_stall;
    // A zero-wait slave may terminate a request on its acceptance edge.
    wire response = wb_cyc && (outstanding != 0 || request) && (wb_ack || wb_err);

    always @(posedge clk) begin
        if (response && !flush) begin
            if (write_pointer[0])
                odd_words[write_pointer[5:1]] <= {wb_err, wb_dat};
            else
                even_words[write_pointer[5:1]] <= {wb_err, wb_dat};
        end
        if (reset || flush) begin
            read_pointer <= 0;
            write_pointer <= 0;
            count <= 0;
            outstanding <= 0;
            head_address <= reset ? 64'b0 : restart_address;
            request_address <= reset ? 64'b0 : restart_address;
            fetch_failed <= 0;
            cancel_cycle <= !reset;
        end else begin
            cancel_cycle <= 0;
            count <= count + {6'b0, response} - {5'b0, pop_count};
            outstanding <= outstanding + {6'b0, request} - {6'b0, response};
            read_pointer <= read_pointer + {4'b0, pop_count};
            head_address <= head_address + {59'b0, pop_count, 3'b0};
            if (request)
                request_address <= request_address + 64'd8;
            if (response) begin
                write_pointer <= write_pointer + 1'b1;
                if (wb_err)
                    fetch_failed <= 1;
            end
        end
    end
endmodule
