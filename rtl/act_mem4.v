// act_mem4.v
//
// Activation memory with FOUR identical copies, one per systolic-array row.
// Every write goes to all four copies; each copy has its own read port, so
// the four rows can read four different addresses in the same clock.
// Synchronous read: the data appears one clock after the address.

module act_mem4 #(
    parameter AW    = 12,
    parameter DEPTH = 4096
) (
    input  wire              clk,
    input  wire              we,
    input  wire [AW-1:0]     waddr,
    input  wire signed [7:0] wdata,
    input  wire [4*AW-1:0]   raddr,   // {row3, row2, row1, row0}
    output reg  [31:0]       rdata    // {row3, row2, row1, row0}, 8 bits each
);

    reg signed [7:0] m0 [0:DEPTH-1];
    reg signed [7:0] m1 [0:DEPTH-1];
    reg signed [7:0] m2 [0:DEPTH-1];
    reg signed [7:0] m3 [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            m0[waddr] <= wdata;
            m1[waddr] <= wdata;
            m2[waddr] <= wdata;
            m3[waddr] <= wdata;
        end
        rdata[ 7: 0] <= m0[raddr[0*AW +: AW]];
        rdata[15: 8] <= m1[raddr[1*AW +: AW]];
        rdata[23:16] <= m2[raddr[2*AW +: AW]];
        rdata[31:24] <= m3[raddr[3*AW +: AW]];
    end

endmodule
