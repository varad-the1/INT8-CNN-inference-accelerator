// wrom4.v
//
// Weight ROM split into FOUR banks, one per systolic-array column.
// Filter o of a layer lives in bank (o mod 4), so the four columns can each
// read their own filter's weight in the same clock.
// All three layers share one address space (layer base + group*K + k):
//     conv1: 0..17     conv2: 18..305     fc: 306..1505
// Contents come from data/wbank0.hex .. wbank3.hex (made by gen_tile_vectors.py).
// Synchronous read: the data appears one clock after the address.

module wrom4 #(
    parameter AW       = 11,
    parameter DEPTH    = 2048,
    parameter DATA_DIR = "data/"
) (
    input  wire            clk,
    input  wire [4*AW-1:0] raddr,   // {col3, col2, col1, col0}
    output reg  [31:0]     rdata    // {col3, col2, col1, col0}, 8 bits each
);

    reg [7:0] b0 [0:DEPTH-1];
    reg [7:0] b1 [0:DEPTH-1];
    reg [7:0] b2 [0:DEPTH-1];
    reg [7:0] b3 [0:DEPTH-1];

    initial begin
        $readmemh({DATA_DIR, "wbank0.hex"}, b0);
        $readmemh({DATA_DIR, "wbank1.hex"}, b1);
        $readmemh({DATA_DIR, "wbank2.hex"}, b2);
        $readmemh({DATA_DIR, "wbank3.hex"}, b3);
    end

    always @(posedge clk) begin
        rdata[ 7: 0] <= b0[raddr[0*AW +: AW]];
        rdata[15: 8] <= b1[raddr[1*AW +: AW]];
        rdata[23:16] <= b2[raddr[2*AW +: AW]];
        rdata[31:24] <= b3[raddr[3*AW +: AW]];
    end

endmodule
