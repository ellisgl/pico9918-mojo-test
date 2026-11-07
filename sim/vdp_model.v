// Behavioural TMS9918A / PICO9918 bus model for simulation.
//
// Implements the host-visible behaviour (address latch, registers, read-ahead,
// status, /INT) plus checks that the host respects the bus timing the
// PICO9918 PIO programs rely on.
`timescale 1ns/1ps
module vdp_model #(
    parameter FRAME_NS   = 200_000,  // shortened frame period for simulation
    parameter RD_DELAY   = 60,       // /CSR low -> CD driven (PIO debounce + out)
    parameter IRQ_NS     = 800,      // RP2040 handler latency after each access
    parameter MIN_STROBE = 100       // shortest strobe we accept (PIO debounce is ~32 ns)
) (
    inout  wire [0:7] CD,
    input  wire       MODE,
    input  wire       nCSR,
    input  wire       nCSW,
    output wire       nINT,
    input  wire       nRESET
);
    reg [7:0]  vram [0:16383];
    reg [7:0]  regs [0:7];
    reg [13:0] addr;
    reg [7:0]  latch;
    reg        stage;
    reg [7:0]  readahead;
    reg [7:0]  status;
    reg        int_pending;
    // F18A subset: unlock (0x1C -> VR57 twice), VR15 status select,
    // SR1 = ID, SR4 = boot trace stage, SR5 = DVI irq count (boot-trace firmware)
    reg        unlocked;
    integer    unlock_cnt;
    reg [5:0]  r15;
    reg [7:0]  sr4 = 8'h23, sr5 = 8'h00;

    reg [7:0]  drive_val;
    reg        drive_en;
    assign CD   = drive_en ? drive_val : 8'bzzzzzzzz;
    assign nINT = ~(int_pending & regs[1][5]);

    integer errors = 0, writes = 0, reads = 0, i;
    realtime t_csw_fall, t_csr_fall, t_last_access = 0;
    reg [7:0] csw_data;
    reg       csw_mode;

    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("[%0t] VDP MODEL ERROR: %0s", $time, msg);
        end
    endtask

    task do_reset;
        begin
            for (i = 0; i < 8; i = i + 1) regs[i] = 8'h00;
            stage = 0; addr = 0; status = 8'h1F; int_pending = 0;
            unlocked = 0; unlock_cnt = 0; r15 = 0;
        end
    endtask

    initial begin
        for (i = 0; i < 16384; i = i + 1) vram[i] = 8'hA5;   // garbage until cleared
        do_reset;
        drive_en = 0; readahead = 0;
    end

    always @(negedge nRESET) do_reset;

    // ---------------------------------------------------------------- writes
    always @(negedge nCSW) begin
        t_csw_fall = $realtime;
        csw_data   = CD;
        csw_mode   = MODE;
        if (!nCSR) fail("/CSW and /CSR both low");
        if ($realtime - t_last_access < IRQ_NS) fail("access before RP2040 handler finished");
    end

    // data and MODE must be stable for the whole strobe
    always @(CD or MODE) if (!nCSW && (CD !== csw_data || MODE !== csw_mode))
        fail("CD/MODE changed while /CSW low");

    always @(posedge nCSW) begin
        if ($realtime - t_csw_fall < MIN_STROBE) fail("/CSW strobe too short");
        if (^CD === 1'bx) fail("CD undriven/X at /CSW rising edge");
        t_last_access = $realtime;
        writes = writes + 1;
        if (MODE) begin
            if (!stage) begin
                latch = CD; stage = 1;
            end else begin
                stage = 0;
                if (CD[0]) begin                             // CD0 = bit 7
                    if (CD[2:7] == 6'd57 && latch[7:2] == 6'h07) begin
                        unlock_cnt = unlock_cnt + 1;
                        if (unlock_cnt == 2) begin unlocked = 1; unlock_cnt = 0; end
                    end else begin
                        unlock_cnt = 0;
                        if (CD[2:7] < 8) regs[CD[5:7]] = latch;
                        else if (unlocked && CD[2:7] == 6'd15) r15 = latch[5:0];
                    end
                end
                else begin
                    addr = {CD[2:7], latch};
                    if (!CD[1]) begin readahead = vram[addr]; addr = addr + 1; end
                end
            end
        end else begin
            stage = 0;
            vram[addr] = CD;
            readahead  = CD;
            addr = addr + 1;
        end
    end

    // ----------------------------------------------------------------- reads
    reg rd_mode;
    always @(negedge nCSR) begin
        t_csr_fall = $realtime;
        rd_mode    = MODE;
        if ($realtime - t_last_access < IRQ_NS) fail("access before RP2040 handler finished");
        sr5 = sr5 + 8'd37;                          // "DVI irqs" keep counting
        drive_val  = !MODE ? readahead :
                     (!unlocked || r15 == 0) ? {int_pending, status[6:0]} :
                     (r15 == 1) ? 8'hE8 : (r15 == 4) ? sr4 : (r15 == 5) ? sr5 : 8'h00;
        #(RD_DELAY);
        if (!nCSR) begin
            if (^CD === 1'bx) ;  // contention shows as X below
            drive_en = 1;
        end
    end

    // bus contention: FPGA driving while the VDP drives gives X
    always @(CD) if (drive_en && CD !== drive_val) fail("CD contention during read");

    always @(posedge nCSR) begin
        drive_en = 0;
        if ($realtime - t_csr_fall < MIN_STROBE) fail("/CSR strobe too short");
        if (MODE !== rd_mode) fail("MODE changed during read");
        t_last_access = $realtime;
        reads = reads + 1;
        stage = 0;
        if (rd_mode) begin
            if (!unlocked || r15 == 0) int_pending = 0;
        end else begin
            readahead = vram[addr];
            addr = addr + 1;
        end
    end

    // ---------------------------------------------------------------- frames
    integer frames = 0;
    reg frames_en = 1;     // testbench clears this to simulate a hung VDP
    always begin
        #(FRAME_NS);
        if (frames_en) begin
            frames = frames + 1;
            int_pending = 1;
        end
    end

    // ------------------------------------------------------------ inspection
    function [7:0] scr(input integer row, input integer col);
        scr = vram[{regs[2][3:0], 10'h000} + row * 32 + col];
    endfunction

    task dump_screen;
        integer r, c;
        reg [8*32-1:0] line;
        reg [7:0] ch;
        begin
            $display("+--------------------------------+");
            for (r = 0; r < 24; r = r + 1) begin
                for (c = 0; c < 32; c = c + 1) begin
                    ch = scr(r, c);
                    line[8*(31-c) +: 8] = (ch >= 8'h80) ? "#" : (ch < 8'h20) ? " " : ch;
                end
                $display("|%s|", line);
            end
            $display("+--------------------------------+");
        end
    endtask
endmodule
