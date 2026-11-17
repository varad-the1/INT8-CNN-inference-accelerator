`timescale 1ns/1ps

// Board-level test: drives the UART pin like a PC would and watches the reply,
// the LEDs and the display lines.
//   1. send 0xA5 + image 3 over the UART      -> expect digit = label 3
//   2. SW[4:0] = 5, press push button 1       -> expect digit = label 5, reply on the UART
// Baud rate and delays are shortened with parameters so the simulation is quick.

module tb_board_top;

    localparam DATA_DIR = "data/";
    localparam BIT = 16;                      // clocks per UART bit in this simulation

    reg clk100 = 1'b0;
    always #5 clk100 = ~clk100;

    reg         push1 = 1'b0;                 // not pressed = low
    reg  [15:0] SLIDE_SW = 16'd0;
    reg         rxd = 1'b1;
    wire [15:0] LED;
    wire sig_a, sig_b, sig_c, sig_d, sig_e, sig_f, sig_g, sig_pd;
    wire sel_disp1, sel_disp2, sel_disp3, sel_disp4;
    wire txd;

    board_top #(.CLKS_PER_BIT(BIT), .SETTLE(22'd300), .DEBOUNCE(20'd40),
                .TIMEOUT(27'd100000)) dut (
        .clk100(clk100), .push1(push1), .SLIDE_SW(SLIDE_SW), .LED(LED),
        .sig_a(sig_a), .sig_b(sig_b), .sig_c(sig_c), .sig_d(sig_d), .sig_e(sig_e),
        .sig_f(sig_f), .sig_g(sig_g), .sig_pd(sig_pd),
        .sel_disp1(sel_disp1), .sel_disp2(sel_disp2), .sel_disp3(sel_disp3), .sel_disp4(sel_disp4),
        .usb_uart_rxd(rxd), .usb_uart_txd(txd));

    reg [15:0] image_mem [0:20*784-1];
    reg [15:0] label_mem [0:19];

    integer i, errors;
    reg [7:0] r0, r1, r2, r3, r4;
    integer cyc;

    // ---- a PC sending one byte ----
    task send_byte(input [7:0] b);
        integer k;
        begin
            rxd <= 1'b0;                          // start bit
            repeat (BIT) @(posedge clk100);
            for (k = 0; k < 8; k = k + 1) begin
                rxd <= b[k];
                repeat (BIT) @(posedge clk100);
            end
            rxd <= 1'b1;                          // stop bit
            repeat (BIT) @(posedge clk100);
        end
    endtask

    // ---- a PC receiving one byte ----
    task recv_byte(output [7:0] b);
        integer k;
        begin
            @(negedge txd);                       // start bit
            repeat (BIT / 2) @(posedge clk100);
            for (k = 0; k < 8; k = k + 1) begin
                repeat (BIT) @(posedge clk100);
                b[k] = txd;
            end
            repeat (BIT) @(posedge clk100);       // stop bit
        end
    endtask

    task recv_reply;
        begin
            recv_byte(r0); recv_byte(r1); recv_byte(r2); recv_byte(r3); recv_byte(r4);
            cyc = {r1, r2, r3, r4};
        end
    endtask

    // digits 1..3 must never be selected
    integer other_on;
    initial other_on = 0;
    always @(posedge clk100)
        if (sel_disp1 !== 1'b1 || sel_disp2 !== 1'b1 || sel_disp3 !== 1'b1) other_on = other_on + 1;

    // ---- display watcher: remember the pattern shown on the right-most digit ----
    reg [6:0] right_seg;
    reg       right_seen;
    always @(posedge clk100)
        if (sel_disp4 == 1'b0 && sel_disp1 == 1'b1 && sel_disp2 == 1'b1 && sel_disp3 == 1'b1) begin
            right_seg  <= {sig_g, sig_f, sig_e, sig_d, sig_c, sig_b, sig_a};
            right_seen <= 1'b1;
        end

    function [6:0] seg_low(input [3:0] n);        // expected pin pattern, lit = LOW
        reg [6:0] hi;
        begin
            case (n)
                0: hi = 7'h3F; 1: hi = 7'h06; 2: hi = 7'h5B; 3: hi = 7'h4F; 4: hi = 7'h66;
                5: hi = 7'h6D; 6: hi = 7'h7D; 7: hi = 7'h07; 8: hi = 7'h7F; default: hi = 7'h6F;
            endcase
            seg_low = ~hi;
        end
    endfunction

    initial begin
        errors = 0; right_seen = 1'b0;
        $readmemh({DATA_DIR, "image.hex"},       image_mem);
        $readmemh({DATA_DIR, "test_labels.hex"}, label_mem);

        repeat (60000) @(posedge clk100);         // power-on reset and button settling

        // ---- 1. image over the UART ----
        send_byte(8'hA5);
        for (i = 0; i < 784; i = i + 1) send_byte(image_mem[3*784 + i][7:0]);
        recv_reply;
        $display("UART: image 3 -> digit %0d (label %0d), %0d clocks", r0, label_mem[3], cyc);
        if (r0 !== label_mem[3][7:0]) errors = errors + 1;
        if (cyc < 30000 || cyc > 40000) errors = errors + 1;
        repeat (200) @(posedge clk100);
        if (LED[3:0] !== r0[3:0] || LED[5] !== 1'b1) begin
            $display("LED check FAILED: LED=%b", LED); errors = errors + 1;
        end

        // ---- 2. built-in image with the button ----
        SLIDE_SW <= 16'd5;
        repeat (50) @(posedge clk100);
        push1 <= 1'b1;
        repeat (200) @(posedge clk100);
        push1 <= 1'b0;
        recv_reply;
        $display("BUTTON: built-in image 5 -> digit %0d (label %0d), %0d clocks", r0, label_mem[5], cyc);
        if (r0 !== label_mem[5][7:0]) errors = errors + 1;
        repeat (500) @(posedge clk100);

        // ---- 3. display: right-most digit shows the digit (segments light when LOW) ----
        right_seen = 1'b0;
        repeat (500) @(posedge clk100);
        if (!right_seen || right_seg !== seg_low(label_mem[5][3:0])) begin
            $display("DISPLAY check FAILED: seen=%b seg=%b expected=%b", right_seen, right_seg,
                     seg_low(label_mem[5][3:0]));
            errors = errors + 1;
        end else
            $display("DISPLAY: right-most digit pattern %b is correct for digit %0d", right_seg, label_mem[5]);

        if (other_on != 0) begin
            $display("DISPLAY check FAILED: digits 1..3 were selected %0d times", other_on);
            errors = errors + 1;
        end else
            $display("DISPLAY: digits 1..3 stay off");

        // ---- 4. another image through SW0..SW3 only (SW = 15 -> image 15, label 5) ----
        SLIDE_SW <= 16'hFFF0 | 16'd15;            // high switches are ignored now
        repeat (50) @(posedge clk100);
        push1 <= 1'b1;
        repeat (200) @(posedge clk100);
        push1 <= 1'b0;
        recv_reply;
        $display("BUTTON: built-in image 15 -> digit %0d (label %0d)", r0, label_mem[15]);
        if (r0 !== label_mem[15][7:0]) errors = errors + 1;

        $display("");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d problems)", errors);
        $finish;
    end

endmodule
