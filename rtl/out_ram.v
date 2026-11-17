// out_ram.v
//
// Plain RAM for layer outputs: one write port, one read port (synchronous read).
// Layer outputs are stored channel-major: address = out_base + o*npos + pos.

module out_ram #(
    parameter AW    = 14,
    parameter DEPTH = 16384
) (
    input  wire              clk,
    input  wire              we,
    input  wire [AW-1:0]     waddr,
    input  wire signed [7:0] wdata,
    input  wire [AW-1:0]     raddr,
    output reg  signed [7:0] rdata
);

    reg signed [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule
