// bias_rom.v
//
// The 34 int32 biases: conv1 (8) at 0..7, conv2 (16) at 8..23, fc (10) at 24..33.
// Contents from data/bias.hex (made by gen_layer_vectors.py).
// Combinational read: the value follows the address with no clock delay.

module bias_rom #(
    parameter DATA_DIR = "data/"
) (
    input  wire [5:0]         addr,
    output wire signed [31:0] data
);

    reg [31:0] mem [0:63];

    initial $readmemh({DATA_DIR, "bias.hex"}, mem);

    assign data = mem[addr];

endmodule
