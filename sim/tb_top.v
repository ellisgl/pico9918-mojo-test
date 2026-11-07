`timescale 1ns/1ps
module tb_top;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;   // 50 MHz

    wire [0:7] CD;
    wire [7:0] led;
    wire MODE, nCSR, nCSW, nINT, RESET, avr_rx;
    reg  gclk = 0, cclk = 0;
    always #1118 gclk = ~gclk;  // ~447 kHz
    always #140  cclk = ~cclk;  // ~3.58 MHz

    top #(
        .ROM_FILE("../rtl/init_rom.hex"),
        .RESET_CYCLES(100), .BOOT_CYCLES(100),
        .WDOG_CYCLES(50_000),      // 1 ms (model frames are 200 us)
        .POLL_CYCLES(2_500),       // 50 us
        .REPORT_CYCLES(40_000),    // 0.8 ms
        .DIAG_CYCLES(20_000),      // 0.4 ms
        .DIAG_ENABLE(1)            // exercise the F18A read path in the model
    ) dut (
        .clk(clk), .rst_n(rst_n), .led(led),
        .CD(CD), .MODE(MODE), .nCSR(nCSR), .nCSW(nCSW), .nINT(nINT),
        .RESET(RESET), .GCLK(gclk), .CCLK(cclk),
        .avr_cclk(1'b1), .avr_rx_busy(1'b0), .avr_rx(avr_rx)
    );

    // decode the debug UART (500 kbaud) and print each line
    reg [8*80-1:0] uline = 0;
    reg [7:0] ub;
    integer ui, lines = 0;
    always @(negedge avr_rx) if (avr_rx === 1'b0) begin
        #1000;                                   // middle of the start bit
        for (ui = 0; ui < 8; ui = ui + 1) begin #2000; ub[ui] = avr_rx; end
        #2000;
        if (ub == 8'h0A) begin
            lines = lines + 1;
            if (lines % 4 == 1) $display("UART: %0s", uline);
            uline = 0;
        end else if (ub != 8'h0D)
            uline = {uline[8*79-1:0], ub};
    end

    vdp_model vdp (.CD(CD), .MODE(MODE), .nCSR(nCSR), .nCSW(nCSW), .nINT(nINT), .nRESET(RESET));

    integer k, fail = 0;
    reg [7:0] exp_regs [0:7];
    initial begin
        exp_regs[0] = 8'h00; exp_regs[1] = 8'hE2; exp_regs[2] = 8'h06; exp_regs[3] = 8'h80;
        exp_regs[4] = 8'h00; exp_regs[5] = 8'h36; exp_regs[6] = 8'h07; exp_regs[7] = 8'hF4;

        #200 rst_n = 1;
        wait (dut.init_done);
        $display("[%0t] init done (%0d writes)", $time, vdp.writes);
        wait (dut.test_done);
        $display("[%0t] readback test: %s, %0d errors", $time,
                 dut.test_pass ? "PASS" : "FAIL", dut.errors);
        wait (dut.frame == 8);
        wait (dut.state == dut.S_WAIT_INT);   // frame 8's writes are done

        for (k = 0; k < 8; k = k + 1)
            if (vdp.regs[k] !== exp_regs[k]) begin
                $display("R%0d = %02x, expected %02x", k, vdp.regs[k], exp_regs[k]);
                fail = 1;
            end
        // font check: 'A' (0x41) pattern row 1 should be the glyph top ".###." >> 1
        if (vdp.vram[16'h0041*8 + 1] !== 8'h38) begin
            $display("font 'A' row1 = %02x", vdp.vram[16'h0041*8 + 1]); fail = 1;
        end
        // sprite attribute: moved by 8 frames from (120,96) with dx=+1, dy=-1
        $display("sprite0 y=%0d x=%0d col=%0d", vdp.vram[14'h1B00], vdp.vram[14'h1B01], vdp.vram[14'h1B03]);
        if (vdp.vram[14'h1B01] !== 8'd128 || vdp.vram[14'h1B00] !== 8'd88) fail = 1;
        if (!dut.test_pass) fail = 1;
        $display("F18A: ID=%02x stage=%02x irqs=%02x", dut.sr1, dut.sr4, dut.sr5);
        if (dut.sr1 !== 8'hE8 || dut.sr4 !== 8'h23) fail = 1;
        if (vdp.r15 !== 0) begin $display("VR15 left at %0d", vdp.r15); fail = 1; end
        if (led[7]) begin $display("LED7 (waiting) still lit"); fail = 1; end
        if (!led[6] || !led[5]) begin $display("clock activity LEDs off"); fail = 1; end

        vdp.dump_screen;
        $display("frames=%0d writes=%0d reads=%0d model errors=%0d leds=%b",
                 dut.frame, vdp.writes, vdp.reads, vdp.errors, led);

        if (dut.poll_frames != 0) begin $display("frames polled with /INT working"); fail = 1; end

        // ----- /INT wire broken: frames should continue via status polling
        force nINT = 1'b1;
        wait (dut.frame == 16);
        wait (dut.state == dut.S_WAIT_INT);
        release nINT;
        $display("[%0t] /INT forced off: ipin=%0d poll=%0d resyncs=%0d", $time,
                 dut.ipin_frames, dut.poll_frames, dut.resyncs);
        if (dut.poll_frames != 8 || dut.resyncs != 0) fail = 1;

        // ----- VDP stops producing frames -> watchdog re-init
        vdp.frames_en = 0;
        wait (dut.state == 0);   // S_RESET
        vdp.frames_en = 1;
        $display("[%0t] watchdog tripped, resyncs=%0d", $time, dut.resyncs);
        wait (dut.test_done);
        wait (dut.frame == 20);
        wait (dut.state == dut.S_WAIT_INT);
        vdp.dump_screen;

        if (vdp.errors != 0 || dut.resyncs != 1 || lines < 5) fail = 1;
        if (fail) $display("*** TEST FAILED ***");
        else      $display("*** TEST PASSED ***");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
