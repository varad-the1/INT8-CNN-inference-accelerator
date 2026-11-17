// uart_rx.v
//
// 8N1 serial receiver. `valid` pulses for one clock when a byte has arrived.
// Samples in the middle of each bit. CLKS_PER_BIT = clock frequency / baud rate
// (100 MHz / 115200 = 868).

module uart_rx #(
    parameter CLKS_PER_BIT = 868
) (
    input  wire       clk,
    input  wire       rx,
    output reg        valid,
    output reg  [7:0] data
);

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg [1:0]  state = S_IDLE;
    reg [15:0] cnt   = 16'd0;
    reg [2:0]  bit_i = 3'd0;
    reg        rx1 = 1'b1, rx2 = 1'b1;           // synchronizer: rx is asynchronous

    always @(posedge clk) begin
        rx1 <= rx;
        rx2 <= rx1;
        valid <= 1'b0;

        case (state)
        S_IDLE: if (!rx2) begin                   // falling edge = start bit
            cnt   <= 16'd0;
            state <= S_START;
        end

        S_START: begin                            // check the start bit again at its middle
            if (cnt == (CLKS_PER_BIT / 2) - 1) begin
                cnt <= 16'd0;
                if (!rx2) begin
                    bit_i <= 3'd0;
                    state <= S_DATA;
                end else
                    state <= S_IDLE;              // glitch, not a real start bit
            end else
                cnt <= cnt + 16'd1;
        end

        S_DATA: begin
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt         <= 16'd0;
                data[bit_i] <= rx2;               // LSB first
                if (bit_i == 3'd7) state <= S_STOP;
                else               bit_i <= bit_i + 3'd1;
            end else
                cnt <= cnt + 16'd1;
        end

        S_STOP: begin
            if (cnt == CLKS_PER_BIT - 1) begin
                valid <= 1'b1;                    // byte is in `data`
                state <= S_IDLE;
                cnt   <= 16'd0;
            end else
                cnt <= cnt + 16'd1;
        end
        endcase
    end

endmodule
