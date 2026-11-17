`timescale 1ns/1ps

// tb_micro_cnn.v (or .sv)
//
// Full MNIST inference testbench for the supplied micro-cnn model.
// Vivado-compatible with zero Active/NBA race conditions.
//
// DUT does ONLY the MAC work:
//   Conv1 MAC -> Conv2 MAC -> FC MAC
//
// Testbench does:
//   activation zero-point subtraction
//   bias addition
//   exact gemmlowp/TFLite-style requantization
//   2x2 stride-2 max-pooling
//   flattening
//   argmax
//   comparison against ref_logits.mem
//
// Memory files are 16-bit sign-extended values except 32-bit bias/M0 data.
//
// NOTE:
//   This testbench assumes the 4x4 systolic_array uses the PE shown in
//   processing_element.v: registered A/B forwarding and accumulator MAC.
//   The array is instantiated with N=4.
//
// Data layout:
//   conv1_w: [oc][ic][kh][kw] = [o][0][kh][kw]
//   conv2_w: [oc][ic][kh][kw]
//   fc_w:    [in_feature][out_feature], matching fc_w[i*10+o] in C
//
// The supplied model uses no ReLU. The only nonlinear layer operation is
// max-pooling.

module tb_microcnn;
    
    // Folder holding the .hex files, relative to the repository root (run the simulator from the root)
    localparam DATA_DIR = "data/";

    localparam integer N = 4;
    localparam integer DATA_WIDTH = 16;
    localparam integer ACC_WIDTH  = 32;

    localparam integer N_TESTS = 20;

    localparam integer IMG_H = 28;
    localparam integer IMG_W = 28;

    localparam integer C1_OC = 8;
    localparam integer C1_K  = 3;

    localparam integer C2_OC = 16;
    localparam integer C2_K  = 3;

    localparam integer FC_IN  = 400;
    localparam integer FC_OUT = 10;

    // Exact values from model_data.h
    localparam signed [31:0] CONV1_M0     = 32'sd2023435029;
    localparam integer       CONV1_SHIFT  = -9;
    localparam signed [31:0] CONV1_IN_ZP  = -32'sd128;
    localparam signed [31:0] CONV1_OUT_ZP = -32'sd128;

    localparam signed [31:0] CONV2_M0     = 32'sd1672637759;
    localparam integer       CONV2_SHIFT  = -8;
    localparam signed [31:0] CONV2_IN_ZP  = -32'sd128;
    localparam signed [31:0] CONV2_OUT_ZP = -32'sd128;

    localparam signed [31:0] FC_M0        = 32'sd1586550534;
    localparam integer       FC_SHIFT     = -10;
    localparam signed [31:0] FC_IN_ZP     = -32'sd128;
    localparam signed [31:0] FC_OUT_ZP    = -32'sd8;

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------

    reg clk;
    reg reset;

    reg signed [N*DATA_WIDTH-1:0] a_in_flat;
    reg signed [N*DATA_WIDTH-1:0] b_in_flat;
    wire signed [N*N*ACC_WIDTH-1:0] c_out_flat;

    wire signed [ACC_WIDTH-1:0] C_00, C_01, C_02, C_03;
    wire signed [ACC_WIDTH-1:0] C_10, C_11, C_12, C_13;
    wire signed [ACC_WIDTH-1:0] C_20, C_21, C_22, C_23;
    wire signed [ACC_WIDTH-1:0] C_30, C_31, C_32, C_33;

    SystolicArrayMod #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ROW       (N),
        .COL       (N)
    ) dut (
        .Clk   (clk),
        .Rst   (reset),
        .A_row0(a_in_flat[0*DATA_WIDTH +: DATA_WIDTH]),
        .A_row1(a_in_flat[1*DATA_WIDTH +: DATA_WIDTH]),
        .A_row2(a_in_flat[2*DATA_WIDTH +: DATA_WIDTH]),
        .A_row3(a_in_flat[3*DATA_WIDTH +: DATA_WIDTH]),
        .B_col0(b_in_flat[0*DATA_WIDTH +: DATA_WIDTH]),
        .B_col1(b_in_flat[1*DATA_WIDTH +: DATA_WIDTH]),
        .B_col2(b_in_flat[2*DATA_WIDTH +: DATA_WIDTH]),
        .B_col3(b_in_flat[3*DATA_WIDTH +: DATA_WIDTH]),
        .C_00  (C_00), .C_01(C_01), .C_02(C_02), .C_03(C_03),
        .C_10  (C_10), .C_11(C_11), .C_12(C_12), .C_13(C_13),
        .C_20  (C_20), .C_21(C_21), .C_22(C_22), .C_23(C_23),
        .C_30  (C_30), .C_31(C_31), .C_32(C_32), .C_33(C_33)
    );

    assign c_out_flat = {
        C_33, C_32, C_31, C_30,
        C_23, C_22, C_21, C_20,
        C_13, C_12, C_11, C_10,
        C_03, C_02, C_01, C_00
    };

    // ------------------------------------------------------------
    // Memories (.mem files for Vivado / simulation)
    // ------------------------------------------------------------

    // image.mem contains the original INT8 input values, sign-extended to 16 bits.
    // The testbench subtracts the layer input zero-point before each systolic MAC.
    reg signed [15:0] image_mem [0:N_TESTS*IMG_H*IMG_W-1];

    reg signed [15:0] conv1_w_mem [0:C1_OC*C1_K*C1_K-1];
    reg signed [31:0] conv1_b_mem [0:C1_OC-1];

    reg signed [15:0] conv2_w_mem [0:C2_OC*8*C2_K*C2_K-1];
    reg signed [31:0] conv2_b_mem [0:C2_OC-1];

    reg signed [15:0] fc_w_mem [0:FC_IN*FC_OUT-1];
    reg signed [31:0] fc_b_mem [0:FC_OUT-1];

    reg signed [15:0] test_labels_mem [0:N_TESTS-1];
    reg signed [15:0] ref_logits_mem [0:N_TESTS*FC_OUT-1];

    // ------------------------------------------------------------
    // Intermediate tensors
    // 16-bit containers for INT8 activations
    // ------------------------------------------------------------

    reg signed [15:0] image       [0:IMG_H-1][0:IMG_W-1];

    reg signed [15:0] conv1_out   [0:C1_OC-1][0:25][0:25];
    reg signed [15:0] pool1_out   [0:C1_OC-1][0:12][0:12];

    reg signed [15:0] conv2_out   [0:C2_OC-1][0:10][0:10];
    reg signed [15:0] pool2_out   [0:C2_OC-1][0:4][0:4];

    reg signed [15:0] final_logits[0:FC_OUT-1];

    // ------------------------------------------------------------
    // 4xK * Kx4 scratch matrices
    // ------------------------------------------------------------

    reg signed [15:0] mm_A [0:3][0:399];
    reg signed [15:0] mm_B [0:399][0:3];
    reg signed [31:0] mm_C [0:3][0:3];

    integer r, c, k;

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ------------------------------------------------------------
    // Reset (Non-blocking to eliminate Active-region race with PE)
    // ------------------------------------------------------------

    task automatic do_reset;
    begin
        a_in_flat <= 0;
        b_in_flat <= 0;
        reset     <= 1'b1;
        @(posedge clk);
        reset     <= 1'b0;
        @(posedge clk);
    end
    endtask

    // ------------------------------------------------------------
    // 4xK * Kx4 using the existing registered systolic array.
    //
    // A[r][k] enters left edge at t = k+r.
    // B[k][c] enters top edge at t = k+c.
    //
    // They meet at PE(r,c) at t = k+r+c.
    //
    // Since t starts at 0, the final PE(3,3) MAC for k=K-1 is at
    // t = (K-1)+3+3 = K+5.
    // We therefore apply K+6 input clock cycles.
    // ------------------------------------------------------------

    task automatic systolic_matmul_4xK(input integer Kdim);

        integer t;
        integer rr;
        integer cc;
        reg signed [15:0] aval;
        reg signed [15:0] bval;
        reg signed [N*DATA_WIDTH-1:0] next_a_flat;
        reg signed [N*DATA_WIDTH-1:0] next_b_flat;
        reg signed [N*N*ACC_WIDTH-1:0] captured_c_flat;

    begin
        do_reset;

        for (t = 0; t < Kdim + 2*N - 2; t = t + 1) begin
            next_a_flat = 0;
            next_b_flat = 0;

            for (rr = 0; rr < N; rr = rr + 1) begin
                aval = 16'sd0;

                if ((t >= rr) && ((t-rr) < Kdim))
                    aval = mm_A[rr][t-rr];

                next_a_flat[rr*DATA_WIDTH +: DATA_WIDTH] = aval;
            end

            for (cc = 0; cc < N; cc = cc + 1) begin
                bval = 16'sd0;

                if ((t >= cc) && ((t-cc) < Kdim))
                    bval = mm_B[t-cc][cc];

                next_b_flat[cc*DATA_WIDTH +: DATA_WIDTH] = bval;
            end

            // Drive inputs in NBA region: PE always samples prior stable cycle
            a_in_flat <= next_a_flat;
            b_in_flat <= next_b_flat;
            @(posedge clk);
        end

        // Clear driven inputs
        a_in_flat <= 0;
        b_in_flat <= 0;

        // Step 1ns past Active/NBA regions so all PE accumulators commit to memory
        #1;

        // Capture systolic-array outputs race-free
        captured_c_flat = c_out_flat;
        for (rr = 0; rr < 4; rr = rr + 1) begin
            for (cc = 0; cc < 4; cc = cc + 1) begin
                mm_C[rr][cc] =
                    $signed(captured_c_flat[(rr*N+cc)*ACC_WIDTH +: ACC_WIDTH]);
            end
        end
    end
    endtask

    // ------------------------------------------------------------
    // Exact C reference: sat_round_doubling_high_mul
    // ------------------------------------------------------------

    function automatic signed [31:0]
        sat_round_doubling_high_mul(
            input signed [31:0] a,
            input signed [31:0] b
        );

        reg signed [63:0] aa;
        reg signed [63:0] bb;
        reg signed [63:0] ab;
        reg signed [63:0] nudge;
        reg signed [63:0] result;

    begin
        if ((a == 32'sh80000000) && (b == 32'sh80000000)) begin
            sat_round_doubling_high_mul = 32'sh7fffffff;
        end
        else begin
            aa = a;
            bb = b;
            ab = aa * bb;

            if (ab >= 0)
                nudge = 64'sd1073741824;             // 1 << 30
            else
                nudge = -64'sd1073741823;            // 1 - (1 << 30)

            result = (ab + nudge) / 64'sd2147483648; // 1 << 31

            if (result > 64'sd2147483647)
                sat_round_doubling_high_mul = 32'sh7fffffff;
            else if (result < -64'sd2147483648)
                sat_round_doubling_high_mul = 32'sh80000000;
            else
                sat_round_doubling_high_mul = result[31:0];
        end
    end
    endfunction

    // ------------------------------------------------------------
    // Exact C reference: rounding_divide_by_pot
    // ------------------------------------------------------------

    function automatic signed [31:0]
        rounding_divide_by_pot(
            input signed [31:0] x,
            input integer exponent
        );

        reg signed [31:0] mask;
        reg signed [31:0] remainder;
        reg signed [31:0] threshold;

    begin
        if (exponent == 0) begin
            rounding_divide_by_pot = x;
        end
        else begin
            mask = (32'sd1 <<< exponent) - 1;
            remainder = x & mask;
            threshold = (mask >>> 1) + ((x < 0) ? 1 : 0);

            rounding_divide_by_pot =
                (x >>> exponent) +
                ((remainder > threshold) ? 1 : 0);
        end
    end
    endfunction

    // ------------------------------------------------------------
    // Exact C reference: micro_cnn_requantize
    // ------------------------------------------------------------

    function automatic signed [15:0]
        requantize_int8(
            input signed [31:0] acc,
            input signed [31:0] m0,
            input integer shift,
            input signed [31:0] out_zp
        );

        integer left_shift;
        integer right_shift;

        reg signed [31:0] x;
        reg signed [31:0] high;
        reg signed [31:0] out;

    begin
        if (shift > 0) begin
            left_shift = shift;
            right_shift = 0;
        end
        else begin
            left_shift = 0;
            right_shift = -shift;
        end

        if (left_shift != 0)
            x = acc <<< left_shift;
        else
            x = acc;

        high = sat_round_doubling_high_mul(x, m0);

        out = rounding_divide_by_pot(high, right_shift) + out_zp;

        if (out < -128)
            out = -128;
        else if (out > 127)
            out = 127;

        requantize_int8 = out[15:0];
    end
    endfunction

    // ------------------------------------------------------------
    // Max pool 1: 8x26x26 -> 8x13x13
    // ------------------------------------------------------------

    task automatic maxpool1;
        integer ch, rr, cc;
        reg signed [15:0] m;
        reg signed [15:0] x1;
        reg signed [15:0] x2;
        reg signed [15:0] x3;

    begin
        for (ch = 0; ch < 8; ch = ch + 1) begin
            for (rr = 0; rr < 13; rr = rr + 1) begin
                for (cc = 0; cc < 13; cc = cc + 1) begin

                    m  = conv1_out[ch][2*rr][2*cc];
                    x1 = conv1_out[ch][2*rr][2*cc+1];
                    x2 = conv1_out[ch][2*rr+1][2*cc];
                    x3 = conv1_out[ch][2*rr+1][2*cc+1];

                    if (x1 > m) m = x1;
                    if (x2 > m) m = x2;
                    if (x3 > m) m = x3;

                    pool1_out[ch][rr][cc] = m;
                end
            end
        end
    end
    endtask

    // ------------------------------------------------------------
    // Max pool 2: 16x11x11 -> 16x5x5
    // ------------------------------------------------------------

    task automatic maxpool2;
        integer ch, rr, cc;
        reg signed [15:0] m;
        reg signed [15:0] x1;
        reg signed [15:0] x2;
        reg signed [15:0] x3;

    begin
        for (ch = 0; ch < 16; ch = ch + 1) begin
            for (rr = 0; rr < 5; rr = rr + 1) begin
                for (cc = 0; cc < 5; cc = cc + 1) begin

                    m  = conv2_out[ch][2*rr][2*cc];
                    x1 = conv2_out[ch][2*rr][2*cc+1];
                    x2 = conv2_out[ch][2*rr+1][2*cc];
                    x3 = conv2_out[ch][2*rr+1][2*cc+1];

                    if (x1 > m) m = x1;
                    if (x2 > m) m = x2;
                    if (x3 > m) m = x3;

                    pool2_out[ch][rr][cc] = m;
                end
            end
        end
    end
    endtask

    // ------------------------------------------------------------
    // Conv1
    //
    // Input:  1x28x28
    // Output: 8x26x26
    // K = 3x3x1 = 9
    //
    // Tiling:
    //   A = 4 spatial patches x 9
    //   B = 9 x 4 output filters
    // ------------------------------------------------------------

    task automatic run_conv1;

        integer obase, pbase;
        integer rr, cc;
        integer pos;
        integer py, px;
        integer kh, kw;
        integer kk;
        integer o;
        reg signed [31:0] acc;

    begin
        for (obase = 0; obase < 8; obase = obase + 4) begin
            for (pbase = 0; pbase < 26*26; pbase = pbase + 4) begin

                // A: 4 image patches
                for (rr = 0; rr < 4; rr = rr + 1) begin
                    pos = pbase + rr;

                    if (pos < 26*26) begin
                        py = pos / 26;
                        px = pos % 26;
                    end
                    else begin
                        py = 0;
                        px = 0;
                    end

                    for (kh = 0; kh < 3; kh = kh + 1) begin
                        for (kw = 0; kw < 3; kw = kw + 1) begin
                            kk = kh*3 + kw;

                            if (pos < 26*26)
                                mm_A[rr][kk] =
                                    image[py+kh][px+kw]
                                    - CONV1_IN_ZP;
                            else
                                mm_A[rr][kk] = 16'sd0;
                        end
                    end
                end

                // B: four filters
                for (kk = 0; kk < 9; kk = kk + 1) begin
                    kh = kk / 3;
                    kw = kk % 3;

                    for (cc = 0; cc < 4; cc = cc + 1) begin
                        o = obase + cc;

                        if (o < 8)
                            mm_B[kk][cc] =
                                conv1_w_mem[o*9 + kh*3 + kw];
                        else
                            mm_B[kk][cc] = 16'sd0;
                    end
                end

                systolic_matmul_4xK(9);

                // Add filter bias and requantize
                for (rr = 0; rr < 4; rr = rr + 1) begin
                    pos = pbase + rr;

                    if (pos < 26*26) begin
                        py = pos / 26;
                        px = pos % 26;

                        for (cc = 0; cc < 4; cc = cc + 1) begin
                            o = obase + cc;

                            if (o < 8) begin
                                acc = mm_C[rr][cc] + conv1_b_mem[o];

                                conv1_out[o][py][px] =
                                    requantize_int8(
                                        acc,
                                        CONV1_M0,
                                        CONV1_SHIFT,
                                        CONV1_OUT_ZP
                                    );
                            end
                        end
                    end
                end
            end
        end
    end
    endtask

    // ------------------------------------------------------------
    // Conv2
    //
    // Input:  8x13x13
    // Output: 16x11x11
    // K = 8x3x3 = 72
    //
    // A = 4 spatial patches x 72
    // B = 72 x 4 output filters
    // ------------------------------------------------------------

    task automatic run_conv2;

        integer obase, pbase;
        integer rr, cc;
        integer pos;
        integer py, px;
        integer ch, kh, kw;
        integer kk;
        integer o;
        reg signed [31:0] acc;

    begin
        for (obase = 0; obase < 16; obase = obase + 4) begin
            for (pbase = 0; pbase < 11*11; pbase = pbase + 4) begin

                // A: four patches
                for (rr = 0; rr < 4; rr = rr + 1) begin
                    pos = pbase + rr;

                    if (pos < 11*11) begin
                        py = pos / 11;
                        px = pos % 11;
                    end
                    else begin
                        py = 0;
                        px = 0;
                    end

                    kk = 0;

                    for (ch = 0; ch < 8; ch = ch + 1) begin
                        for (kh = 0; kh < 3; kh = kh + 1) begin
                            for (kw = 0; kw < 3; kw = kw + 1) begin

                                if (pos < 11*11)
                                    mm_A[rr][kk] =
                                        pool1_out[ch][py+kh][px+kw]
                                        - CONV2_IN_ZP;
                                else
                                    mm_A[rr][kk] = 16'sd0;

                                kk = kk + 1;
                            end
                        end
                    end
                end

                // B: four filters
                for (kk = 0; kk < 72; kk = kk + 1) begin
                    ch = kk / 9;
                    kh = (kk % 9) / 3;
                    kw = kk % 3;

                    for (cc = 0; cc < 4; cc = cc + 1) begin
                        o = obase + cc;

                        if (o < 16)
                            mm_B[kk][cc] =
                                conv2_w_mem[
                                    o*72 + ch*9 + kh*3 + kw
                                ];
                        else
                            mm_B[kk][cc] = 16'sd0;
                    end
                end

                systolic_matmul_4xK(72);

                // Add bias and requantize
                for (rr = 0; rr < 4; rr = rr + 1) begin
                    pos = pbase + rr;

                    if (pos < 11*11) begin
                        py = pos / 11;
                        px = pos % 11;

                        for (cc = 0; cc < 4; cc = cc + 1) begin
                            o = obase + cc;

                            if (o < 16) begin
                                acc = mm_C[rr][cc] + conv2_b_mem[o];

                                conv2_out[o][py][px] =
                                    requantize_int8(
                                        acc,
                                        CONV2_M0,
                                        CONV2_SHIFT,
                                        CONV2_OUT_ZP
                                    );
                            end
                        end
                    end
                end
            end
        end
    end
    endtask

    // ------------------------------------------------------------
    // FC
    //
    // Input: 400
    // Output:10
    //
    // For a single image there are only 10 output neurons, so each
    // group of four columns is useful. The four rows of A are copies
    // of the same input vector; this allows the current 4x4 array to
    // be used without changing the PE/array interface.
    //
    // B = 400 x 4
    // A = 4 x 400
    // C = 4 x 4
    //
    // Read row 0 of C.
    // ------------------------------------------------------------

    task automatic run_fc;

        integer obase;
        integer i_f;
        integer rr, cc;
        integer o;
        reg signed [31:0] acc;

    begin
        for (obase = 0; obase < 10; obase = obase + 4) begin

            // A: duplicate the 400-element feature vector on four rows
            for (rr = 0; rr < 4; rr = rr + 1) begin
                for (i_f = 0; i_f < 400; i_f = i_f + 1) begin
                    mm_A[rr][i_f] =
                        pool2_out[i_f/25]
                                  [(i_f%25)/5]
                                  [i_f%5]
                        - FC_IN_ZP;
                end
            end

            // B: four FC output neurons
            for (i_f = 0; i_f < 400; i_f = i_f + 1) begin
                for (cc = 0; cc < 4; cc = cc + 1) begin
                    o = obase + cc;

                    if (o < 10)
                        mm_B[i_f][cc] = fc_w_mem[i_f*10 + o];
                    else
                        mm_B[i_f][cc] = 16'sd0;
                end
            end

            // NOTE: FC quantization constants must come from model_data.h.
            // They are parameterized here so the file compiles after the
            // actual values are inserted.

            systolic_matmul_4xK(400);

            for (cc = 0; cc < 4; cc = cc + 1) begin
                o = obase + cc;

                if (o < 10) begin
                    acc = mm_C[0][cc] + fc_b_mem[o];

                    final_logits[o] =
                        requantize_int8(
                            acc,
                            FC_M0,
                            FC_SHIFT,
                            FC_OUT_ZP
                        );
                end
            end
        end
    end
    endtask

    // ------------------------------------------------------------
    // Load image into 2D array
    // ------------------------------------------------------------

    task automatic load_image(input integer sample);

        integer rr, cc;

    begin
        for (rr = 0; rr < IMG_H; rr = rr + 1)
            for (cc = 0; cc < IMG_W; cc = cc + 1)
                image[rr][cc] =
                    image_mem[sample*784 + rr*28 + cc];
    end
    endtask

    // ------------------------------------------------------------
    // Main test
    // ------------------------------------------------------------

    integer t;
    integer o;
    integer pred;
    integer correct;
    integer mismatch_count;
    reg image_mismatch;

    initial begin

        // Load all generated memories
        $readmemh({DATA_DIR, "image.hex"}, image_mem);

        $readmemh({DATA_DIR, "conv1_w.hex"}, conv1_w_mem);
        $readmemh({DATA_DIR, "conv1_b.hex"}, conv1_b_mem);

        $readmemh({DATA_DIR, "conv2_w.hex"}, conv2_w_mem);
        $readmemh({DATA_DIR, "conv2_b.hex"}, conv2_b_mem);

        $readmemh({DATA_DIR, "fc_w.hex"}, fc_w_mem);
        $readmemh({DATA_DIR, "fc_b.hex"}, fc_b_mem);

        $readmemh({DATA_DIR, "test_labels.hex"}, test_labels_mem);
        $readmemh({DATA_DIR, "ref_logits.hex"}, ref_logits_mem);

        reset = 1'b1;
        a_in_flat = 0;
        b_in_flat = 0;

        correct = 0;
        mismatch_count = 0;
        repeat (15) begin
            @(posedge clk);
        end
        reset <= 1'b1;

        for (t = 0; t < N_TESTS; t = t + 1) begin
            
            load_image(t);

            run_conv1;
            maxpool1;

            run_conv2;
            maxpool2;

            run_fc;

            // argmax
            pred = 0;

            for (o = 1; o < 10; o = o + 1)
                if (final_logits[o] > final_logits[pred])
                    pred = o;

            if (pred == test_labels_mem[t]) begin
                correct = correct + 1;
                $display(
                    "sample %0d: PASS prediction=%0d label=%0d",
                    t,
                    pred,
                    $signed(test_labels_mem[t])
                );
            end
            else begin
                $display(
                    "sample %0d: FAIL prediction=%0d label=%0d",
                    t,
                    pred,
                    $signed(test_labels_mem[t])
                );
            end

        end

        $display("");
        $display("==============================================");
        $display("micro-cnn systolic-array test");
        $display("accuracy: %0d/%0d", correct, N_TESTS);
        $display("==============================================");

        if (correct == N_TESTS)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");

        $finish;
    end

endmodule