module mdma_fifo_tb #(
    parameter IMPLEMENTATION = 0,
    parameter DEPTH = 4,
    parameter WIDTH = 64
);
    reg clk = 0;
    reg reset = 0;
    reg [WIDTH-1:0] input_data;
    reg input_valid, output_take;
    wire input_take, output_valid;
    wire [WIDTH-1:0] output_data;

    mdma_fifo #(.IMPLEMENTATION(IMPLEMENTATION), .DEPTH(DEPTH), .WIDTH(WIDTH)) dut (
        .clk(clk), .reset(reset),
        .i_in_data(input_data), .i_in_valid(input_valid), .i_in_take(input_take),
        .o_out_data(output_data), .o_out_valid(output_valid), .o_out_take(output_take)
    );

    // Model shifts the oldest value out and appends new values at the end.
    reg [WIDTH-1:0] queue [0:DEPTH-1];
    integer count = 0;
    reg accepted_push, accepted_pop;

    function [WIDTH-1:0] pattern;
        input integer tag;
        reg [63:0] word;
        begin
            for (integer bit_index = 0; bit_index < WIDTH; bit_index = bit_index + 1) begin
                if (bit_index % 64 == 0)
                    word = (64'hfedcba9876543211 + tag + bit_index) * 64'h9e3779b97f4a7c15;
                pattern[bit_index] = word[bit_index % 64];
            end
        end
    endfunction

    task check_head;
        if (output_valid !== (!reset && count != 0))
            $fatal(1, "wrong output valid at occupancy %0d", count);
        else if (output_valid && output_data !== queue[0])
            $fatal(1, "head mismatch: got %h expected %h", output_data, queue[0]);
    endtask

    task cycle;
        input valid;
        input [WIDTH-1:0] data;
        input take, clear;
        begin
            reset = clear;
            input_valid = valid;
            input_data = data;
            output_take = take;
            #1;
            check_head;
            accepted_pop = !clear && take && count != 0;
            accepted_push = !clear && valid && (count < DEPTH || accepted_pop);
            if (input_take !== accepted_push)
                $fatal(1, "wrong input take at occupancy %0d", count);

            clk = 1;
            if (clear)
                count = 0;
            if (accepted_pop) begin
                count = count - 1;
                for (integer index = 0; index < count; index = index + 1)
                    queue[index] = queue[index + 1];
            end
            if (accepted_push) begin
                queue[count] = data;
                count = count + 1;
            end
            #1;
            check_head;
            clk = 0;
            #1;
        end
    endtask

    integer seed = 381;
    reg pending = 0;
    reg [WIDTH-1:0] pending_data;
    reg clear;

    initial begin
        cycle(1, pattern(1), 1, 1);
        cycle(1, pattern(2), 1, 0); // Empty push cannot pop on the same edge.
        for (integer index = 0; index < DEPTH * 3; index = index + 1) begin
            cycle(1, pattern(index + 3), 1, 0); // Replace the sole entry.
            cycle(0, '0, 0, 0);
        end
        for (integer index = 1; index < DEPTH; index = index + 1)
            cycle(1, pattern(index + 5), 0, 0);
        cycle(1, pattern(10), 0, 0); // Full and stalled.
        cycle(1, pattern(10), 1, 0);
        for (integer index = 0; index < DEPTH * 5; index = index + 1)
            cycle(1, pattern(index + 20), 1, 0);
        cycle(1, pattern(11), 1, 1); // Reset a full FIFO with a request on each port.
        cycle(0, '0, 1, 0);
        cycle(1, pattern(12), 0, 0);
        cycle(0, '0, 0, 0);

        seed = $urandom(seed);
        for (integer index = 0; index < 2000; index = index + 1) begin
            if (!pending) begin
                pending = $urandom_range(0, 3) != 0;
                pending_data = pattern(index + 1000);
            end
            clear = $urandom_range(0, 99) == 0;
            cycle(pending, pending_data, $urandom_range(0, 1) != 0, clear);
            if (accepted_push || clear)
                pending = 0;
        end
        cycle(pending, pending_data, 1, 0);
        repeat (DEPTH + 1)
            cycle(0, '0, 1, 0);
        $display("FIFO implementation %0d, %0dx%0d passed", IMPLEMENTATION, WIDTH, DEPTH);
        $finish;
    end
endmodule

module mdma_fifo_fu_tb;
    reg clk = 0, reset = 1;
    reg lhs_valid = 0, rhs_valid = 0, result_take = 0;
    reg [63:0] lhs_input, rhs_input;
    wire lhs_take, rhs_take;
    wire [63:0] lhs, rhs, add, sub;
    wire lhs_ready, rhs_ready, lhs_pop, rhs_pop;
    wire add_valid, sub_valid, group_push, result_valid;
    wire [127:0] result;

    mdma_fifo #(.IMPLEMENTATION(0)) lhs_fifo (
        .clk(clk), .reset(reset),
        .i_in_data(lhs_input), .i_in_valid(lhs_valid), .i_in_take(lhs_take),
        .o_out_data(lhs), .o_out_valid(lhs_ready), .o_out_take(lhs_pop)
    );

    mdma_fifo #(.IMPLEMENTATION(1)) rhs_fifo (
        .clk(clk), .reset(reset),
        .i_in_data(rhs_input), .i_in_valid(rhs_valid), .i_in_take(rhs_take),
        .o_out_data(rhs), .o_out_valid(rhs_ready), .o_out_take(rhs_pop)
    );

    mdma_arith arith (
        .clk(clk), .reset(reset),
        .i_lhs_data(lhs), .i_lhs_valid(lhs_ready), .i_lhs_take(lhs_pop),
        .i_rhs_data(rhs), .i_rhs_valid(rhs_ready), .i_rhs_take(rhs_pop),
        .o_add_data(add), .o_add_valid(add_valid), .o_add_take(group_push),
        .o_sub_data(sub), .o_sub_valid(sub_valid), .o_sub_take(1'b0)
    );

    mdma_fifo #(.IMPLEMENTATION(2), .WIDTH(128)) results (
        .clk(clk), .reset(reset),
        .i_in_data({sub, add}), .i_in_valid(add_valid && sub_valid), .i_in_take(group_push),
        .o_out_data(result), .o_out_valid(result_valid), .o_out_take(result_take)
    );

    task tick;
        begin
            #1 clk = 1;
            #1 clk = 0;
            #1;
        end
    endtask

    task send_lhs;
        input [63:0] value;
        begin
            lhs_input = value;
            lhs_valid = 1;
            #1;
            if (lhs_take !== 1)
                $fatal(1, "left FIFO did not accept its input");
            tick;
            lhs_valid = 0;
        end
    endtask

    task send_rhs;
        input [63:0] value;
        begin
            rhs_input = value;
            rhs_valid = 1;
            #1;
            if (rhs_take !== 1)
                $fatal(1, "right FIFO did not accept its input");
            tick;
            rhs_valid = 0;
        end
    endtask

    task receive;
        input [127:0] expected;
        integer clocks;
        begin
            clocks = 0;
            while (!result_valid && clocks < 20) begin
                tick;
                clocks = clocks + 1;
            end
            if (result_valid !== 1 || result !== expected)
                $fatal(1, "wrong grouped ARITH result: got %h expected %h", result, expected);
            tick;
            if (result_valid !== 1 || result !== expected)
                $fatal(1, "stalled grouped result changed");
            result_take = 1;
            tick;
            result_take = 0;
        end
    endtask

    initial begin
        tick;
        reset = 0;
        send_lhs(64'd10);
        send_lhs(64'hffff_ffff_ffff_ffff);
        send_rhs(64'd3);
        send_rhs(64'd1);
        receive({64'd7, 64'd13});
        receive({64'hffff_ffff_ffff_fffe, 64'b0});
        if (result_valid !== 0)
            $fatal(1, "unexpected extra grouped result");
        $display("FIFO → ARITH → grouped FIFO passed");
        $finish;
    end
endmodule
