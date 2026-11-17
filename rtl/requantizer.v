// requantizer.v
//
// Turns a 32-bit accumulator into an int8 activation.
// Hardware version of requantize() in reference/micro_cnn_ref.py
// (and requantize_int8 in tb/tb_microcnn.v). Bit-exact with both.
//
//   result = clamp( round(acc * M0 / 2^31) / 2^shift_r  +  out_zp , -128, 127 )
//
// The caller adds the bias to the sum BEFORE this block (acc = sum + bias).
// All shifts in this model are right shifts (shift = -9, -8, -10 in the
// testbench), so the input is the right-shift amount shift_r = -shift.
//
// 5-stage pipeline: a new input can be accepted every clock, and the result
// appears 5 clocks later together with valid_out.

module requantizer (
    input  wire               clk,
    input  wire               valid_in,
    input  wire signed [31:0] acc,       // sum + bias
    input  wire signed [31:0] m0,        // layer multiplier
    input  wire        [4:0]  shift_r,   // right shift, 0..31
    input  wire signed [31:0] out_zp,    // output zero-point
    output reg                valid_out,
    output reg  signed [7:0]  result
);

    // ---- stage 1: 32x32 -> 64-bit product ---------------------------------
    reg                v1;
    reg signed [63:0]  prod;
    reg                ovf1;             // the one overflow case: MIN * MIN
    reg        [4:0]   sh1;
    reg signed [31:0]  zp1;

    always @(posedge clk) begin
        v1   <= valid_in;
        prod <= acc * m0;
        ovf1 <= (acc == 32'sh80000000) && (m0 == 32'sh80000000);
        sh1  <= shift_r;
        zp1  <= out_zp;
    end

    // ---- stage 2: add the rounding nudge -----------------------------------
    // nudge = +2^30 for positive products, 1-2^30 for negative ones
    wire signed [63:0] nudge = (prod >= 0) ? 64'sd1073741824 : -64'sd1073741823;

    reg                v2;
    reg signed [63:0]  num;
    reg                ovf2;
    reg        [4:0]   sh2;
    reg signed [31:0]  zp2;

    always @(posedge clk) begin
        v2   <= v1;
        num  <= prod + nudge;
        ovf2 <= ovf1;
        sh2  <= sh1;
        zp2  <= zp1;
    end

    // ---- stage 3: divide by 2^31, truncating toward zero (C / semantics) ----
    // An arithmetic shift rounds toward -inf; for a negative number with any
    // discarded bits set, add 1 to get round-toward-zero.
    wire               adj  = num[63] && (|num[30:0]);
    wire signed [32:0] quot = $signed(num[63:31]) + $signed({32'd0, adj});

    reg                v3;
    reg signed [31:0]  high;
    reg        [4:0]   sh3;
    reg signed [31:0]  zp3;

    always @(posedge clk) begin
        v3   <= v2;
        high <= ovf2 ? 32'sh7fffffff : quot[31:0];
        sh3  <= sh2;
        zp3  <= zp2;
    end

    // ---- stage 4: rounding shift right ---------------------------------------
    wire        [31:0] mask      = (32'd1 << sh3) - 32'd1;
    wire        [31:0] remainder = high & mask;
    wire        [31:0] threshold = (mask >> 1) + (high[31] ? 32'd1 : 32'd0);

    reg                v4;
    reg signed [31:0]  shifted;
    reg                round_up;
    reg signed [31:0]  zp4;

    always @(posedge clk) begin
        v4       <= v3;
        shifted  <= high >>> sh3;
        round_up <= (remainder > threshold);
        zp4      <= zp3;
    end

    // ---- stage 5: add rounding bit and zero-point, clamp to int8 -------------
    wire signed [33:0] total = $signed(shifted)
                             + $signed({33'd0, round_up})
                             + $signed(zp4);

    always @(posedge clk) begin
        valid_out <= v4;
        if (total > 34'sd127)
            result <= 8'sd127;
        else if (total < -34'sd128)
            result <= -8'sd128;
        else
            result <= total[7:0];
    end

endmodule
