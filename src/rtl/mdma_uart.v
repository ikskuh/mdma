// An 8-N-1 UART between raw serial pins and the byte-ready/valid interface.
module mdma_uart #(
    parameter CLOCKS_PER_BIT = 104
) (
    input wire clk, reset, serial_rx,
    output wire serial_tx,
    output reg [7:0] rx_data,
    output reg rx_valid,
    input wire rx_ready,
    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready
);
    localparam COUNTER_BITS = $clog2(CLOCKS_PER_BIT);
    reg [COUNTER_BITS-1:0] tx_wait, rx_wait;
    reg [9:0] tx_shift;
    reg [3:0] tx_bits, rx_bits;
    reg [7:0] rx_shift;
    (* async_reg = "true" *) reg rx_meta, rx_sync;

    assign serial_tx = tx_bits == 0 || tx_shift[0];
    assign tx_ready = tx_bits == 0;

    always @(posedge clk) begin
        if (reset) begin
            tx_bits <= 0;
            rx_bits <= 0;
            rx_valid <= 0;
            rx_meta <= 1;
            rx_sync <= 1;
        end else begin
            rx_meta <= serial_rx;
            rx_sync <= rx_meta;
            if (tx_ready && tx_valid) begin
                tx_shift <= {1'b1, tx_data, 1'b0};
                tx_wait <= CLOCKS_PER_BIT - 1;
                tx_bits <= 10;
            end else if (!tx_ready) begin
                if (tx_wait != 0)
                    tx_wait <= tx_wait - 1'b1;
                else begin
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_wait <= CLOCKS_PER_BIT - 1;
                    tx_bits <= tx_bits - 1'b1;
                end
            end
            if (rx_ready)
                rx_valid <= 0;
            if (rx_bits == 0) begin
                if (!rx_sync) begin
                    rx_wait <= CLOCKS_PER_BIT / 2 - 1;
                    rx_bits <= 10;
                end
            end else if (rx_wait != 0)
                rx_wait <= rx_wait - 1'b1;
            else begin
                rx_wait <= CLOCKS_PER_BIT - 1;
                rx_bits <= rx_bits - 1'b1;
                if (rx_bits == 10 && rx_sync)
                    rx_bits <= 0;
                if (rx_bits > 1 && rx_bits < 10)
                    rx_shift <= {rx_sync, rx_shift[7:1]};
                if (rx_bits == 1 && rx_sync && (!rx_valid || rx_ready)) begin
                    rx_data <= rx_shift;
                    rx_valid <= 1;
                end
            end
        end
    end
endmodule
