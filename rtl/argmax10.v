// argmax10.v
//
// Finds which of the 10 FC scores is largest and outputs its position (0..9).
// Hardware version of the `pred` loop in tb_microcnn.v.
//
// Scores arrive one per clock (score 0 first). Assert `last` on the 10th.
// One digit comes out 1 clock after `last`, with `done` high for one clock.
// On a tie the FIRST (lowest) index wins, same as the testbench's strict '>'.

module argmax10 (
    input  wire              clk,
    input  wire              rst,
    input  wire              valid_in,
    input  wire signed [7:0] score,
    input  wire              last,
    output reg               done,
    output reg         [3:0] digit
);

    reg        [3:0] idx;        // which score is arriving now
    reg signed [7:0] best_val;   // best score so far
    reg        [3:0] best_idx;   // and where it was

    wire       first   = (idx == 4'd0);
    wire       take    = first || (score > best_val);   // strict > : ties keep the earlier one
    wire [3:0] new_idx = take ? idx : best_idx;

    always @(posedge clk) begin
        if (rst) begin
            idx      <= 4'd0;
            best_val <= 8'sd0;
            best_idx <= 4'd0;
            digit    <= 4'd0;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;
            if (valid_in) begin
                if (take) begin
                    best_val <= score;
                    best_idx <= idx;
                end
                if (last) begin
                    digit <= new_idx;   // includes the score arriving right now
                    done  <= 1'b1;
                    idx   <= 4'd0;
                end else begin
                    idx <= idx + 4'd1;
                end
            end
        end
    end

endmodule
