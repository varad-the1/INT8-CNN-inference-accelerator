// board_top.v
//
// Top level for the Eisler Artix-7 100T board.
//
// Two ways to run an inference:
//   * PC over USB-UART (115200 8N1): send 0xA5 followed by 784 pixel bytes
//     (int8, row by row). The board answers with 5 bytes:
//        [digit] [cycles 31:24] [cycles 23:16] [cycles 15:8] [cycles 7:0]
//   * Stand-alone: slide switches SW0..SW3 pick one of the first 16 built-in
//     images (binary: SW0 = 1, SW1 = 2, SW2 = 4, SW3 = 8), push button 1 runs it.
//
// Display: only the right-most digit is used; it shows the predicted digit and
//   is blank until the first inference has finished. The other three are off.
//   (On this board a segment lights and a digit is selected when its pin is LOW.)
// LEDs:  LED[3:0] = predicted digit, LED[4] busy, LED[5] result valid,
//        LED[6] UART byte received, LED[7] UART byte sent, LED[15] heartbeat.
//
// Button: the level seen shortly after power-up is taken as "not pressed",
// so either polarity works (do not hold a button while powering up).

module board_top #(
    parameter CLKS_PER_BIT = 868,          // 100 MHz / 115200 baud
    parameter [21:0] SETTLE    = 22'd4000000,   // clocks to wait before reading the idle button level
    parameter [19:0] DEBOUNCE  = 20'd1000000,   // 10 ms
    parameter [26:0] TIMEOUT   = 27'd50000000   // 0.5 s without a byte while receiving an image
) (
    input  wire        clk100,
    input  wire        push1,
    input  wire [15:0] SLIDE_SW,
    output wire [15:0] LED,
    output wire        sig_a, sig_b, sig_c, sig_d, sig_e, sig_f, sig_g, sig_pd,
    output wire        sel_disp1, sel_disp2, sel_disp3, sel_disp4,
    input  wire        usb_uart_rxd,
    output wire        usb_uart_txd
);

    wire clk = clk100;

    // ---- power-on reset ----------------------------------------------------
    reg [15:0] por = 16'd0;
    always @(posedge clk) if (!por[15]) por <= por + 16'd1;
    wire rst = ~por[15];

    // ---- synchronized switches: SW0..SW3 select the demo image (0..15) -----
    reg [3:0] sw1 = 4'd0, sw2 = 4'd0;
    always @(posedge clk) begin sw1 <= SLIDE_SW[3:0]; sw2 <= sw1; end
    wire [3:0] demo_idx = sw2;

    // ---- push button 1: idle level auto-detect and debounce ----------------
    reg        b1 = 1'b0, b2 = 1'b0, btn_idle = 1'b0, btn_ready = 1'b0;
    reg [21:0] settle_cnt = 22'd0;
    reg [19:0] db_cnt = 20'd0;
    reg        pressed = 1'b0, pressed_d = 1'b0;
    always @(posedge clk) begin
        b1 <= push1;  b2 <= b1;
        if (!btn_ready) begin
            if (settle_cnt == SETTLE) begin btn_idle <= b2; btn_ready <= 1'b1; end
            else settle_cnt <= settle_cnt + 22'd1;
        end
        if (btn_ready && (b2 != btn_idle)) begin
            if (db_cnt == DEBOUNCE) pressed <= 1'b1; else db_cnt <= db_cnt + 20'd1;
        end else begin
            db_cnt  <= 20'd0;
            pressed <= 1'b0;
        end
        pressed_d <= pressed;
    end
    wire press_ev = pressed && !pressed_d;

    // ---- UART --------------------------------------------------------------
    wire       rx_valid;
    wire [7:0] rx_data;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) urx (.clk(clk), .rx(usb_uart_rxd),
                                                .valid(rx_valid), .data(rx_data));

    reg        tx_start = 1'b0;
    reg  [7:0] tx_data  = 8'd0;
    wire       tx_busy;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) utx (.clk(clk), .start(tx_start), .data(tx_data),
                                                .busy(tx_busy), .txd(usb_uart_txd));

    // ---- the accelerator and the demo image ROM ----------------------------
    reg         start_r = 1'b0;
    wire        busy, done;
    wire  [3:0] digit;
    wire [31:0] cycles;
    reg         load_we = 1'b0;
    reg  [9:0]  load_addr = 10'd0;
    reg  signed [7:0] load_data = 8'sd0;

    cnn_top core (.clk(clk), .rst(rst), .start(start_r), .busy(busy), .done(done),
                  .digit(digit), .cycles(cycles),
                  .load_we(load_we), .load_addr(load_addr), .load_data(load_data));

    reg  [13:0] rom_addr = 14'd0;
    wire [7:0]  rom_q;
    demo_rom drom (.clk(clk), .addr(rom_addr), .data(rom_q));

    // ---- control: receive / demo-load -> run -> reply ----------------------
    localparam S_IDLE = 4'd0, S_RX = 4'd1, S_DEMO = 4'd2, S_START = 4'd3, S_RUN = 4'd4,
               S_TXA  = 4'd5, S_TXB = 4'd6, S_TXC  = 4'd7;
    reg [3:0]  state = S_IDLE;
    reg [9:0]  cnt = 10'd0;                 // pixel counter
    reg [10:0] dk = 11'd0;                  // demo load step
    reg [26:0] tout = 27'd0;
    reg [2:0]  wcnt = 3'd0;
    reg [2:0]  tx_idx = 3'd0;

    // demo load pipeline: address -> ROM -> write
    reg        dv1 = 1'b0, dv2 = 1'b0;
    reg [9:0]  da1 = 10'd0, da2 = 10'd0;

    reg        res_valid = 1'b0;
    reg  [3:0] res_digit = 4'd0;
    reg [31:0] res_cycles = 32'd0;

    wire [7:0] tx_byte = (tx_idx == 3'd0) ? {4'd0, res_digit} :
                         (tx_idx == 3'd1) ? res_cycles[31:24] :
                         (tx_idx == 3'd2) ? res_cycles[23:16] :
                         (tx_idx == 3'd3) ? res_cycles[15:8]  : res_cycles[7:0];

    reg [6:0] act_rx = 7'd0, act_tx = 7'd0;       // activity stretchers for the LEDs

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            start_r <= 1'b0;  load_we <= 1'b0;  tx_start <= 1'b0;
            res_valid <= 1'b0;
        end else begin
            start_r  <= 1'b0;
            load_we  <= 1'b0;
            tx_start <= 1'b0;
            dv1 <= 1'b0;

            case (state)
            S_IDLE: begin
                if (rx_valid && rx_data == 8'hA5) begin
                    cnt  <= 10'd0;
                    tout <= 27'd0;
                    state <= S_RX;
                end else if (press_ev) begin
                    dk    <= 11'd0;
                    state <= S_DEMO;
                end
            end

            S_RX: begin                                  // 784 pixel bytes
                tout <= tout + 27'd1;
                if (rx_valid) begin
                    tout      <= 27'd0;
                    load_we   <= 1'b1;
                    load_addr <= cnt;
                    load_data <= rx_data;
                    cnt       <= cnt + 10'd1;
                    if (cnt == 10'd783) begin
                        wcnt  <= 3'd0;
                        state <= S_START;
                    end
                end else if (tout == TIMEOUT)
                    state <= S_IDLE;                      // transfer abandoned
            end

            S_DEMO: begin                                 // copy a stored image into the accelerator
                dk  <= dk + 11'd1;
                if (dk < 11'd784) begin
                    rom_addr <= demo_idx * 14'd784 + {3'd0, dk};
                    dv1 <= 1'b1;
                    da1 <= dk[9:0];
                end
                dv2 <= dv1;  da2 <= da1;                  // ROM data arrives one clock later
                if (dv2) begin
                    load_we   <= 1'b1;
                    load_addr <= da2;
                    load_data <= rom_q;
                end
                if (dk == 11'd790) begin
                    wcnt  <= 3'd0;
                    state <= S_START;
                end
            end

            S_START: begin
                start_r <= 1'b1;
                wcnt    <= 3'd0;
                state   <= S_RUN;
            end

            S_RUN: begin                                  // skip 3 clocks so a stale `done` is ignored
                if (wcnt != 3'd4) wcnt <= wcnt + 3'd1;
                else if (done) begin
                    res_digit  <= digit;
                    res_cycles <= cycles;
                    res_valid  <= 1'b1;
                    tx_idx     <= 3'd0;
                    state      <= S_TXA;
                end
            end

            S_TXA: if (!tx_busy) begin                     // start sending byte tx_idx
                tx_data  <= tx_byte;
                tx_start <= 1'b1;
                state    <= S_TXB;
            end
            S_TXB: state <= S_TXC;                         // let the transmitter pick it up
            S_TXC: if (!tx_busy) begin
                if (tx_idx == 3'd4) state <= S_IDLE;
                else begin tx_idx <= tx_idx + 3'd1; state <= S_TXA; end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ---- display: only the right-most digit, showing the predicted digit ---
    function [6:0] seg7;                                   // {g,f,e,d,c,b,a}, 1 = lit
        input [3:0] n;
        case (n)
            4'd0: seg7 = 7'h3F;  4'd1: seg7 = 7'h06;  4'd2: seg7 = 7'h5B;  4'd3: seg7 = 7'h4F;
            4'd4: seg7 = 7'h66;  4'd5: seg7 = 7'h6D;  4'd6: seg7 = 7'h7D;  4'd7: seg7 = 7'h07;
            4'd8: seg7 = 7'h7F;  4'd9: seg7 = 7'h6F;  default: seg7 = 7'h00;   // blank
        endcase
    endfunction

    reg [6:0] seg_q = 7'd0;
    always @(posedge clk) seg_q <= res_valid ? seg7(res_digit) : 7'h00;

    assign {sig_g, sig_f, sig_e, sig_d, sig_c, sig_b, sig_a} = ~seg_q;   // lit when LOW
    assign sig_pd    = 1'b1;                               // decimal point off
    assign sel_disp1 = 1'b1;                               // digits 1..3 off
    assign sel_disp2 = 1'b1;
    assign sel_disp3 = 1'b1;
    assign sel_disp4 = 1'b0;                               // right-most digit on (select is active-low)

    // ---- LEDs ---------------------------------------------------------------
    reg [25:0] hb = 26'd0;
    reg [31:0] dcnt = 32'd0;
    always @(posedge clk) dcnt <= dcnt + 32'd1;
    always @(posedge clk) begin
        hb <= hb + 26'd1;
        if (rx_valid)      act_rx <= 7'h7F; else if (dcnt[17:0] == 0 && act_rx != 0) act_rx <= act_rx - 7'd1;
        if (tx_start)      act_tx <= 7'h7F; else if (dcnt[17:0] == 0 && act_tx != 0) act_tx <= act_tx - 7'd1;
    end

    assign LED[3:0]  = res_valid ? res_digit : 4'd0;
    assign LED[4]    = (state != S_IDLE);
    assign LED[5]    = res_valid;
    assign LED[6]    = (act_rx != 0);
    assign LED[7]    = (act_tx != 0);
    assign LED[14:8] = 7'd0;
    assign LED[15]   = hb[25];

endmodule
