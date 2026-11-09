// Dedicated operand and sibling-result FIFOs isolate the iterative engine's clock.
module mdma_math_cdc #(
    parameter DIVIDE = 0, parameter SIGNED_OP = 0
) (
    input wire cpu_clk, fu_clk, reset, draining,
    input wire push_lhs, push_rhs,
    input wire [63:0] lhs_data, rhs_data,
    output wire lhs_full, rhs_full, lhs_almost_full, rhs_almost_full,
    input wire pop_result,
    output wire result_empty, progress, divide_error,
    output wire [127:0] result
);
    wire [63:0] a, b, lo, hi;
    wire lhs_empty, rhs_empty, output_full, done;
    wire [4:0] completed, result_count;
    reg busy, faulted;
    reg [4:0] lhs_written, rhs_written;
    (* async_reg = "true" *) reg fault_sync1, fault_sync2;
    (* async_reg = "true" *) reg [1:0] fu_reset;
    always @(posedge fu_clk or posedge reset)
        if (reset) fu_reset <= 2'b11; else fu_reset <= {fu_reset[0], 1'b0};

    wire take = !fu_reset[1] && !lhs_empty && !rhs_empty && !output_full && !busy && !faulted;
    wire division_by_zero = take && DIVIDE && b == 0;
    assign divide_error = fault_sync2;
    // Compare writes against completions visible in the CPU domain, so a
    // pending pair counts as progress during pointer synchronization too.
    assign progress = lhs_written != completed && rhs_written != completed && (result_count < 8 || draining);

    mdma_async_fifo lhs (
        .write_clk(cpu_clk), .read_clk(fu_clk), .reset(reset), .push(push_lhs), .pop(take),
        .write_data(lhs_data), .read_data(a), .full(lhs_full), .almost_full(lhs_almost_full), .empty(lhs_empty),
        .read_count(), .read_seen_write()
    );
    mdma_async_fifo rhs (
        .write_clk(cpu_clk), .read_clk(fu_clk), .reset(reset), .push(push_rhs), .pop(take),
        .write_data(rhs_data), .read_data(b), .full(rhs_full), .almost_full(rhs_almost_full), .empty(rhs_empty),
        .read_count(), .read_seen_write()
    );
    mdma_async_fifo #(.WIDTH(128)) results (
        .write_clk(fu_clk), .read_clk(cpu_clk), .reset(reset), .push(done), .pop(pop_result),
        .write_data(DIVIDE ? {lo, hi} : {hi, lo}), .read_data(result), .full(output_full),
        .empty(result_empty), .read_count(result_count), .read_seen_write(completed)
    );
    generate
        if (DIVIDE) begin: divider
            mdma_div #(.SIGNED_OP(SIGNED_OP)) operation (
                .clk(fu_clk), .reset(fu_reset[1]), .start(take && !division_by_zero),
                .lhs(a), .rhs(b), .done(done), .quotient(lo), .residue(hi)
            );
        end else begin: multiplier
            mdma_mul #(.SIGNED_OP(SIGNED_OP)) operation (
                .clk(fu_clk), .reset(fu_reset[1]), .start(take),
                .lhs(a), .rhs(b), .done(done), .lo(lo), .hi(hi)
            );
        end
    endgenerate

    always @(posedge fu_clk) begin
        if (fu_reset[1]) begin
            busy <= 0;
            faulted <= 0;
        end else if (division_by_zero)
            faulted <= 1;
        else if (take)
            busy <= 1;
        else if (done)
            busy <= 0;
    end

    always @(posedge cpu_clk) begin
        if (reset) begin
            lhs_written <= 0;
            rhs_written <= 0;
            fault_sync1 <= 0;
            fault_sync2 <= 0;
        end else begin
            lhs_written <= lhs_written + push_lhs;
            rhs_written <= rhs_written + push_rhs;
            fault_sync1 <= faulted;
            fault_sync2 <= fault_sync1;
        end
    end
endmodule
