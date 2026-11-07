// Mojo V3 (XC6SLX9) as a host CPU for a PICO9918 on a Waveshare RP2040-PiZero.
//
// Sequence:
//   1. Hold the VDP's RESET low for RESET_CYCLES, then wait BOOT_CYCLES.
//   2. Run the init script in rtl/init_rom.hex (registers, font, colour bars,
//      sprite, text) - see tools/gen_init_rom.py.
//   3. VRAM readback test: write 256 bytes to VRAM_TEST, read them back, count
//      mismatches. This exercises the read path (/CSR, bus turnaround).
//   4. Frame loop: on each /INT, read the status register (which acknowledges
//      the interrupt), then write the frame counter, status, test result,
//      resync count and a bouncing sprite.
//   While waiting for /INT, the status register is also polled every
//   POLL_CYCLES; if its frame flag (bit 7) is set the frame runs anyway. The
//   screen and the serial report count frames from each source, which shows
//   whether the /INT wire works.
//   If no frame arrives (by /INT or by polling) for WDOG_CYCLES (VDP unplugged, rebooted, not yet powered),
//   go back to step 1.
//
// Bit order: TMS9918A pins are named CD0 (MSB) .. CD7 (LSB), and the PICO9918
// firmware follows that (CD7 = GPIO8 = bit 0). The port is declared [0:7] so
// CD[0] is the MSB and byte values map onto it directly.
//
// LEDs: 0 heartbeat (frame counter), 1 init done, 2 readback PASS,
//       3 readback FAIL, 4 /INT seen recently, 5 GROMCLK toggling,
//       6 CPUCLK toggling, 7 waiting for the VDP (reset/boot/watchdog).
module top #(
    parameter ROM_FILE     = "rtl/init_rom.hex",
    parameter RESET_CYCLES = 500_000,      // 10 ms
    parameter BOOT_CYCLES  = 12_500_000,   // 250 ms
    parameter WDOG_CYCLES  = 25_000_000,   // 500 ms (frames are ~16.7 ms)
    parameter POLL_CYCLES  = 50_000,       // 1 ms status poll while waiting
    parameter REPORT_CYCLES = 12_500_000,  // serial report every 250 ms
    parameter DIAG_CYCLES  = 5_000_000,    // F18A SR1/SR4/SR5 read every 100 ms
    parameter DIAG_ENABLE  = 0,            // 1: unlock F18A, read SR1/SR4/SR5 (boot-trace firmware; stops /INT after a few frames)
    parameter T_GAP        = 100           // 2 us between bus accesses
) (
    input  wire       clk,       // 50 MHz
    input  wire       rst_n,     // Mojo reset button
    output wire [7:0] led,

    inout  wire [0:7] CD,        // CD0 = MSB
    output wire       MODE,
    output wire       nCSR,
    output wire       nCSW,
    input  wire       nINT,
    output reg        RESET = 1'b0,  // active low, like the TMS9918A pin
    input  wire       GCLK,      // GROMCLK from the VDP
    input  wire       CCLK,      // CPUCLK from the VDP

    // Mojo AVR serial bridge (USB /dev/ttyACM0, 500 kbaud) for debug reports
    input  wire       avr_cclk,
    input  wire       avr_rx_busy,
    output wire       avr_rx
);
    `include "layout.vh"

    // ------------------------------------------------------------------ reset
    reg [1:0] rst_sync = 2'b00;
    always @(posedge clk) begin
      rst_sync <= {rst_sync[0], rst_n};
    end 
    wire rst = ~rst_sync[1];

    // ------------------------------------------------------------ input sync
    reg [2:0] int_s  = 3'b111;
    reg [2:0] gclk_s = 3'b000;
    reg [2:0] cclk_s = 3'b000;
    always @(posedge clk) begin
        int_s  <= {int_s[1:0],  nINT};
        gclk_s <= {gclk_s[1:0], GCLK};
        cclk_s <= {cclk_s[1:0], CCLK};
    end
    wire int_active = ~int_s[1];

    // Activity detectors: lit if an edge was seen in the last ~1.3 ms.
    reg [16:0] gclk_idle = 17'h1ffff;
    reg [16:0] cclk_idle = 17'h1ffff;
    reg [16:0]  int_idle = 17'h1ffff;
    always @(posedge clk) begin
        gclk_idle <= (gclk_s[2] != gclk_s[1]) ? 17'd0 : gclk_idle + {16'd0, ~&gclk_idle};
        cclk_idle <= (cclk_s[2] != cclk_s[1]) ? 17'd0 : cclk_idle + {16'd0, ~&cclk_idle};
    end

    // -------------------------------------------------------------- bus core
    reg        bus_start = 1'b0, bus_rd, bus_mode;
    reg  [7:0] bus_wdata;
    wire       bus_done, bus_busy;
    wire [7:0] bus_rdata, cd_out;
    wire       cd_oe;

    tms_bus #(.T_GAP(T_GAP)) u_bus (
        .clk(clk), .rst(rst),
        .start(bus_start), .rd(bus_rd), .mode(bus_mode), .wdata(bus_wdata),
        .busy(bus_busy), .done(bus_done), .rdata(bus_rdata),
        .vdp_mode(MODE), .vdp_csr_n(nCSR), .vdp_csw_n(nCSW),
        .cd_out(cd_out), .cd_oe(cd_oe), .cd_in(CD)
    );
    assign CD = cd_oe ? cd_out : 8'bzzzzzzzz;

    // -------------------------------------------------------------- init ROM
    localparam OP_END = 4'd0, OP_WCTRL = 4'd1, OP_WDATA = 4'd2, OP_CNTHI = 4'd3,
               OP_CNTLO = 4'd4, OP_FILL = 4'd5, OP_RSTAT = 4'd6;

    reg [11:0] rom [0:ROM_DEPTH-1];
    initial $readmemh(ROM_FILE, rom);

    reg [ROM_AW-1:0] rom_addr;
    reg [11:0]       rom_q;
    always @(posedge clk) rom_q <= rom[rom_addr];
    wire [3:0] rom_op  = rom_q[11:8];
    wire [7:0] rom_arg = rom_q[7:0];

    // --------------------------------------------------------- frame updates
    function [7:0] hexc(input [3:0] n);
        hexc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction

    reg [15:0] frame;
    reg [7:0]  status;
    reg [7:0]  errors;       // readback mismatches (saturating)
    reg        test_done, test_pass;
    reg [7:0]  resyncs;
    reg [7:0]  ipin_frames, poll_frames;   // frames started by /INT / by polling
    reg [15:0] poll_cnt;
    reg [22:0] diag_cnt;
    reg [7:0]  sr1, sr4, sr5;              // F18A status regs (ID, boot trace, DVI irqs)
    reg [3:0]  dstep;
    reg [1:0]  d_cap;                      // which register the pending read fills
    reg [7:0]  spr_x, spr_y;
    reg        spr_dx, spr_dy;   // 1 = increasing
    wire [3:0] spr_col = (frame[8:5] == 4'd0 || frame[8:5] == 4'd4) ? 4'hF : frame[8:5];

    // Per-frame write list. step -> {last, mode, data}
    reg  [5:0] step;
    reg        f_last, f_mode;
    reg  [7:0] f_data;
    always @* begin
        f_last = 1'b0; f_mode = 1'b0; f_data = 8'h00;
        case (step)
        6'd0:   begin f_mode = 1; f_data = ADDR_FRAME[7:0]; end
        6'd1:   begin f_mode = 1; f_data = {2'b01, ADDR_FRAME[13:8]}; end
        6'd2:   f_data = hexc(frame[15:12]);
        6'd3:   f_data = hexc(frame[11:8]);
        6'd4:   f_data = hexc(frame[7:4]);
        6'd5:   f_data = hexc(frame[3:0]);
        6'd6:   begin f_mode = 1; f_data = ADDR_STATUS[7:0]; end
        6'd7:   begin f_mode = 1; f_data = {2'b01, ADDR_STATUS[13:8]}; end
        6'd8:   f_data = hexc(status[7:4]);
        6'd9:   f_data = hexc(status[3:0]);
        6'd10: begin f_mode = 1; f_data = ADDR_TEST[7:0]; end
        6'd11: begin f_mode = 1; f_data = {2'b01, ADDR_TEST[13:8]}; end
        6'd12: f_data = test_pass ? "P" : "F";
        6'd13: f_data = "A";
        6'd14: f_data = test_pass ? "S" : "I";
        6'd15: f_data = test_pass ? "S" : "L";
        6'd16: f_data = " ";
        6'd17: f_data = "$";
        6'd18: f_data = hexc(errors[7:4]);
        6'd19: f_data = hexc(errors[3:0]);
        6'd20: begin f_mode = 1; f_data = ADDR_RESYNC[7:0]; end
        6'd21: begin f_mode = 1; f_data = {2'b01, ADDR_RESYNC[13:8]}; end
        6'd22: f_data = hexc(resyncs[7:4]);
        6'd23: f_data = hexc(resyncs[3:0]);
        6'd24: begin f_mode = 1; f_data = ADDR_IPIN[7:0]; end
        6'd25: begin f_mode = 1; f_data = {2'b01, ADDR_IPIN[13:8]}; end
        6'd26: f_data = hexc(ipin_frames[7:4]);
        6'd27: f_data = hexc(ipin_frames[3:0]);
        6'd28: begin f_mode = 1; f_data = ADDR_POLL[7:0]; end
        6'd29: begin f_mode = 1; f_data = {2'b01, ADDR_POLL[13:8]}; end
        6'd30: f_data = hexc(poll_frames[7:4]);
        6'd31: f_data = hexc(poll_frames[3:0]);
        6'd32: begin f_mode = 1; f_data = VRAM_SAT[7:0]; end
        6'd33: begin f_mode = 1; f_data = {2'b01, VRAM_SAT[13:8]}; end
        6'd34: f_data = spr_y;
        6'd35: f_data = spr_x;
        6'd36: f_data = 8'h00;              // pattern 0
        6'd37: f_data = {4'h0, spr_col};
        default: f_last = 1'b1;
        endcase
    end

    // F18A diagnostic reads (firmware built with PICO9918_BOOT_TRACE=ON):
    // unlock (0x1C -> VR57 twice), then select SR1/SR4/SR5 with VR15 and read
    // the status port, then restore VR15 = 0. dstep -> {last, rd, data, cap}
    reg        d_last, d_rd;
    reg  [7:0] d_data;
    reg  [1:0] d_slot;
    always @* begin
        d_last = 1'b0; d_rd = 1'b0; d_data = 8'h00; d_slot = 2'd0;
        case (dstep)
        4'd0, 4'd2:  d_data = 8'h1C;
        4'd1, 4'd3:  d_data = 8'hB9;          // VR57
        4'd4:        d_data = 8'h01;
        4'd5:        d_data = 8'h8F;          // VR15 = 1 (ID)
        4'd6:        begin d_rd = 1'b1; d_slot = 2'd1; end
        4'd7:        d_data = 8'h04;
        4'd8:        d_data = 8'h8F;          // VR15 = 4 (boot stage)
        4'd9:        begin d_rd = 1'b1; d_slot = 2'd2; end
        4'd10:       d_data = 8'h05;
        4'd11:       d_data = 8'h8F;          // VR15 = 5 (DVI irq count)
        4'd12:       begin d_rd = 1'b1; d_slot = 2'd3; end
        4'd13:       d_data = 8'h00;
        4'd14:       d_data = 8'h8F;          // VR15 = 0
        default:     d_last = 1'b1;
        endcase
    end

    // ------------------------------------------------------------ main FSM
    localparam S_RESET      = 5'd0,  S_BOOT      = 5'd1,  S_ROM_READ = 5'd2,
               S_ROM_EXEC   = 5'd3,  S_ROM_NEXT  = 5'd4,  S_BUS_WAIT = 5'd5,
               S_T_WADDR0   = 5'd6,  S_T_WADDR1  = 5'd7,  S_T_WRITE  = 5'd8,
               S_T_RADDR0   = 5'd9,  S_T_RADDR1  = 5'd10, S_T_READ   = 5'd11,
               S_T_CHECK    = 5'd12, S_WAIT_INT  = 5'd13, S_F_STATUS = 5'd14,
               S_F_GOTSTAT  = 5'd15, S_F_STEP    = 5'd16, S_WAIT_IDLE = 5'd17,
               S_POLL_CHECK = 5'd18, S_D_STEP    = 5'd19, S_D_GOT    = 5'd20;

    reg [4:0]  state, ret_state;
    reg [24:0] timer;
    reg [15:0] fill_cnt;
    reg [7:0]  t_idx;
    reg        init_done;

    // readback pattern: an odd multiplier makes every byte distinct
    wire [7:0] t_pattern = t_idx * 8'd37 + 8'd11;

    // Issue one bus access and continue at `next` once it completes.
    task issue(input rd, input mode, input [7:0] data, input [4:0] next);
        begin
            bus_start <= 1'b1;
            bus_rd    <= rd;
            bus_mode  <= mode;
            bus_wdata <= data;
            ret_state <= next;
            state     <= S_BUS_WAIT;
        end
    endtask

    always @(posedge clk) begin
        bus_start <= 1'b0;
        int_idle  <= int_active ? 17'd0 : int_idle + {16'd0, ~&int_idle};

        if (rst) begin
            state     <= S_RESET;
            ret_state <= S_RESET;
            timer     <= 25'd0;
            RESET     <= 1'b0;
            rom_addr  <= {ROM_AW{1'b0}};
            fill_cnt  <= 16'd0;
            init_done <= 1'b0;
            test_done <= 1'b0;
            test_pass <= 1'b0;
            errors    <= 8'd0;
            resyncs   <= 8'd0;
            ipin_frames <= 8'd0;
            poll_frames <= 8'd0;
            poll_cnt  <= 16'd0;
            diag_cnt  <= 23'd0;
            dstep     <= 4'd0;
            d_cap     <= 2'd0;
            sr1 <= 8'h00;  sr4 <= 8'h00;  sr5 <= 8'h00;
            frame     <= 16'd0;
            status    <= 8'd0;
            step      <= 6'd0;
            t_idx     <= 8'd0;
            spr_x     <= 8'd120;  spr_dx <= 1'b1;
            spr_y     <= 8'd96;   spr_dy <= 1'b0;
            bus_rd    <= 1'b0;  bus_mode <= 1'b0;  bus_wdata <= 8'h00;
        end else begin
            case (state)
            // ---------------------------------------------- reset + boot wait
            S_RESET: begin
                RESET     <= 1'b0;
                init_done <= 1'b0;
                test_done <= 1'b0;
                if (timer == RESET_CYCLES - 1) begin
                    timer <= 25'd0;
                    RESET <= 1'b1;
                    state <= S_BOOT;
                end else
                    timer <= timer + 1'b1;
            end
            S_BOOT:
                if (timer == BOOT_CYCLES - 1) begin
                    timer    <= 25'd0;
                    rom_addr <= {ROM_AW{1'b0}};
                    state    <= S_ROM_READ;
                end else
                    timer <= timer + 1'b1;

            // ---------------------------------------------- init script
            S_ROM_READ:          // wait for the block RAM output register
                state <= S_ROM_EXEC;
            S_ROM_EXEC:
                case (rom_op)
                OP_WCTRL: issue(1'b0, 1'b1, rom_arg, S_ROM_NEXT);
                OP_WDATA: issue(1'b0, 1'b0, rom_arg, S_ROM_NEXT);
                OP_RSTAT: issue(1'b1, 1'b1, 8'h00,   S_ROM_NEXT);
                OP_CNTHI: begin fill_cnt[15:8] <= rom_arg; state <= S_ROM_NEXT; end
                OP_CNTLO: begin fill_cnt[7:0]  <= rom_arg; state <= S_ROM_NEXT; end
                OP_FILL:
                    if (fill_cnt == 16'd0)
                        state <= S_ROM_NEXT;
                    else begin
                        fill_cnt <= fill_cnt - 1'b1;
                        issue(1'b0, 1'b0, rom_arg, S_ROM_EXEC);
                    end
                default: begin   // OP_END
                    init_done <= 1'b1;
                    state     <= S_T_WADDR0;
                end
                endcase
            S_ROM_NEXT: begin
                rom_addr <= rom_addr + 1'b1;
                state    <= S_ROM_READ;
            end

            S_BUS_WAIT:
                if (bus_done)
                    state <= ret_state;

            // ---------------------------------------------- readback test
            S_T_WADDR0: begin
                t_idx  <= 8'd0;
                errors <= 8'd0;
                issue(1'b0, 1'b1, VRAM_TEST[7:0], S_T_WADDR1);
            end
            S_T_WADDR1: issue(1'b0, 1'b1, {2'b01, VRAM_TEST[13:8]}, S_T_WRITE);
            S_T_WRITE: begin
                t_idx <= t_idx + 1'b1;
                issue(1'b0, 1'b0, t_pattern, (t_idx == 8'hFF) ? S_T_RADDR0 : S_T_WRITE);
            end
            S_T_RADDR0: issue(1'b0, 1'b1, VRAM_TEST[7:0], S_T_RADDR1);
            S_T_RADDR1: issue(1'b0, 1'b1, {2'b00, VRAM_TEST[13:8]}, S_T_READ);
            S_T_READ:   issue(1'b1, 1'b0, 8'h00, S_T_CHECK);
            S_T_CHECK: begin
                if (bus_rdata != t_pattern && errors != 8'hFF)
                    errors <= errors + 1'b1;
                t_idx <= t_idx + 1'b1;
                if (t_idx == 8'hFF) begin
                    test_done <= 1'b1;
                    test_pass <= (errors == 8'd0) && (bus_rdata == t_pattern);
                    timer     <= 25'd0;
                    dstep     <= 4'd0;
                    // A failed readback usually means the VDP wasn't ready
                    // (still booting), so the init was lost too: start over.
                    if (errors == 8'd0 && bus_rdata == t_pattern)
                        state <= DIAG_ENABLE ? S_D_STEP : S_WAIT_INT;
                    else begin
                        resyncs <= resyncs + 1'b1;
                        state   <= S_RESET;
                    end
                end else
                    state <= S_T_READ;
            end

            // ---------------------------------------------- frame loop
            S_WAIT_INT:
                if (int_active) begin
                    timer       <= 25'd0;
                    poll_cnt    <= 16'd0;
                    ipin_frames <= ipin_frames + 1'b1;
                    state       <= S_F_STATUS;
                end else if (timer == WDOG_CYCLES - 1) begin
                    timer   <= 25'd0;
                    resyncs <= resyncs + 1'b1;
                    state   <= S_RESET;
                end else begin
                    timer <= timer + 1'b1;
                    if (DIAG_ENABLE && diag_cnt == DIAG_CYCLES - 1) begin
                        diag_cnt <= 23'd0;
                        dstep    <= 4'd0;
                        state    <= S_D_STEP;
                    end else begin
                        diag_cnt <= diag_cnt + 1'b1;
                        if (poll_cnt == POLL_CYCLES - 1) begin
                            poll_cnt <= 16'd0;
                            issue(1'b1, 1'b1, 8'h00, S_POLL_CHECK);
                        end else
                            poll_cnt <= poll_cnt + 1'b1;
                    end
                end
            // F18A diagnostic read sequence, then back to waiting for a frame
            S_D_STEP:
                if (d_last)
                    state <= S_WAIT_INT;
                else begin
                    dstep <= dstep + 1'b1;
                    d_cap <= d_slot;
                    issue(d_rd, 1'b1, d_data, d_rd ? S_D_GOT : S_D_STEP);
                end
            S_D_GOT: begin
                case (d_cap)
                2'd1: sr1 <= bus_rdata;
                2'd2: sr4 <= bus_rdata;
                default: sr5 <= bus_rdata;
                endcase
                state <= S_D_STEP;
            end
            // Status poll: frame flag set means the VDP finished a frame but
            // /INT did not reach us. Run the frame update anyway.
            S_POLL_CHECK:
                if (bus_rdata[7]) begin
                    timer       <= 25'd0;
                    poll_frames <= poll_frames + 1'b1;
                    state       <= S_F_GOTSTAT;
                end else
                    state <= S_WAIT_INT;
            S_F_STATUS: issue(1'b1, 1'b1, 8'h00, S_F_GOTSTAT);
            S_F_GOTSTAT: begin
                status <= bus_rdata;
                frame  <= frame + 1'b1;
                // bounce the sprite inside 0..239 x 0..175
                if (spr_dx) begin
                    if (spr_x == 8'd239) begin spr_dx <= 1'b0; spr_x <= spr_x - 1'b1; end
                    else spr_x <= spr_x + 1'b1;
                end else begin
                    if (spr_x == 8'd0) begin spr_dx <= 1'b1; spr_x <= spr_x + 1'b1; end
                    else spr_x <= spr_x - 1'b1;
                end
                if (spr_dy) begin
                    if (spr_y == 8'd175) begin spr_dy <= 1'b0; spr_y <= spr_y - 1'b1; end
                    else spr_y <= spr_y + 1'b1;
                end else begin
                    if (spr_y == 8'd0) begin spr_dy <= 1'b1; spr_y <= spr_y + 1'b1; end
                    else spr_y <= spr_y - 1'b1;
                end
                step  <= 6'd0;
                state <= S_F_STEP;
            end
            S_F_STEP:
                if (f_last) begin
                    timer <= 25'd0;
                    state <= S_WAIT_IDLE;
                end else begin
                    step <= step + 1'b1;
                    issue(1'b0, f_mode, f_data, S_F_STEP);
                end
            // The status read releases /INT; make sure it is high before
            // waiting for the next frame (gives up after ~1 ms).
            S_WAIT_IDLE:
                if (!int_active || timer == 25'd50_000) begin
                    timer <= 25'd0;
                    state <= S_WAIT_INT;
                end else
                    timer <= timer + 1'b1;

            default: state <= S_RESET;
            endcase
        end
    end

    wire waiting = (state == S_RESET) || (state == S_BOOT) ||
                   (state == S_WAIT_INT && timer > 25'd2_500_000);   // >50 ms without /INT

    debug_uart #(.PERIOD(REPORT_CYCLES)) u_dbg (
        .clk(clk), .avr_cclk(avr_cclk), .avr_rx_busy(avr_rx_busy), .avr_rx(avr_rx),
        .st({3'b000, state}), .int_pin(int_s[1]), .status(status), .frame(frame),
        .ipin(ipin_frames), .poll(poll_frames), .resyncs(resyncs), .errors(errors),
        .test_done(test_done), .test_pass(test_pass),
        .sr1(sr1), .sr4(sr4), .sr5(sr5)
    );

    assign led = { waiting,
                   ~&cclk_idle,
                   ~&gclk_idle,
                   ~&int_idle,
                   test_done & ~test_pass,
                   test_done & test_pass,
                   init_done,
                   frame[5] };
endmodule
