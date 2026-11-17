// maxpool4.v
//
// Picks the largest of the four values in one 2x2 pooling window.
// Hardware version of the inner part of maxpool1 / maxpool2 in tb_microcnn.v
// (and maxpool2() in reference/micro_cnn_ref.py).
//
// The controller decides WHICH four pixels to send (the window position);
// this block only does the comparison. 1-clock latency.

module maxpool4 (
    input  wire              clk,
    input  wire              valid_in,
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    input  wire signed [7:0] c,
    input  wire signed [7:0] d,
    output reg               valid_out,
    output reg  signed [7:0] y
);

    // two comparisons side by side, then one to pick the winner
    wire signed [7:0] max_ab = (b > a) ? b : a;
    wire signed [7:0] max_cd = (d > c) ? d : c;

    always @(posedge clk) begin
        valid_out <= valid_in;
        y         <= (max_cd > max_ab) ? max_cd : max_ab;
    end

endmodule
