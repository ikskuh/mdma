// ECP5 transport network. Each input has its own FIFO. Each FU publishes all
// sibling outputs into a single wide FIFO with independent read/write ports.
`ifndef MDMA_FAST_ALU
`define MDMA_FAST_ALU 2
`endif
module mdma_cpu (
    input wire clk, reset,
    input wire [3:0] math_clk,
    output wire i_req_valid,
    output wire [63:0] i_req_addr,
    input wire i_req_ready, i_rsp_valid, i_rsp_error,
    input wire [63:0] i_rsp_data,
    output wire d_req_valid, d_req_write,
    output wire [7:0] d_req_mask,
    output wire [63:0] d_req_addr, d_req_data,
    input wire d_req_ready, d_rsp_valid, d_rsp_error,
    input wire [63:0] d_rsp_data,
    output reg halted,
    output reg [3:0] fault,
    output reg [31:0] ticks
);
`include "mdma_ports.vh"

    localparam [3:0] FAULT_RESERVED_SINK = 1, FAULT_RESERVED_SOURCE = 2,
        FAULT_MEMORY = 3, FAULT_DIV_ZERO = 4, FAULT_TYPE = 5,
        FAULT_ALIGNMENT = 6, FAULT_PC = 7, FAULT_STALL = 8;
    localparam FAST_ALU = `MDMA_FAST_ALU;

    reg [63:0] pc, next_pc, constant_value, saved_jump;
    reg constant_ready, jump_redirected, halt_requested;
    reg execute_valid, draining, predicate_needed, synchronized_moves, jump_pending;
    reg [4:0] relative_slots;
    reg pc_conflict, relative_capture, jump_relative;
    reg [4:0] pending, staged_mask;
    reg [63:0] staged_data [0:4];
    reg [4:0] writeback_active;
    reg [63:0] writeback_data [0:4];

    wire stopped = halted || fault != 0;
    wire [63:0] fetch_pc, stream_word0, stream_word1;
    wire [1:0] stream_valid, stream_error, stream_pop;
    wire [6:0] stream_count;
    wire fetch_error, fetch_accept, fetch_slot_ready, replace_execute;
    wire redirect;
    wire [63:0] target;
    wire fetch_enabled = !draining && !halt_requested && !stopped && fetch_pc[2:0] == 0;
    mdma_instruction_stream stream (
        .clk(clk), .reset(reset), .enable(fetch_enabled), .flush(redirect),
        .restart_address(target), .pop_count(stream_pop),
        .head_address(fetch_pc), .word0(stream_word0), .word1(stream_word1),
        .valid(stream_valid), .error(stream_error), .count(stream_count),
        .req_valid(i_req_valid), .req_addr(i_req_addr), .req_ready(i_req_ready),
        .rsp_valid(i_rsp_valid), .rsp_error(i_rsp_error), .rsp_data(i_rsp_data)
    );
    // Only the decoder knows that the next word is a pending constant.
    wire pending_constant = execute_valid && !constant_ready;
    wire constant_capture = pending_constant && stream_valid[0] && !stream_error[0] && !stopped;
    wire [63:0] fetched = pending_constant ? stream_word1 : stream_word0;
    wire fetched_valid = pending_constant ? stream_valid[1] : stream_valid[0];
    wire fetched_error = pending_constant ? stream_error[1] : stream_error[0];
    wire [63:0] fetched_address = fetch_pc + (pending_constant ? 64'd8 : 64'd0);
    wire extended = fetched[61:60] == 1;
    wire new_constant_ready = !extended || (!pending_constant && stream_valid[1]);
    wire [29:0] fetched_sinks;
    wire [4:0] decoded_relative;
    function [29:0] decode_sinks(input [63:0] instruction);
        integer slot;
        reg [8:0] sum;
        begin
            sum = 0;
            for (slot = 0; slot < 5; slot = slot + 1) begin
                sum = sum + {3'b0, instruction[slot*12+6 +: 6]} + (slot != 0);
                decode_sinks[slot*6 +: 6] = sum >= 63 ? 6'd63 : sum[5:0];
            end
        end
    endfunction
    assign fetched_sinks = decode_sinks(fetched);

    reg [63:0] new_constant;
    always @* begin
        case (fetched[61:60])
            0: new_constant = 1;
            1: new_constant = stream_word1;
            2: new_constant = {52'b0, fetched[59:48]};
            default: new_constant = {{52{fetched[59]}}, fetched[59:48]};
        endcase
    end
    wire [63:0] fetch_plus_word = fetched_address + 64'd8;
    wire [63:0] fetch_plus_immediate = fetched_address + 64'd16;
    wire [63:0] fetch_next = fetched[61:60] == 1 ? fetch_plus_immediate : fetch_plus_word;
    wire instruction_ready = execute_valid && !stopped;

    wire [63:0] input_empty, input_full, input_pop, input_push;
    wire [63:0] input_almost_full, dispatch_full, dispatch_push, writeback_push;
    wire [3:0] input_count [0:63];
    wire [63:0] input_head [0:63], input_data [0:63];
    wire [63:0] source_value [0:63];
    wire [63:0] source_ready;
    wire [31:0] result_empty, result_full, result_pop, take, publish, unit_progress, divide_fault;
    wire pack_type_bad = |input_head[39][63:3];
    wire unpack_type_bad = |input_head[42][63:3];
    wire pack_alignment_bad = misaligned(input_head[38][2:0], input_head[39][2:1]);
    wire unpack_alignment_bad = misaligned(input_head[41][2:0], input_head[42][2:1]);

    assign source_value[0] = 0;
    assign source_value[1] = constant_value;
    assign source_value[2] = next_pc;
    assign source_value[59] = 0;
    assign source_value[60] = 0;
    assign source_ready[0] = 1;
    assign source_ready[1] = constant_ready;
    assign source_ready[2] = 1;
    assign source_ready[59] = 0;
    assign source_ready[60] = 0;

    wire forward_predicate = input_empty[62] && writeback_push[62];
    wire predicate_value = input_empty[62] ? |input_data[62] : input_head[62][0];
    wire take_predicate = instruction_ready && predicate_needed && (!input_empty[62] || forward_predicate);
    wire skip = take_predicate && !predicate_value;
    wire issue = instruction_ready && (!predicate_needed || (take_predicate && !skip));
    wire work_in_flight = (|writeback_active) || (|unit_progress);

    reg [5:0] src [0:4], dst [0:4];
    reg [4:0] group [0:4];
    wire [4:0] decoded_group [0:4];
    reg [4:0] bad_source, bad_sink, fifo_source;
    wire [63:0] transfer [0:4];
    wire [4:0] ready_moves, invalid_sink, commits, consumes, save, first_fault;
    wire all_ready = (ready_moves & pending) == pending;
    wire [4:0] faults = pending & (bad_source | invalid_sink);
    wire [4:0] stop_scan = faults | (synchronized_moves ? pending & ~ready_moves : 5'b0);
    wire can_commit = issue && !pc_conflict && (synchronized_moves ? all_ready : !(|faults));

    wire memory_fault;
    genvar slot, bank, u, lane, bit_index, port_index;
    generate
        for (slot = 0; slot < 5; slot = slot + 1) begin: move
            wire [5:0] decoded_src = fetched[slot*12 +: 6];
            wire [5:0] decoded_dst = fetched_sinks[slot*6 +: 6];
            assign decoded_relative[slot] = decoded_dst == SINK_PC_REL && (slot != 4 || !fetched[61]);
            assign decoded_group[slot] = source_fu(decoded_src);
            always @(posedge clk) if (fetch_accept) begin
                src[slot] <= decoded_src;
                dst[slot] <= decoded_dst;
                group[slot] <= decoded_group[slot];
                bad_source[slot] <= decoded_src == 59 || decoded_src == 60;
                bad_sink[slot] <= decoded_dst == 26 || (decoded_dst > SINK_PC_REL && decoded_dst <= 61);
                fifo_source[slot] <= decoded_src > 2;
            end
            localparam [4:0] EARLIER = (1 << slot) - 1;
            wire source_available, sink_full;
            mdma_port_select source_status (source_ready, src[slot], source_available);
            mdma_port_select sink_status (dispatch_full, dst[slot], sink_full);
            wire readable = staged_mask[slot] || source_available;
            assign invalid_sink[slot] = readable && bad_sink[slot];
            assign ready_moves[slot] = readable && !sink_full && !bad_sink[slot];
            assign commits[slot] = can_commit && pending[slot] && ready_moves[slot];
            // A synchronized instruction reports only faults before its first wait.
            assign first_fault[slot] = faults[slot] && !(|(stop_scan & EARLIER));
            assign consumes[slot] = commits[slot] && fifo_source[slot] && !staged_mask[slot];
            wire [63:0] selected_value;
            for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin: payload_bit
                wire [63:0] candidates;
                for (port_index = 0; port_index < 64; port_index = port_index + 1) begin: source_port
                    assign candidates[port_index] = source_value[port_index][bit_index];
                end
                mdma_payload_select select_payload (candidates, src[slot], selected_value[bit_index]);
            end
            assign transfer[slot] = staged_mask[slot] ? staged_data[slot] : selected_value;
            // Capture the five selected payloads before distributing them to the sinks.
            always @(posedge clk) begin
                writeback_data[slot] <= transfer[slot];
                writeback_active[slot] <= !reset && commits[slot] && dst[slot] != 0 &&
                                          !relative_slots[slot] && dst[slot] != 63;
            end
            assign save[slot] = pending[slot] && !commits[slot] && !staged_mask[slot] && fifo_source[slot] &&
                ((consumes[0] && group[0] == group[slot]) || (consumes[1] && group[1] == group[slot]) ||
                 (consumes[2] && group[2] == group[slot]) || (consumes[3] && group[3] == group[slot]) ||
                 (consumes[4] && group[4] == group[slot]));
            // Sample until a sibling pop makes this copy live. The save
            // decision then only clocks the valid bit, away from the data CE.
            always @(posedge clk)
                if (!staged_mask[slot])
                    staged_data[slot] <= selected_value;
        end
        for (bank = 0; bank < 64; bank = bank + 1) begin: sink
            if ((bank >= 1 && bank <= 51 && bank != 26) || bank == 62) begin: buffered
                wire [63:0] data;
                wire [4:0] from;
                assign from[0] = dst[0] == bank;
                assign from[1] = dst[1] == bank;
                assign from[2] = dst[2] == bank;
                assign from[3] = dst[3] == bank;
                assign from[4] = dst[4] == bank;
                wire [4:0] dispatch_from = from & commits;
                reg [4:0] writeback_from;
                reg writeback_valid;
                always @(posedge clk) begin
                    writeback_from <= from;
                    writeback_valid <= !reset && |dispatch_from;
                end
                assign data = (writeback_data[0] & {64{writeback_from[0]}}) |
                              (writeback_data[1] & {64{writeback_from[1]}}) |
                              (writeback_data[2] & {64{writeback_from[2]}}) |
                              (writeback_data[3] & {64{writeback_from[3]}}) |
                              (writeback_data[4] & {64{writeback_from[4]}});
                assign dispatch_push[bank] = |dispatch_from;
                assign writeback_push[bank] = writeback_valid;
                // The preceding instruction may already own the last free entry.
                assign dispatch_full[bank] = input_full[bank] ||
                                             (input_almost_full[bank] && writeback_push[bank]);
                assign input_data[bank] = data;
                if (bank == 62) begin: predicate
                    wire nonzero, reserved_empty;
                    assign input_push[bank] = writeback_push[bank];
                    assign input_empty[bank] = reserved_empty ||
                                               (writeback_push[bank] && input_count[bank] == 1);
                    assign input_almost_full[bank] = 0;
                    // COND queues eight independent truth values.
                    mdma_fifo #(.WIDTH(1)) fifo (
                        .clk(clk), .reset(reset), .push(input_push[bank]), .pop(input_pop[bank]),
                        .reserve(dispatch_push[bank]),
                        .data_in(|data), .data_out(nonzero), .count(input_count[bank]),
                        .empty(reserved_empty), .full(input_full[bank])
                    );
                    assign input_head[bank] = {63'b0, nonzero};
                end else if ((bank >= 15 && bank <= 22) || (bank >= 46 && bank <= 51)) begin: unit_operand
                    // Math owns its operand banks at the CDC boundary.
                    // STASH and STACK share a single direct storage bank with their source.
                    assign input_head[bank] = 0;
                    assign input_empty[bank] = 1;
                    assign input_count[bank] = 0;
                    if (bank <= 22)
                        assign input_push[bank] = writeback_push[bank];
                end else begin: core_operand
                    localparam CONDITION = bank == 28 || bank == 31;
                    localparam TYPE_CODE = bank == 39 || bank == 42;
                    localparam WIDTH = CONDITION ? 1 : TYPE_CODE ? 4 :
                                       (bank == 10 || bank == 12) ? 6 : bank == 23 ? 7 :
                                       bank == 37 ? 8 : bank == 41 ? 3 : bank == 45 ? 24 : 64;
                    wire [WIDTH-1:0] operand, head;
                    wire reserved_empty;
                    wire arriving_head = writeback_push[bank] && input_count[bank] == 1;
                    assign input_push[bank] = writeback_push[bank];
                    localparam FORWARD = FAST_ALU && (bank < 34 || bank > 37);
                    assign input_empty[bank] = reserved_empty ||
                                               (!FORWARD && arriving_head);
                    assign input_almost_full[bank] = 0;
                    if (CONDITION) begin: truth_value
                        assign operand = |data;
                    end else if (TYPE_CODE) begin: checked_type
                        assign operand = {|data[63:3], data[2:0]};
                    end else if (bank == 23) begin: mask_size
                        assign operand = {|data[63:6], data[5:0]};
                    end else begin: low_bits
                        assign operand = data[WIDTH-1:0];
                    end
                    // A reservation includes the word in writeback. Forward
                    // only when it is the sole reserved word; otherwise RAM
                    // still owns the oldest head. Both FIFO pointers advance
                    // normally if that arriving word is consumed.
                    assign input_head[bank] = {{(64-WIDTH){1'b0}}, (FORWARD && arriving_head ? operand : head)};
                    mdma_fifo #(.WIDTH(WIDTH), .BLOCK(WIDTH == 64)) fifo (
                        .clk(clk), .reset(reset), .push(input_push[bank]), .pop(input_pop[bank]),
                        .reserve(dispatch_push[bank]),
                        .data_in(operand), .data_out(head), .count(input_count[bank]),
                        .empty(reserved_empty), .full(input_full[bank])
                    );
                end
            end else begin: unbuffered
                assign input_push[bank] = 0;
                assign input_empty[bank] = 1;
                assign input_full[bank] = 0;
                assign input_almost_full[bank] = 0;
                assign dispatch_full[bank] = 0;
                assign dispatch_push[bank] = 0;
                assign writeback_push[bank] = 0;
                assign input_head[bank] = 0;
                assign input_count[bank] = 0;
                assign input_data[bank] = 0;
            end
        end
        for (u = 0; u < 32; u = u + 1) begin: unit
            if (u < FU_COUNT) begin: implemented
                localparam BASE = fu_base(u);
                localparam INS = fu_inputs(u);
                localparam OUTS = fu_outputs(u);
                localparam STACK = u == FU_STACK_A || u == FU_STACK_B;
                localparam TRANSPORT = STACK || (u >= FU_STASH_A && u <= FU_STASH_D);
                localparam ITERATIVE = u >= FU_MUL && u <= FU_DIVS;
                wire [OUTS*64-1:0] data_in, data_out;
                wire consumes_result;
                // All logical reads of sibling outputs request one physical pop.
                assign consumes_result = (consumes[0] && group[0] == u) || (consumes[1] && group[1] == u) ||
                                         (consumes[2] && group[2] == u) || (consumes[3] && group[3] == u) ||
                                         (consumes[4] && group[4] == u);
                assign result_pop[u] = consumes_result || (ITERATIVE && draining && !stopped && !result_empty[u]);
                for (lane = 0; lane < OUTS; lane = lane + 1) begin: source
                    localparam PORT = fu_source((u << 3) | lane);
                    assign source_ready[PORT] = !result_empty[u];
                    assign source_value[PORT] = data_out[lane*64 +: 64];
                end
                if (TRANSPORT) begin: direct
                    assign input_push[BASE] = writeback_push[BASE];
                    assign input_almost_full[BASE] = 0;
                    if (STACK) begin: stack
                        mdma_stack storage (
                            .clk(clk), .reset(reset), .reserve(dispatch_push[BASE]),
                            .push(input_push[BASE]), .pop(result_pop[u]),
                            .data_in(input_data[BASE]), .top(data_out),
                            .empty(result_empty[u]), .full(result_full[u])
                        );
                    end else begin: stash
                        mdma_stash storage (
                            .clk(clk), .reset(reset), .reserve(dispatch_push[BASE]),
                            .push(input_push[BASE]), .pop(result_pop[u]),
                            .data_in(input_data[BASE]), .data_out(data_out),
                            .empty(result_empty[u]), .full(result_full[u])
                        );
                    end
                    assign input_full[BASE] = result_full[u];
                    assign input_pop[BASE] = 0;
                    assign take[u] = 0;
                    assign publish[u] = input_push[BASE];
                    assign unit_progress[u] = 0;
                    assign divide_fault[u] = 0;
                end else if (ITERATIVE) begin: clocked_math
                    mdma_math_cdc #(
                        .DIVIDE(u == FU_DIV || u == FU_DIVS), .SIGNED_OP(u == FU_MULS || u == FU_DIVS)
                    ) engine (
                        .cpu_clk(clk), .fu_clk(math_clk[u-FU_MUL]), .reset(reset), .draining(draining),
                        .push_lhs(input_push[BASE]), .push_rhs(input_push[BASE+1]),
                        .lhs_data(input_data[BASE]), .rhs_data(input_data[BASE+1]),
                        .lhs_full(input_full[BASE]), .rhs_full(input_full[BASE+1]),
                        .lhs_almost_full(input_almost_full[BASE]), .rhs_almost_full(input_almost_full[BASE+1]),
                        .pop_result(result_pop[u]), .result_empty(result_empty[u]), .result(data_out),
                        .progress(unit_progress[u]), .divide_error(divide_fault[u])
                    );
                    assign result_full[u] = 0;
                    assign take[u] = 0;
                    assign publish[u] = 0;
                    assign input_pop[BASE +: 2] = 0;
                end else begin: local_clock
                    // Keep narrow results packed in the FIFO. Expand each
                    // lane to an ISA word only when the transport reads it.
                    localparam RESULT_BITS = u == FU_CMP ? OUTS : u == FU_BITCNT ? 7*OUTS :
                                             u == FU_PACK ? 136 : 64*OUTS;
                    wire [RESULT_BITS-1:0] stored_in, stored_out;
                    wire valid_result;
                    if (u == FU_PACK) begin: pack_result
                        assign valid_result = !FAST_ALU || (!pack_type_bad && !pack_alignment_bad);
                    end else if (u == FU_UNPACK) begin: unpack_result
                        assign valid_result = !FAST_ALU || (!unpack_type_bad && !unpack_alignment_bad);
                    end else begin: untyped_result
                        assign valid_result = 1;
                    end
                    wire enqueue_result = publish[u] && !draining && valid_result;
                    wire block_result = result_full[u] && !draining;
                    for (lane = 0; lane < OUTS; lane = lane + 1) begin: result_field
                        localparam BITS = u == FU_CMP ? 1 : u == FU_BITCNT ? 7 :
                                          (u == FU_PACK && lane == 1) ? 8 : 64;
                        localparam OFFSET = u == FU_PACK && lane != 0 ? 64 + 8*(lane-1) : lane*BITS;
                        assign stored_in[OFFSET +: BITS] = data_in[lane*64 +: BITS];
                        assign data_out[lane*64 +: 64] = {{(64-BITS){1'b0}}, stored_out[OFFSET +: BITS]};
                    end
                    mdma_fifo #(.WIDTH(RESULT_BITS)) results (
                        .clk(clk), .reset(reset), .reserve(enqueue_result), .push(enqueue_result), .pop(result_pop[u]),
                        .data_in(stored_in), .data_out(stored_out), .count(),
                        .empty(result_empty[u]), .full(result_full[u])
                    );
                    if (u == FU_MEM) begin: memory
                        wire take_store;
                        // Queue requests from operands that have reached RAM.
                        mdma_mem mem (
                            .clk(clk), .reset(reset), .enable(!stopped),
                            .read_count(input_count[34] - writeback_push[34]),
                            .write_count(input_count[35] - writeback_push[35]),
                            .data_count(input_count[36] - writeback_push[36]),
                            .mask_count(input_count[37] - writeback_push[37]),
                            .read_head(input_head[34]), .write_head(input_head[35]),
                            .data_head(input_head[36]), .mask_head(input_head[37]),
                            .take_read(take[u]), .take_store(take_store), .output_full(block_result),
                            .publish(publish[u]), .progress(unit_progress[u]), .bus_fault(memory_fault),
                            .result(data_in), .req_valid(d_req_valid), .req_write(d_req_write),
                            .req_mask(d_req_mask), .req_addr(d_req_addr), .req_data(d_req_data),
                            .req_ready(d_req_ready), .rsp_valid(d_rsp_valid),
                            .rsp_error(d_rsp_error), .rsp_data(d_rsp_data)
                        );
                        assign input_pop[34] = take[u];
                        assign input_pop[37:35] = {3{take_store}};
                        assign divide_fault[u] = 0;
                    end else begin: compute
                        for (lane = 0; lane < INS; lane = lane + 1) begin: operand
                            assign input_pop[BASE+lane] = take[u];
                        end
                        if (u == FU_SHIFT_A || u == FU_SHIFT_B) begin: shifter
                            mdma_shift #(.FAST(FAST_ALU)) engine (
                                .clk(clk), .reset(reset), .allow_start(!stopped),
                                .operands_ready(input_empty[BASE +: INS] == 0),
                                .output_full(block_result),
                                .value(input_head[BASE]), .count(input_head[BASE+1]), .take(take[u]),
                                .publish(publish[u]), .progress(unit_progress[u]), .results(data_in)
                            );
                        end else begin: general
                            wire [INS*64-1:0] operands_in, operands;
                            wire [OUTS*64-1:0] computed;
                            wire [63:0] a, b, c;
                            assign {c, b, a} = {{(3-INS)*64{1'b0}}, operands};
                            for (lane = 0; lane < INS; lane = lane + 1) begin: capture
                                assign operands_in[lane*64 +: 64] = input_head[BASE+lane];
                            end
                            if (FAST_ALU) begin: direct_result
                                assign operands = operands_in;
                                assign take[u] = !stopped && input_empty[BASE +: INS] == 0 && !block_result;
                                assign publish[u] = take[u];
                                assign unit_progress[u] = take[u];
                                assign data_in = computed;
                            end else begin: registered_result
                                mdma_fu_pipeline #(.INPUTS(INS), .OUTPUTS(OUTS)) pipeline (
                                    .clk(clk), .reset(reset), .allow_start(!stopped),
                                    .operands_ready(input_empty[BASE +: INS] == 0),
                                    .output_full(block_result),
                                    .operands_in(operands_in), .operands(operands), .computed(computed),
                                    .take(take[u]), .publish(publish[u]), .progress(unit_progress[u]),
                                    .results(data_in)
                                );
                            end
                            if (u == FU_ARITH_A || u == FU_ARITH_B) begin: arith
                                mdma_arith operation (a, b, computed);
                            end else if (u == FU_LOGIC_A || u == FU_LOGIC_B) begin: logic_unit
                                mdma_logic operation (a, b, computed);
                            end else if (u == FU_CMP) begin: compare
                                mdma_cmp operation (a, b, computed);
                            end else if (u == FU_MASK) begin: mask
                                mdma_mask operation (a, computed);
                            end else if (u == FU_UOP_A || u == FU_UOP_B) begin: unary
                                mdma_uop operation (a, computed);
                            end else if (u == FU_BITCNT) begin: count_bits
                                mdma_bitcnt operation (a, computed);
                            end else if (u == FU_SEL_A || u == FU_SEL_B) begin: select_word
                                mdma_sel operation (a, b, c, computed);
                            end else if (u == FU_PACK) begin: pack_bytes
                                mdma_pack operation (a, b, c, computed);
                            end else if (u == FU_UNPACK) begin: unpack_bytes
                                mdma_unpack operation (a, b, c, computed);
                            end else if (u == FU_SWIZZLE8) begin: swizzle
                                mdma_swizzle8 operation (a, b, computed);
                            end
                        end
                        assign divide_fault[u] = 0;
                    end
                end
            end else begin: unused
                assign result_pop[u] = 0;
                assign result_empty[u] = 1;
                assign result_full[u] = 0;
                assign take[u] = 0;
                assign publish[u] = 0;
                assign unit_progress[u] = 0;
                assign divide_fault[u] = 0;
            end
        end
    endgenerate

    assign input_pop[0] = 0;
    assign input_pop[26] = 0;
    assign input_pop[61:52] = 0;
    assign input_pop[62] = take_predicate;
    assign input_pop[63] = 0;

    // Sink zero can occur only in slot zero because later sinks are strictly increasing.
    wire jump_slot = pending[0] && dst[0] == 0;
    wire new_jump = commits[0] && jump_slot;
    wire new_relative = |(commits & relative_slots);
    wire [63:0] displacement = (writeback_data[0] & {64{relative_slots[0]}}) |
                               (writeback_data[1] & {64{relative_slots[1]}}) |
                               (writeback_data[2] & {64{relative_slots[2]}}) |
                               (writeback_data[3] & {64{relative_slots[3]}}) |
                               (writeback_data[4] & {64{relative_slots[4]}});
    wire [63:0] relative_target = next_pc + {displacement[60:0], 3'b0};
    // The relative payload is in writeback on the next clock. Keep next_pc
    // live until then, even if the relative move completed the pack.
    wire moves_done = skip || (issue && !pc_conflict && all_ready && !(|(pending & relative_slots)));
    wire done = execute_valid && moves_done && (constant_ready || constant_capture);
    assign redirect = instruction_ready && !jump_redirected && (new_jump || jump_pending) &&
                      (constant_ready || constant_capture);
    assign target = new_jump ? transfer[0] : relative_capture ? relative_target : saved_jump;
    wire target_halts = !jump_relative && (&target);
    assign replace_execute = !execute_valid || done;
    assign fetch_slot_ready = fetch_enabled && replace_execute && !redirect &&
                              (!pending_constant || constant_capture);
    assign fetch_error = (pending_constant && stream_valid[0] && stream_error[0]) ||
                         (fetch_slot_ready && fetched_valid &&
                          (fetched_error || (extended && !pending_constant && stream_valid[1] && stream_error[1])));
    assign fetch_accept = fetch_slot_ready && fetched_valid && !fetch_error;
    assign stream_pop = fetch_accept ? (pending_constant || (extended && stream_valid[1]) ? 2'd2 : 2'd1) :
                        constant_capture ? 2'd1 : 2'd0;
    function misaligned;
        input [2:0] address;
        input [1:0] size;
        misaligned = |(address & ((3'b001 << size) - 1'b1));
    endfunction
    wire type_fault = (take[FU_PACK] && pack_type_bad) || (take[FU_UNPACK] && unpack_type_bad);
    wire alignment_fault = (take[FU_PACK] && pack_alignment_bad) ||
                           (take[FU_UNPACK] && unpack_alignment_bad);

    always @(posedge clk) begin
        if (fetch_accept) begin
            pc <= fetched_address;
            next_pc <= fetch_next;
            constant_value <= new_constant;
            constant_ready <= new_constant_ready;
            predicate_needed <= fetched[63];
            synchronized_moves <= fetched[62];
            pending <= fetched[61] ? 5'b01111 : 5'b11111;
            staged_mask <= 0;
            jump_pending <= 0;
            relative_slots <= decoded_relative;
            pc_conflict <= fetched_sinks[5:0] == 0 && (|decoded_relative);
            relative_capture <= 0;
            jump_relative <= 0;
            jump_redirected <= 0;
            halt_requested <= 0;
        end else begin
            if (constant_capture) begin
                constant_value <= stream_word0;
                constant_ready <= 1;
            end
            predicate_needed <= predicate_needed && !take_predicate;
            pending <= skip ? 5'b0 : pending & ~commits;
            staged_mask <= staged_mask | save;
            jump_pending <= jump_pending || new_jump || new_relative;
            relative_capture <= new_relative;
            jump_relative <= jump_relative || new_relative;
            if (redirect) begin
                jump_redirected <= 1;
                halt_requested <= target_halts;
            end
        end
        if (new_jump)
            saved_jump <= transfer[0];
        else if (relative_capture)
            saved_jump <= relative_target;
        if (reset) begin
            constant_ready <= 0;
            pending <= 0;
            predicate_needed <= 0;
            jump_pending <= 0;
            relative_slots <= 0;
            pc_conflict <= 0;
            relative_capture <= 0;
            jump_relative <= 0;
            jump_redirected <= 0;
            halt_requested <= 0;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            fault <= 0;
            halted <= 0;
            ticks <= 0;
            execute_valid <= 0;
            draining <= 0;
        end else if (!stopped) begin
            ticks <= ticks + 1'b1;
            if (memory_fault || fetch_error)
                fault <= FAULT_MEMORY;
            else if (|divide_fault)
                fault <= FAULT_DIV_ZERO;
            else if (type_fault)
                fault <= FAULT_TYPE;
            else if (alignment_fault)
                fault <= FAULT_ALIGNMENT;
            else if (draining) begin
                if (!work_in_flight)
                    halted <= 1;
            end else if (!execute_valid && fetch_pc[2:0] != 0)
                fault <= FAULT_PC;
            else if (issue && pc_conflict)
                fault <= FAULT_RESERVED_SINK;
            else if (issue && |first_fault)
                fault <= |(first_fault & bad_source) ? FAULT_RESERVED_SOURCE : FAULT_RESERVED_SINK;
            else if (instruction_ready && !done && !pending_constant &&
                     !(|commits) && !take_predicate && !work_in_flight)
                fault <= FAULT_STALL;

            if (fetch_accept)
                execute_valid <= 1;
            else if (done) begin
                execute_valid <= 0;
                if (halt_requested || (redirect && target_halts))
                    draining <= 1;
            end
        end
    end
endmodule

// A 64 -> 16 -> 4 -> 1 selection uses one LUT4 level per tier. The ECP5
// wide mux in each PFU selects between its two LUT4 outputs locally.
module mdma_port_select (input wire [63:0] values, input wire [5:0] index, output wire selected);
`ifdef YOSYS
    wire [15:0] quarters;
    wire [3:0] groups;
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin: first
            mdma_port_mux4 select_value (values[4*i +: 4], index[1:0], quarters[i]);
        end
        for (i = 0; i < 4; i = i + 1) begin: second
            mdma_port_mux4 select_quarter (quarters[4*i +: 4], index[3:2], groups[i]);
        end
    endgenerate
    mdma_port_mux4 select_group (groups, index[5:4], selected);
