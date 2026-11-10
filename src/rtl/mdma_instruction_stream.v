// The two banks retain consumed raw words until new requests need their slots.
`ifndef MDMA_STREAM_WORDS
`define MDMA_STREAM_WORDS 16
`endif
`ifndef MDMA_STREAM_AHEAD_WORDS
`define MDMA_STREAM_AHEAD_WORDS (`MDMA_STREAM_WORDS / 2)
`endif
module mdma_instruction_stream #(
    parameter integer WORDS = `MDMA_STREAM_WORDS,
    parameter integer AHEAD_WORDS = `MDMA_STREAM_AHEAD_WORDS
) (
    input wire clk, reset, enable, flush,
    input wire [63:0] restart_address,
    input wire [1:0] pop_count,
    output reg [63:0] head_address,
    output wire [63:0] word0, word1,
    output wire [1:0] valid, error,
    output reg [6:0] count,
    output wire wb_cyc, wb_stb,
    output reg [63:0] wb_adr,
    input wire wb_stall,
    input wire [63:0] wb_dat,
    input wire wb_ack, wb_err
);
    localparam INDEX_BITS = $clog2(WORDS);
    localparam [6:0] CAPACITY = WORDS;
    localparam [6:0] HISTORY_WORDS = WORDS - AHEAD_WORDS;
    (* ram_style = "distributed" *) reg [64:0] even_words [0:WORDS/2-1];
    (* ram_style = "distributed" *) reg [64:0] odd_words [0:WORDS/2-1];
    reg [INDEX_BITS-1:0] write_pointer;
    reg [6:0] history, outstanding;
    reg [63:0] oldest_address, next_address, redirect_target;
    reg request_pending, redirect_lookup, cancel_cycle, fetch_failed;
    wire [INDEX_BITS-1:0] read_pointer = head_address[3 +: INDEX_BITS];
    wire [INDEX_BITS-1:0] second_pointer = read_pointer + 1'b1;
    wire [64:0] even_head = even_words[read_pointer[0] ? second_pointer[INDEX_BITS-1:1] :
                                                         read_pointer[INDEX_BITS-1:1]];
    wire [64:0] odd_head = odd_words[read_pointer[INDEX_BITS-1:1]];
    wire [64:0] first = read_pointer[0] ? odd_head : even_head;
    wire [64:0] second = read_pointer[0] ? even_head : odd_head;
    assign word0 = first[63:0];
    assign word1 = second[63:0];
    assign error = {second[64], first[64]};
    assign valid = redirect_lookup ? 2'b0 : {count >= 2, count != 0};
    assign wb_cyc = enable && !reset && !cancel_cycle;
    assign wb_stb = wb_cyc && request_pending;
    wire request = wb_stb && !wb_stall;
    wire response = wb_cyc && (outstanding != 0 || request) && (wb_ack || wb_err);
    wire [6:0] received = history + count;
    wire [6:0] occupied = received + outstanding + {6'b0, request_pending};

    // A full ring can grow at the tail only by reclaiming history beyond
    // the budget. That also puts reserved lookahead below AHEAD_WORDS.
    wire full = occupied == CAPACITY;
    wire reserve_word = wb_cyc && !fetch_failed && !(response && wb_err) &&
                        !flush && !redirect_lookup && (!request_pending || request) &&
                        (!full || history > HISTORY_WORDS);
    wire evict = reserve_word && full;

    // The registered target keeps the address comparison off the move path.
    wire [63:0] target_offset = redirect_target - oldest_address;
    wire redirect_hit = redirect_lookup && target_offset[2:0] == 0 &&
                        !(|target_offset[63:INDEX_BITS+3]) &&
                        target_offset[3 +: INDEX_BITS] < received;
    wire direct_restart = flush && restart_address[2:0] != 0;
    wire restart = direct_restart || (redirect_lookup && !redirect_hit);
    wire [63:0] restart_pc = direct_restart ? restart_address : redirect_target;

    always @(posedge clk) begin
        if (response && !restart) begin
            if (write_pointer[0])
                odd_words[write_pointer[INDEX_BITS-1:1]] <= {wb_err, wb_dat};
            else
                even_words[write_pointer[INDEX_BITS-1:1]] <= {wb_err, wb_dat};
        end
        if (reset || restart) begin
            write_pointer <= reset ? {INDEX_BITS{1'b0}} : restart_pc[3 +: INDEX_BITS];
            count <= 0;
            history <= 0;
            outstanding <= 0;
            head_address <= reset ? 64'b0 : restart_pc;
            oldest_address <= reset ? 64'b0 : restart_pc;
            next_address <= reset ? 64'b0 : restart_pc;
            request_pending <= 0;
            redirect_lookup <= 0;
            fetch_failed <= 0;
            cancel_cycle <= !reset;
        end else begin
            cancel_cycle <= 0;
            redirect_lookup <= flush;
            if (flush)
                redirect_target <= restart_address;
            if (redirect_hit) begin
                head_address <= redirect_target;
                // A seek may skip a speculative error while retaining later words.
                fetch_failed <= 0;
                history <= target_offset[3 +: INDEX_BITS];
                count <= received - target_offset[3 +: INDEX_BITS] + {6'b0, response};
            end else begin
                head_address <= head_address + {59'b0, pop_count, 3'b0};
                history <= history + {5'b0, pop_count} - {6'b0, evict};
                count <= count + {6'b0, response} - {5'b0, pop_count};
            end
            outstanding <= outstanding + {6'b0, request} - {6'b0, response};
            request_pending <= reserve_word || (request_pending && !request);
            if (evict)
                oldest_address <= oldest_address + 64'd8;
            if (reserve_word) begin
                wb_adr <= next_address;
                next_address <= next_address + 64'd8;
            end
            if (response) begin
                write_pointer <= write_pointer + 1'b1;
                if (wb_err)
                    fetch_failed <= 1;
            end
        end
    end
endmodule
