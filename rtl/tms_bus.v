// TMS9918A host-side bus master.
//
// Performs one write (MODE + CD driven, /CSW pulsed) or one read (/CSR pulsed,
// CD sampled) per `start` pulse. All timing is in `clk` cycles (20 ns @ 50 MHz).
//
// The defaults are chosen around the PICO9918 PIO programs (src/tms9918.pio.in):
//  - Both strobes are debounced by ~32 ns in the PIO, so strobes must be clean
//    and comfortably longer than that.
//  - tmsRead drives CD ~60 ns after /CSR falls and releases it within a few ns
//    of /CSR rising. We sample at the end of a 400 ns strobe.
//  - tmsWrite keeps sampling CD/MODE while /CSW is low and keeps the last
//    sample before /CSW rises, so data is held across the rising edge.
//  - Every access raises an interrupt on the RP2040, which updates the
//    read-ahead value. T_GAP gives that handler time to finish before the next
//    access (a real TMS9918A needs 2-8 us between VRAM accesses as well).
module tms_bus #(
    parameter T_SETUP  = 3,    // MODE/CD valid before strobe falls
    parameter T_STROBE = 15,   // /CSW low time
    parameter T_READ   = 20,   // /CSR low time before CD is sampled
    parameter T_HOLD   = 3,    // CD/MODE held after strobe rises
    parameter T_GAP    = 100   // idle time after each access
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       start,    // 1-cycle pulse, only honoured when !busy
    input  wire       rd,       // 1 = read, 0 = write
    input  wire       mode,     // 0 = data port, 1 = control/status port
    input  wire [7:0] wdata,
    output reg        busy = 1'b0,
    output reg        done = 1'b0,     // 1-cycle pulse when the access (incl. gap) ends
    output reg  [7:0] rdata,

    // Power-up values keep the bus idle until the first clocked reset.
    output reg        vdp_mode  = 1'b0,
    output reg        vdp_csr_n = 1'b1,
    output reg        vdp_csw_n = 1'b1,
    output reg  [7:0] cd_out    = 8'h00,
    output reg        cd_oe     = 1'b0,
    input  wire [7:0] cd_in
);
    localparam S_IDLE = 3'd0, S_SETUP = 3'd1, S_STROBE = 3'd2, S_HOLD = 3'd3, S_GAP = 3'd4;

    reg [2:0] state = 3'd0;
    reg [7:0] cnt   = 8'd0;
    reg       is_rd;
    reg [7:0] cd_in_q;

    always @(posedge clk) cd_in_q <= cd_in;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            vdp_mode  <= 1'b0;
            vdp_csr_n <= 1'b1;
            vdp_csw_n <= 1'b1;
            cd_oe     <= 1'b0;
            cd_out    <= 8'h00;
            rdata     <= 8'h00;
            cnt       <= 8'd0;
            is_rd     <= 1'b0;
        end else if (cnt != 0) begin
            cnt <= cnt - 1'b1;
        end else begin
            case (state)
            S_IDLE:
                if (start) begin
                    busy     <= 1'b1;
                    is_rd    <= rd;
                    vdp_mode <= mode;
                    cd_out   <= wdata;
                    cd_oe    <= ~rd;
                    cnt      <= T_SETUP - 1;
                    state    <= S_SETUP;
                end
            S_SETUP: begin
                if (is_rd) begin
                    vdp_csr_n <= 1'b0;
                    cnt       <= T_READ - 1;
                end else begin
                    vdp_csw_n <= 1'b0;
                    cnt       <= T_STROBE - 1;
                end
                state <= S_STROBE;
            end
            S_STROBE: begin
                if (is_rd)
                    rdata <= cd_in_q;     // CD has been stable for most of the strobe
                vdp_csr_n <= 1'b1;
                vdp_csw_n <= 1'b1;
                cnt       <= T_HOLD - 1;
                state     <= S_HOLD;
            end
            S_HOLD: begin
                cd_oe <= 1'b0;
                cnt   <= T_GAP - 1;
                state <= S_GAP;
            end
            default: begin            // S_GAP
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= S_IDLE;
            end
            endcase
        end
    end
endmodule
