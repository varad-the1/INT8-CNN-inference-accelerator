// uart_tx.v
//
// 8N1 serial transmitter. Pulse `start` for one clock with `data` set, while
// `busy` is low. `busy` is high from the clock after `start` until the stop bit
// has been sent.

module uart_tx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       start,
    input  wire [7:0] data,
    output reg        busy,
    output reg        txd
);

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg [1:0]  state = S_IDLE;
    reg [15:0] cnt   = 16'd0;
    reg [2:0]  bit_i = 3'd0;
    reg [7:0]  sh    = 8'd0;

    initial begin busy = 1'b0; txd = 1'b1; end

    always @(posedge clk) begin
        case (state)
        S_IDLE: begin
            txd <= 1'b1;
            if (start) begin
                sh    <= data;
                busy  <= 1'b1;
                cnt   <= 16'd0;
                state <= S_START;
            end
        end

        S_START: begin
            txd <= 1'b0;                          // start bit
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt   <= 16'd0;
                bit_i <= 3'd0;
                state <= S_DATA;
            end else
                cnt <= cnt + 16'd1;
        end

        S_DATA: begin
            txd <= sh[bit_i];                     // LSB first
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt <= 16'd0;
                if (bit_i == 3'd7) state <= S_STOP;
                else               bit_i <= bit_i + 3'd1;
            end else
                cnt <= cnt + 16'd1;
        end

        S_STOP: begin
            txd <= 1'b1;                          // stop bit
            if (cnt == CLKS_PER_BIT - 1) begin
                busy  <= 1'b0;
                state <= S_IDLE;
            end else
                cnt <= cnt + 16'd1;
        end
        endcase
    end

endmodule
