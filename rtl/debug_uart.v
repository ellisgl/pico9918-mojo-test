// Debug report over the Mojo V3's USB serial port (AVR bridge, 500 kbaud 8N1).
//
// Every PERIOD clocks it sends one line:
//   S=0D I=1 ST=9F FR=0123 IP=12 PL=00 RS=00 ER=00 T=P
//   ... B=23 D=5A ID=E8
//   S  main FSM state            I  /INT pin level (1 = idle)
//   ST last status read          FR frame counter
//   IP frames started by the /INT pin
//   PL frames found by polling the status register (F bit set)
//   RS watchdog re-inits         ER readback errors   T readback P/F/-
//   B  F18A SR4: firmware boot stage (PICO9918_BOOT_TRACE builds; bit 7 = hard fault)
//   D  F18A SR5: DVI DMA irq count, low byte (changes if video is running)
//   ID F18A SR1: E8 when the F18A unlock worked
//
// The AVR raises avr_cclk once it is ready to forward data; until then
// avr_rx stays tristated, as in the Mojo base project.
module debug_uart #(
    parameter CLK_PER_BIT = 100,          // 50 MHz / 500 kbaud
    parameter PERIOD      = 12_500_000    // 250 ms
) (
    input  wire        clk,
    input  wire        avr_cclk,
    input  wire        avr_rx_busy,
    output wire        avr_rx,

    input  wire [7:0]  st,
    input  wire        int_pin,
    input  wire [7:0]  status,
    input  wire [15:0] frame,
    input  wire [7:0]  ipin,
    input  wire [7:0]  poll,
    input  wire [7:0]  resyncs,
    input  wire [7:0]  errors,
    input  wire        test_done,
    input  wire        test_pass,
    input  wire [7:0]  sr1,
    input  wire [7:0]  sr4,
    input  wire [7:0]  sr5
);
    function [7:0] hx(input [3:0] n);
        hx = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction

    // --- AVR ready: cclk high for 1024 consecutive clocks
    reg [1:0]  cclk_s = 2'b00;
    reg [10:0] cclk_cnt = 11'd0;
    wire ready = cclk_cnt[10];
    always @(posedge clk) begin
        cclk_s <= {cclk_s[0], avr_cclk};
        if (!cclk_s[1])      cclk_cnt <= 11'd0;
        else if (!ready)     cclk_cnt <= cclk_cnt + 1'b1;
    end

    reg [1:0] busy_s = 2'b11;
    always @(posedge clk) busy_s <= {busy_s[0], avr_rx_busy};

    // --- line snapshot
    localparam L = 68;
    reg [8*L-1:0] line = {8*L{1'b0}};
    wire [8*L-1:0] line_now = {
        "S=", hx(st[7:4]), hx(st[3:0]),
        " I=", int_pin ? "1" : "0",
        " ST=", hx(status[7:4]), hx(status[3:0]),
        " FR=", hx(frame[15:12]), hx(frame[11:8]), hx(frame[7:4]), hx(frame[3:0]),
        " IP=", hx(ipin[7:4]), hx(ipin[3:0]),
        " PL=", hx(poll[7:4]), hx(poll[3:0]),
        " RS=", hx(resyncs[7:4]), hx(resyncs[3:0]),
        " ER=", hx(errors[7:4]), hx(errors[3:0]),
        " T=", test_done ? (test_pass ? "P" : "F") : "-",
        " B=", hx(sr4[7:4]), hx(sr4[3:0]),
        " D=", hx(sr5[7:4]), hx(sr5[3:0]),
        " ID=", hx(sr1[7:4]), hx(sr1[3:0]),
        8'h0D, 8'h0A };

    reg [23:0] period_cnt = 24'd0;
    reg [6:0]  idx = 7'd0;
    reg        sending = 1'b0;

    // --- transmitter: 1 start, 8 data, 1 stop, 1 extra idle bit
    reg       tx_active = 1'b0;
    reg [6:0] bit_cnt = 7'd0;
    reg [3:0] bitn = 4'd0;
    reg [9:0] shift = 10'h3ff;

    always @(posedge clk) begin
        if (period_cnt == PERIOD - 1) begin
            period_cnt <= 24'd0;
            if (!sending && ready) begin
                line    <= line_now;
                idx     <= 7'd0;
                sending <= 1'b1;
            end
        end else
            period_cnt <= period_cnt + 1'b1;

        if (!tx_active) begin
            if (sending && !busy_s[1]) begin
                shift     <= {1'b1, line[8*(L-1-idx) +: 8], 1'b0};
                tx_active <= 1'b1;
                bit_cnt   <= CLK_PER_BIT - 1;
                bitn      <= 4'd0;
                if (idx == L - 1) sending <= 1'b0;
                else              idx <= idx + 1'b1;
            end
        end else if (bit_cnt != 0) begin
            bit_cnt <= bit_cnt - 1'b1;
        end else begin
            bit_cnt <= CLK_PER_BIT - 1;
            shift   <= {1'b1, shift[9:1]};
            if (bitn == 4'd10) tx_active <= 1'b0;
            bitn <= bitn + 1'b1;
        end
    end

    assign avr_rx = ready ? shift[0] : 1'bz;
endmodule
