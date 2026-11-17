// demo_rom.v
//
// The 20 test images (784 bytes each, int8) stored on the chip, so the board can
// run a demo with no PC: image n is at addresses n*784 .. n*784+783.
// Contents from data/demo_images.hex (made by reference/gen_demo_images.py).
// Synchronous read: data appears one clock after the address.

module demo_rom #(
    parameter DATA_DIR = "data/"
) (
    input  wire        clk,
    input  wire [13:0] addr,
    output reg  [7:0]  data
);

    reg [7:0] mem [0:16383];

    initial $readmemh({DATA_DIR, "demo_images.hex"}, mem);

    always @(posedge clk) data <= mem[addr];

endmodule