`else
    assign selected = values[index];
`endif
endmodule

// A payload bit uses four local 16:1 muxes and one final 4:1 mux. The first
// tier fits in ECP5 LUT7 cascades and needs no general interconnect inside it.
module mdma_payload_select (input wire [63:0] values, input wire [5:0] index, output wire selected);
`ifdef YOSYS
    wire [3:0] groups;
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin: first
        mdma_payload_mux16 mux (values[16*i +: 16], index[3:0], groups[i]);
    end
    mdma_port_mux4 select_group (groups, index[5:4], selected);
`else
    assign selected = values[index];
`endif
endmodule

`ifdef YOSYS
module mdma_payload_mux16 (input wire [15:0] values, input wire [3:0] index, output wire selected);
    wire [3:0] quarters;
    wire [1:0] halves;
    genvar i;
    for (i = 0; i < 4; i = i + 1) begin: group
        mdma_port_mux4 mux (values[4*i +: 4], index[1:0], quarters[i]);
    end
    L6MUX21 mux_low (.D0(quarters[0]), .D1(quarters[1]), .SD(index[2]), .Z(halves[0]));
    L6MUX21 mux_high (.D0(quarters[2]), .D1(quarters[3]), .SD(index[2]), .Z(halves[1]));
    L6MUX21 mux_top (.D0(halves[0]), .D1(halves[1]), .SD(index[3]), .Z(selected));
endmodule

module mdma_port_mux4 (input wire [3:0] values, input wire [1:0] index, output wire selected);
    wire low_pair, high_pair;
    LUT4 #(.INIT(16'hcaca)) low (.A(values[0]), .B(values[1]), .C(index[0]), .D(1'b0), .Z(low_pair));
    LUT4 #(.INIT(16'hcaca)) high (.A(values[2]), .B(values[3]), .C(index[0]), .D(1'b0), .Z(high_pair));
    PFUMX mux (.ALUT(high_pair), .BLUT(low_pair), .C0(index[1]), .Z(selected));
endmodule
`endif
