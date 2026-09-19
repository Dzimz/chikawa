/*
 * Kurimanju + VGA Glyph Mode merge
 * Base glyph/rain design: James Ross (Apache-2.0)
 * Sprite overlay: 16 flat-color RGB222 frames, transparent background, ~30 fps
 */

`default_nettype none

module tt_um_vga_glyph_mode(
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // VGA signals
    wire hsync, vsync, display_on;
    wire [10:0] hpos;
    wire [9:0]  vpos;
    wire [5:0]  RGB;

    // TinyVGA PMOD
    assign uo_out = {hsync, RGB[0], RGB[2], RGB[4], vsync, RGB[1], RGB[3], RGB[5]};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // ---------------- Glyph Mode background ----------------
    wire [7:0] xb = hpos[10:3];
    wire [6:0] x_mix = {xb[7] ^ xb[3], xb[1], xb[4], xb[1], xb[6], xb[0], xb[2]};
    wire [2:0] g_x = hpos[2:0];
    wire [5:0] yb;
    wire [3:0] _unused_div;
    assign {_unused_div, yb} = vpos / 10'd12;
    wire [5:0] g_unused;
    wire [3:0] g_y;
    assign {g_unused, g_y} = vpos - {yb, 3'b000} - {1'b0, yb, 2'b00};
    wire hl;

    wire _unused_ok = &{ena, ui_in[5:2], uio_in};

    reg [9:0] frame;
    reg rst_drop;

    hvsync_generator hvsync_gen(
        .clk(clk),
        .reset(~rst_n),
        .mode(ui_in[7:6]),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(display_on),
        .hpos(hpos),
        .vpos(vpos)
    );

    glyphs_rom glyphs(
        .c(glyph_index),
        .y(g_y),
        .x(g_x),
        .pixel(hl)
    );

    wire [5:0] color;
    palette_rom palettes(
        .cid(y),
        .pid(ui_in[1:0]),
        .color(color)
    );

    // Keep your 39-glyph selection.
    wire [5:0] glyph_index = (yb + xb) % 6'd39;

    wire [1:0] a = xb[1:0];
    wire [3:0] b = xb[5:2];
    wire [2:0] d = xb[3:2] + 2'd3;

    wire t = &{xb[0] ^ yb[2] ^ frame[7], xb[1] ^ yb[1] ^ frame[8],
                xb[2] ^ yb[3] ^ frame[9], xb[3] ^ yb[0]};
    wire s = ^xb[6:0];
    wire n = xb[1] ^ xb[3] ^ xb[5];
    wire [6:0] v = (s ? frame[8:2] : frame[9:3]) - yb - x_mix;
    wire [3:0] c = {1'b0, a} + d;
    wire [6:0] e = {3'b000, b} << c;
    wire [6:0] f = v & e;
    wire [6:0] x = v >> a;
    wire [2:0] y = ~x[2:0];
    wire [9:0] drop = {1'b0, yb, 3'd0} >> s;
    wire drop_bit = ({3'd0, x_mix} + drop > frame) & ~rst_drop;
    wire [5:0] glyph_color = {6{drop_bit}} ^ color;
    wire [5:0] z = (&(~v[2:0]) & &(y)) ? 6'd63 : glyph_color;
    wire [5:0] glyph_rgb = (display_on & hl & ~(|f | n | drop_bit)) ? z : 6'd0;

    always @(posedge vsync or negedge rst_n) begin
        if (!rst_n) begin
            rst_drop <= 1'b0;
            frame <= 10'd0;
        end else begin
            if (&frame)
                rst_drop <= 1'b1;
            frame <= frame + 10'd1;
        end
    end

    // ---------------- Kurimanju sprite overlay ----------------
    // 48x48 sprite scaled 8x -> 384x384.
    // It is centered for every VGA mode supported by this Glyph Mode design.
    wire [10:0] sprite_x0 = (ui_in[7:6] == 2'd0) ? 11'd128 :
                            (ui_in[7:6] == 2'd1) ? 11'd192 :
                            (ui_in[7:6] == 2'd2) ? 11'd208 : 11'd320;
    wire [9:0] sprite_y0 = (ui_in[7:6] == 2'd0) ? 10'd48 :
                           (ui_in[7:6] == 2'd1) ? 10'd96 :
                           (ui_in[7:6] == 2'd2) ? 10'd108 : 10'd192;

    wire inside_sprite = display_on &&
                         (hpos >= sprite_x0) && (hpos < sprite_x0 + 11'd384) &&
                         (vpos >= sprite_y0) && (vpos < sprite_y0 + 10'd384);

    wire [10:0] local_x = hpos - sprite_x0;
    wire [9:0]  local_y = vpos - sprite_y0;
    wire [5:0] sprite_x = local_x[8:3];
    wire [5:0] sprite_y = local_y[8:3];

    // The supported VGA modes are all nominally 60 Hz when driven at their
    // matching pixel clock. Advancing every second display frame gives 30 fps.
    wire video_frame_tick = (hpos == 11'd0) && (vpos == 10'd0);
    reg anim_half;
    reg [3:0] anim_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            anim_half  <= 1'b0;
            anim_frame <= 4'd0;
        end else if (video_frame_tick) begin
            if (anim_half) begin
                anim_half <= 1'b0;
                anim_frame <= (anim_frame == 4'd15) ? 4'd0 : anim_frame + 4'd1;
            end else begin
                anim_half <= 1'b1;
            end
        end
    end

    wire [5:0] sprite_rgb;
    kurimanju_solid_rom sprite_rom(
        .frame(anim_frame),
        .x(sprite_x),
        .y(sprite_y),
        .rgb(sprite_rgb)
    );

    // Magenta RGB222 (3,0,3) is reserved as transparency in the sprite ROM.
    localparam [5:0] SPRITE_TRANSPARENT = 6'b110011;
    wire sprite_opaque = inside_sprite && (sprite_rgb != SPRITE_TRANSPARENT);

    // Sprite wins over the glyph rain. Transparent sprite pixels reveal glyphs.
    assign RGB = !display_on ? 6'd0 :
                 sprite_opaque ? sprite_rgb : glyph_rgb;

endmodule

module kurimanju_solid_rom(
    input  wire [3:0] frame,
    input  wire [5:0] x,
    input  wire [5:0] y,
    output reg  [5:0] rgb
);
    reg [287:0] row;

    always @* begin
        row = {48{6'b110011}};
        case (frame)
      4'd0: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea00000000002acf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cea025940000000000025000033cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3025025965965965965965940940033cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965965940cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc096596596596596596596596596596594000002acf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf300000002596596596596596596596596596594097ecc0ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea03efbe940965965965965965965965965965000ffeff3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cf3033fbef8002596596596596596596596594003efbee80cf3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3cf3fbefbef8002596596596596596594003efbefbef80033cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefbefb3940000000000000000000cfefbefbefb3033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0fbefbefbefbefbeeb3fbe96597ecf3fbefbefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefa5033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc097efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbee80033fbefbefbefb303efbefbefbefbefbe02acf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbef80000fbefbefbecc0000cfefbefbefbefbefaacf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbaebaebecc097efbefbefbef80000ebaebaebefbefbef80cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbecfaeb3cf3fb3cfefbefbefbefbecfaebaeb3cf3fbefbef80cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbece5ea5965ebefbefbeeb3fbefbefbece5ea5965ebefbe940cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbefb3ebaeb3ebefbefb3000fbefbefbefb3cfaeb3ebefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbefbeebafbefbefbefbecf3ebefbefbefbeebaebefbefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc003ffbefbefbefbefbefbefbefbefbefbefbefbefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefba02acf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbecfee80cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303ecf3fbefbefbefbefbefbefbefbefbefbefbef80ab3fc0ab3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cea97f033fbefbefbefbefbefbefbefbefbefbefbef80000cc0ab3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcf3fbefbefbefbefbefbefbefbefbefbefbef80aaa02acf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3033025fbefbefbefbefbefbefbefbefbefbefbef80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbefbefbefbe000ebe000cf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80033cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd1: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea000000000ab3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000965000000000025000ab3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000025965965965965965940940033cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0965965965965965965965965965965965a8002acf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000965965965965965965965965965965940033cc0ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0fbafb3025965965965965965965965965965000ffeffeab3cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cea03efbef8096596596596596596596596594003efbecc0cf3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3fb3fbefbe000965965965965965965965000ebefbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0ebefbefbecc000002596596596594000097efbefbefb3ab3cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3a80fbefbefbefbece5000000000000000cfafbefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbeeb3cf3cfefbefbefbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefb3cfefbefbefbefb3cfefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0033fbefbefbef80000fbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0fbefbefbeebaebf000000fbefbefbecc0000cfefbafbefbefbe96acf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0fbefbefbaebaebecc0033fbefbefbefbe03efbaebaebafbefbe000cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbecf3cf3cf3fbefbefbefbefbefbefbecf3cfaebafbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbece5cf3ea5ebefbefb3cfecfafbefbeea5cf3ce5cfefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbefb3ebaebafbefbefb3fbefbefbefbefbaebaebafbefbe033cf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefc0033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0fbffbefbefbefbefbefbefbefbefbefbefbefbefbeff3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbacfaf80cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303ecf3fbefbefbefbefbefbefbefbefbefb3ab3033f80cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cea97f033fbefbefbefbefbefbefbefbefbee80cf303ecc0cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcf3fbefbefbefbefbefbefbefbefbecc0cc0033000cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf303303efbefbefbefbefbefbefbefbefbef80033000000cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbe033ab3cc0ab3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefb3033000000ab3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefb3033000000cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000ce5000cf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003fffa02acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd2: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea000aaacf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000025940000025940000ab3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000940965965965965965000000cf3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3a80965965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0000965965965965965965965965965965000033cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3a80000965965965965965965965965965965940000940ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea033e80025965965965965965965965965965940cfeff3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cea03efba025965965965965965965965965965000fbecc0cf3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3033fbecc096596596596596596596596594003efbee80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefb3000965965965965965965965000fbefbefb3ab3cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0ebefbefbee80000025965965965000000fbefbefbefbe02acf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbefbefbeeb394000000000003ecfefbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbaebafbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefb3cfefbefbefbefb3fb3fbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0025fbefbefbef80000fbefbefbefbefbe96acf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbeebaebff80000fbefbefbecc0000cfeebafbefbefbe940cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbefbaebaebaf80033fbefbefbefb303efbaebaebafbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbecf3cfaea5fbefbefbefbefbefbefbfcf3cfaea5fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbeea5cf3cfaebefbefb3ce5cfafbefbeea5cf3cfacfefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefbaebaebafbefbefb3fb3cfefbefbefbaebaebafbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefbe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3ab3fbefbefbefbefbefbefbeebafbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefbefb3cf3cf3fbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0cfffbefbefbefbefbefbefbe973cf3cc0cfefbefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbe033cc0000cfefbefbeceaab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefbefbe000000fc003ffbefb3aaacf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbe000a80cc0033fbef80ab3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303e033fbefbefbefbefbefbecea033000cf3fbef80ab3cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3ceacff033fbefbefbefbefbefbeceaa80000ebecf3f80ab3cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcfefbefbefbefbefbefbee8000000003ecf3f80ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3000025fbefbefbefbefbefbefbecfafbefbefbef80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3ceacfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefb3fb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd3: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea02aaaacf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000025940000025940000cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000940965965965965965000000cf3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3a80965965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0000965965965965965965965965965965033cf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3a80000965965965965965965965965965965965000000cf3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea033cc0965965965965965965965965965965940fbefb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cffff3025965965965965965965965965965940fbef80ab3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303afbe000965965965965965965965965965033fbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbef80025965965965965965965965940fbefbefb3033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0ebefbefbe940025965965965965965940033fbefbefbe02acf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbefbefb3000000000000000000000ebefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303afbefbefbefbefbecf3000000025cf3fbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefb3fb3fbefbefbefb3033fbefbefbefbefbefaacf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbef80000fbefbefbee80000cfefbefbefbefbef80cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbefbaebaebfcc0000fbefbefbee80000cfeebafbefbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbeebaebaeb3fb3fbafbefbefbefb3fb3ebaebaeb3fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbece5ce5965ebefbefbefbafbefbefbece5ce5965ebefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbeebacf3cf3ebefbefb3f80fbafbefbeebacfacf3ebefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbeebaebefbefbefbacf3cfefbefbefbeebaebefbefbe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbeeb3cf3cfafbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0cfffbefbefbefbefbefba033cf3cc0fbefbefbefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefb3cf3cc0a80cfefbefbefbeceaab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefb3033033cc0cfefbefbefb3aaacf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefb3033cf3a80cfefbefbef80ab3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303f033fbefbefbefbefb3a80cc0000973fbefbef80ab3cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3ceacff033fbefbefbefbefb3033000fbffbeebefbef80ab3cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcfefbefbefbefbefbe000000025cfecfefbef80ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3000025fbefbefbefbefbefb3cf3cf3cf3fbefbef80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbeffffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003fff302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd4: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3aaa000aaacf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000000940000025940000ab3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000940965965965965965000940ab3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3a80965965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0000965965965965965965965965965965033cf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3a80000965965965965965965965965965965965000000ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea033cc0965965965965965965965965965965940cfefb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cfffb3025965965965965965965965965965940fbefb3033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303afbef80965965965965965965965965965033fbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefbe025965965965965965965965000cfefbefb3ab3cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0ebefbefbecc0000965965965965965000033fbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbefbefbef80000000000000000033fbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefb3cfefbecf3cfefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0033fbefbefbefb3025fbefbefbefbefbefaacf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbf940000fbefbefbecc0000cfefbefbefbefbef80cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbefbaebaebfcc003efbefbefbef80000ebaebaebefbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbeebaeb3cf3fb3cfefbefbefbefbecfeebaeb3cf3fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbece5ea5965ebefbefbaeb3fbefbefbece5ea5965ebefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefb3cfaeb3ebefbefb300097efbefbefb3cfaeb3ebefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbeebaebefbefbefbecf3ebefbefbefbeebaebefbefbe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefb3cf3cfafbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0cfffbefbefbefbefbefba033cf3cc0fbefbefbefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefb3ceacf3cc0ebefbefbefbeceaab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3a80fbefbefbefbefbefb3033000cc0ebefbefbefb3aaacf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefb302aceafc0fbefbefbef80ab3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303f033fbefbefbefbefba000033000fb3fbefbef80ab3cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3ceacff033fbefbefbefbefbe033000033ffeeb3fbef80ab3cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcfefbefbefbefbefbe940000000fbefb3fbef80ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3000025fbefbefbefbefbefb3cf3cfecfafbefbef80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbeffffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003fff302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd5: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3aaa000aaacf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000000940000025940000ab3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000940965965965965965000000ab3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3a80965965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0000965965965965965965965965965965033cf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3cc0000965965965965965965965965965965965000000cf3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea033cc0965965965965965965965965965965940cfefb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cfffb3025965965965965965965965965965940fbef80ab3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3033fbef80965965965965965965965965965033fbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefa5025965965965965965965965000cfefbefb3ab3cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0ebefbefbecc0000965965965965965000033fbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbefbefbef80000000000000000033fbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefb3cfefbecf3cfefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbee80033fbefbefbefb303efbefbefbefbefbefaacf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbf940000fbefbefbecc0000cfefbefbefbefbef80cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbefbaebaebfcc003efbefbefbef80000ebaebaebefbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbeebaeb3cf3fb3cfefbefbefbefbecfeebaeb3cf3fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbece5ea5965ebefbefbaeb3fbefbefbece5ea5965ebefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbeeb3ebaeb3ebefbefb394097efbefbefb3cfaeb3ebefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbeebaebefbefbefbecf3ebefbefbefbeebaebefbefbe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefbecf3cfeebefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0cfffbefbefbefbefbefbecc0cf3ab3fbefbefbefbeff3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefb3cf3cf303efbefbefbeceaab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3a80fbefbefbefbefbefbecc0cc0cf303efbefbefb3aaacf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbeceaaaafea03ecfefbef80ab3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303f033fbefbefbefbefbecc0a80a80fb3cfefbef80ab3cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3ceacff033fbefbefbefbefbef80cc000097efb3cfef80ab3cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcfefbefbefbefbefbefbe00003e025cf3ebef80ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3000025fbefbefbefbefbefbecf3ebefbefbefbef80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbeffffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003fff302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd6: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea000000000033cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cea025940000000000025940033cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea025025965965965965965940940033cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965965940cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0965965965965965965965965965965940000033cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000965965965965965965965965965965940000940ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0973fb3025965965965965965965965965965940fbeff3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0fbefbe000965965965965965965965965965033fbef80ab3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303afbef80025965965965965965965965940cfefbef80033cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefbe000025965965965965965000033fbefbefb3033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3a80fbefbefbefb300000000000000000003efbefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbecf3fbefbefbecfafbefbefbefbefbee80cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefa5033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe02acf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0fbafbefbefbefbe033fbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbf000000fbefbefbecc0025fbefbefbefbefbef80cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbaebaebffa597efbefbefbecc0000fbaebaebefbefbe940cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbeebaeb3cf3fb3cfefbefbefbecf3cfeebaeb3cf3fbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbece5ea5965fbefbefbefb3cc003efbece5ce5965fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbeeb3ebacf3ebefbefbe000cffff3cfeeb3ebacf3ebefbe033cf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc097efbefbeebaebefbefbefb3033ceaa8003efbeebaebefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbef80cc0cf303afbefbefbefbefc0033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbecc0cc0ff3033fbefbefbefbee80cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefbefbefbee80033000000fbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc003ffbefbefbefbefbefbefb3000000940973fbefbeff3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3025fbefbefbefbefbefbefba000033ffece5fbefbeceacf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefbefbeeb3f80973fbefbef80ab3cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fb3fbefbefbefbefbefbefbefbecfefb3fbef80033cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033cc0fbefbefbefbefbefbefbefbefbecf3fbefb3033cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3033f80cfefbefbefbefbefbefbefbefbefbefbefa5033cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf3a80ff397efbefbefbefbefbefbefbefbefbefbefc0033cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cc0000cfefbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbeffffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa80033000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd7: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3a80000000000000cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cc0025940000965940000940033cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3aaacc0965025965965965965965965000033000cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cc0000000025965965965965965965965940000025033cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cc0fbefbaf80000965965965965965000033fbefbf02acf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefb3f80000000000000000973fbefbefb3033cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbacf3cf3cf3fbefbefbefbefb3033cf3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cf3cf3fbefbefbefbefbefbefbefbefbefbefbefbefbef80cf3cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cf3cfefbefbefbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefb3cfefb3cf3cfefb3fbefbefbefbefbe940cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3033fbefbefbefbef80033fb3cf3cfecc0000fbefbefbefbef80cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbeebafbf000025fbecf3ff3000000fbeebafbefbefbe033cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cc0fbefbeebaebaebecc0033cfefb3000cf3033ffaebaebafbefb3033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc0cfefbecf3ce597afbefbecfacc0abffffcc0cf3ce5965fbefba033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbece5cf3cf3ebefbefb302acffab3cf3000cf3cf3ebefbe02acf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0ebefbefbaebaebefbefbefbef80ab3000cea000ebaebefbefbe02acf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbefbefbefb3000cc0000a80ebefbefbefbef80cf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbefbefbefbecc0cc0000a80ffefbefbefbe940cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbefbefbefbefb300000000097efbefbefbe000cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbecc0000cfe000ebefbefbe02acf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbaf8097efbe03efbefbe033cf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefb3033fbe033fbefb3033cf3cf3;
          6'd27: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbecc0cfecc0fbefc0033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefb303ef80cfecc0cf3cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefbefbefbefbefbefbefbefbe033ffecff000cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbecf3fbafbe033cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbefbefbefaacf3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3ab3fbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033eb3fbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033f80fbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3ab3ff3fbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf3cc0cfe03efbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cea000fbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3a80fbefbefbefbefbefbefbefbefbefbefbee80cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a80000000000aaaa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80033cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd8: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3a80000000000000ab3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cc0025940000965940000940033cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cc0965025965965965965965965000033aaacf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3000000025965965965965965965965940000000033cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cc0cfefbaf80000965965965965965000033fbefbf000cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cc0cfefbefbacc0000000000000000fb3fbefbefb302acf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3cc097efbefbefbefbacf3cf3cf3fbefbefbefbefb3033cf3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cf3cf3fbefbefbefbefbefbefbefbefbefbefbefbefbef80cf3cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cf3cfefbefbefbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefb3cfefb3cf3cfefb3fbafbefbefbefbe940cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3033fbefbefbefbe000033fb3cf3cfecc0000fbefbefbefbef80cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbeebaebf000025fbecf3ffe000000fbeebafbefbefbe033cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cc0fbefbeebaebaebae8003acfeff3f8002aab3ffaebaebafbefb3033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc0cfefbecf3ce5965fbefbecfacc002afffcc0cf3ce5965fbefba033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbece5cf3cf3ebefbefb3000cfffeacea025cf3cf3ebefbe02acf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0ebefbefbaebaebefbefbefbef80ab3000cea000ebaebefbefbe02acf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbefbefbefb3ab3cf3a80a80ebefbefbefbef80cf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbefbefbefbef80cc0000cc0ffefbefbefbe940cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbefbefbefbefbe000000000fbefbefbefbe000cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbef80000cfa000fbefbefbe02acf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefb3cc0fbff8003efbefbe033cf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefb3033fbe033fbefb3033cf3cf3;
          6'd27: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbecc0ebecc0fbefc0033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefb303ef80cfecc0cf3cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefbefbefbefbefbefbefbefbe033fc0cff000cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbecf3fb3fbe033cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbeebafbefaacf3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3ab3fbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033eb3fbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033f80fbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3ab3ff3fbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf3cc0cfe03efbefbefbefbefbefbefbefbefbefbefb3033cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cea000fbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3a80fbefbefbefbefbefbefbefbefbefbefbeeaacf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a80000000000aaaa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd9: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3ceaaaaaaacf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000025965000025940000cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000940965965965965965000000cf3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3cc0965965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0000965965965965965965965965965940033cf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000965965965965965965965965965965965000000cf3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0973cc0025965965965965965965965965965940fbafb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cfffba025965965965965965965965965965940fbef80ab3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303efbecc0965965965965965965965965965033fbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3ceacfefbefb3000965965965965965965965000cfefbefbe033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0ebefbefbee80000025965965965940000033fbefbefbe02acf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbefbefbecfe000000000000000fb3fbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303afbefbefbefbefbefbeeb3cf3cf3fbefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbecfefbefbefbefbecfafbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbef80000fbeeb3ebefb3000cfefbefbefbefbe96acf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0000eb3cf3cf3f80000fbfebefbefbefbef80cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbefbaebaebaf80000fbacf3cfafb3000cfaebaebafbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbeeb3eb3ce5ebeebefbefb3fbefbefbeeb3cf3ce5ebefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbeea5eb3965cfefbefb3f80033fbefbefa5973965cfefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefbaebaebaebefbefbe00003efbefbefbacfaebaebefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbafbefbefbefbe000033cfefbefbefbafbefbeffe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbecc0033cf3fbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbecc0fffcf303afbefbefbefbfcc0cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3ceacfefbefbefbefbefbefbefb3a80cf3033fbefbefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbecc0cc0fea03efbefbefbecc0ab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3000fbefbefbefbefbefbef80cf3cc0000fbecfefb3000cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefb3000000cf3cf3cfef80033cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033cc0fbefbefbefbefbefbe03e000cfefbefbefb3033cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3033f80cfefbefbefbefbefbece5cf3025fbecfefbe033cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf3a80ffa03efbefbefbefbefbefbefbefbaeb3ebefc0033cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cc003e03efbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3000cfefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd10: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3aaacf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3a8000002596500000002acf3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000940025965965965940025000cf3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3cc094096596596596596596596596502acf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cea000965965965965965965965965965000033cf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3cc0000025965965965965965965965965965965000000cf3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea033cc0965965965965965965965965965965940033eb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cfffb3025965965965965965965965965965940fbefb3033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303afbecc0965965965965965965965965965033fbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cf3cfefbefb3000965965965965965965965940cfefbefbe033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0cfefbefbecc0000965965965965965000033fbefbefbe02acf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3025fbefbefbefbecc0000000000000000033fbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbacf3cf3cf3cfefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbeebefbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefbe03efbefbafbefb3000cfefbefbefbefbe96acf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0000cf3cf3cf3fc000003ffbefbefbefbef80cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbefbaebaebef80000fbacf3cf3fb3000cffebaebefbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbeeb3eb3cf3ebecfefbefb3fbefbeebafb3eb3cf3ebefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbeea5eba965cfefbefb3cfefb3fbefbefa597a965cfefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefb3cfaebacfefbefbe000033fbefbefbacfaebaebefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cc003efbefbefbaebefbefbefbe94003efbefbefbefbaebefbefb3033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf303afbefbefbefbefbefbefbecc097efbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbecc0cfefbefbefbefbefbefbecc0cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0cfefbefbefbefbefbefbefb3cfefbefbefb3ebefbefba02acf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cea033fbefbefbefbefbefbefb3ebefbecf3a8003efbee80033cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefb3ab3fffcf3ffecc0cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3ab3fbefbefbefbefbefbefbefbef80fffff3cc0cf3fb3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033cfefbefbefbefbefbefbefbefbecf3033000cf3fb3cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3033cc0fbefbefbefbefbefbefbefb303fabfce5ffeceacf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf3033fe5cfefbefbefbefbefbefbefbe033000000000033cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3a80cc0fbefbefbefbefbefbefbefbef8002a000cc0cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cea000fbefbefbefbefbefbefbefbee80fbecfecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbacfefbf000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefb3fb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd11: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea00000000002acf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cea025940000000000025940033cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea025025965965965965965940940033cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965965940cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc096596596596596596596596596596594002acf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000965965965965965965965965965965940000000ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0cfaf80025965965965965965965965965965940ebefba033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cfefb3025965965965965965965965965965033fbefa5033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303efbecc0965965965965965965965965940fbefbef80033cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefb300096596596596596596594003efbefbefb3033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3a80fbefbefbee80000000965965940000000cfefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbeeb3f80000000000fb3cfefbefbefbefbee80cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc097efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe02acf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0ebefbefbefbefbefb3cfefbefbefbefb3fbefbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbe000033fb3cf3ebecc0000fbefbefbefbefbef80cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbeebafbe000033fb3cf3cfecc0000fbaebafbefbefbe940cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbeebaebaebecc0fbefbacf3fbefbe973ebaebaebefbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbecf3ea5973fbefbefbecf3fbefbefbecf3cfa973fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbece5cf3cf3fbefbef80000fbefbefbece5cf3cf3fbefbe033cf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc097efbefbaebaebefbefbefbe000cfefbefbefbaebaebefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefb3025ebefbefbefbefbefbefbefc0033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefb3000fbefbefbefbefbefbefbee80cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc003efbefbefbefbefbefbecf3fbefbefbacf3cfefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf303efbefbefbefbefbefbefbefbefbecc0cf3033fbecc0cf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3ce5fbefbefbefbefbefbefbefbef80cfffffcfefbeceacf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fb3fbefbefbefbefbefbefbef80ff3ceacc0033fb3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033cc0fbefbefbefbefbefbefbefb3033033cfefbefaacf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3033f80cfefbefbefbefbefbefbefb303fabfcc0cf3033cf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf3025ff3fbefbefbefbefbefbefbefbe000000000000ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cc0000cfefbefbefbefbefbefbefbecc0a8003ef80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefb3ebfcc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefb3fb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbeffffbefbefbe000cfe000cf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80033cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd12: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea000000000033cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cea000965000000000025940033cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3025025965965965965965940940033cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965965940cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc096596596596596596596596596596596502acf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000965965965965965965965965965965940000000ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0fb3e80025965965965965965965965965965940cfefb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0cfefb302596596596596596596596596596503efbefa5033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf303efbecc096596596596596596596596594003efbef80033cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefb3000965965965965965965940000fbefbefb3033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0fbefbefbee80000000965965965000000cfefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbeeb3f80000000000973cfefbefbefbefbee80cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbeebafbefbefbefbefbefbefbef80033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc097efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe02acf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefb3cfefbefbefbefb3fbefbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbe000033fbacf3ebecc0000fbefbefbefbefbef80cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbeebafbf00003efb3cf3cfecc0000fbeebafbefbefbe940cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbeebaebaebecc003afbacf3fbefbe033fbaebaebafbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbecf3ce5973fbefbefbecf3ebefbefbfcf3ce5965fbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbece5cf3cf3fbefbefa5000fbefbefbece5cf3cf3fbefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc097efbefbaebaebefbefbefb3940cfefbefbefbaebaebefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefb3000cfefbefbefbefbefbefbefc0033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefb3000cfefbefbefbefbefbefbef80cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3a80fbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc003efbefbefbefbefbefbecf3fbefbefbecf3cfefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbecc0cf3033fbecc0cf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3a80fbefbefbefbefbefbefbefbef80cfffffcfefbeceacf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fb3fbefbefbefbefbefbefbef80ff3cf3cc0033fb3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033cc0fbefbefbefbefbefbefbefb3033033abefbefaacf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3033f80cfefbefbefbefbefbefbefb303fcffcc0cf302acf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf303eff3fbefbefbefbefbefbefbefbe000000000000ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cc0000cfefbefbefbefbefbefbefbecc0a8003ee80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefb3ebfcc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefb3fb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbeffffbefbefbe000cfe000cf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003fff302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80033cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd13: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3a8000002aab3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000965000000000965000ab3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000025965965965965965940940ab3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0025965965965965965965965965965965033cf3cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000965965965965965965965965965965940000000ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0973fb3025965965965965965965965965965940ebefb3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3ceafbefbe000965965965965965965965965965033fbefb3033cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3033fbef80025965965965965965965965940fbefbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefbef80025965965965965965940033fbefbefb3ab3cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0fbefbefbefb3f8000000000000000003eebefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf303efbefbefbefbefbeeb3fbefbefb3cfafbefbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefb3033fbefbefbefb3000fbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbefbefbecc0000fbefbefbef80000cfefbefbefbefbefaacf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbefbaebaebfcc0000fbefbefbef80000cffebaebefbefbe940cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbeebaeb3cf3fb3cfefbefbefbefbecfaebaeb3cf3fbefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbeea5ce5940cfefbefbafb3cfafbefbeea5ce5965cfefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbefb3cfacf3cfefbefb3000033fbefbefb3cfacf3cfefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefbeebaebefbefbefbecfafbefbefbefbeebaebefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbecfefbefbefbefbefbefbefbeffe033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0fbffbefbefbefbefbefbefbefbefbefbecf3cfefbefb3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbeceaab3033fbeceaab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3a80fbefbefbefbefbefbefbefbef80ceafffcfeffecc0cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbef80fffcf3cc0fbefb3cf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf3033ce5fbefbefbefbefbefbefbefb303303303eebafb3cf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cf3033f80fbefbefbefbefbefbefbefb3abfcffcc0cf3aaacf3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cf303eff3fbefbefbefbefbefbefbefbe000000000000ab3cf3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3cc0cc0cfefbefbefbefbefbefbefbecc0a8003ee80cf3cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cf3000fbefbefbefbefbefbefbefbefa5973cfecc0cf3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefb3fb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbefbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80033cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      4'd14: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cc000000000002acf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cc0025940000000000025940033cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cc0965025965965965965965940940033cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965965940cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc096596596596596596596596596596594000002acf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000025965965965965965965965965965965940cf3cc0ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cc0fbafb3025965965965965965965965965965033fbef80cf3cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cc0fbefbecc0965965965965965965965965940cfefbef80cf3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3fbafbefb3000965965965965965965940033fbefbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0fbefbefbefbe00000000000000000003efbefbefbefb3ab3cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3000fbefbefbefbefb3cfe94000097ecf3fbefbefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80ab3cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0ebefbefbefbefbeebefbefbefbefbefbe033fbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0fbefbefbefbefbe00003effefbefbecc0000fbefbefbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3a80fbefbefbaebaebf000033fbefbefbecc0000fbaebaebefbefbe02acf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0fbefbeebaebacfafb3cfefbefbefbefb3cfeebaeb3cf3fbefbe02acf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0fbefbecfaea5965fbefbefbeeb3fbefbefbece5ea5965ebefbe02acf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0ebefbeebaeb3cf3fbefbefbe940fbefbefbeeb3ebacf3ebefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbefbaebaebefbefbefb3cf3ebefbefbefbeebaebefbefb3033cf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cc003efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefc0033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0cfffbefbefbefbefbefbefbefbefbefbefbefbefbefc0033cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefaacf3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0ebefbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbef80faacf3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303ecf3fbefbefbefbefbefbefbefbefbefbefbef80cfecf3cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3cea03f033fbefbefbefbefbefbefbefbefbefbefbef80cf3ab3cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcf3fbefbefbefbefbefbefbefbefbefbefbef80cf3ab3cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf3033025fbefbefbefbefbefbefbefbefbefbefbef80cc0cf3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3a80000fbefbefbefbefbefbefbefbefbefbefbecc002acf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000ebe000cf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cf3000cf3000a8000000000002aa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
      default: begin
        case (y)
          6'd0: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd1: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd2: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd3: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd4: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd5: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cea000000000ab3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd6: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3000965000000000965000ab3cf3cf3cf3cf3cf3cf3cf3;
          6'd7: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3000025965965965965965940940ab3cf3cf3cf3cf3cf3cf3;
          6'd8: row = 288'hcf3cf3cf3cf3cf3cf3cf3000025965965965965965965965940000cf3cf3cf3cf3cf3cf3;
          6'd9: row = 288'hcf3cf3cf3cf3cf3cf3cc0025965965965965965965965965965940a80033cf3cf3cf3cf3;
          6'd10: row = 288'hcf3cf3cf3cf3cf3000000025965965965965965965965965965000cfecc0ab3cf3cf3cf3;
          6'd11: row = 288'hcf3cf3cf3cf3cea97aebe940965965965965965965965965965033fbeff3033cf3cf3cf3;
          6'd12: row = 288'hcf3cf3cf3cf3cea03efbefa5025965965965965965965965000cfefbecc0cf3cf3cf3cf3;
          6'd13: row = 288'hcf3cf3cf3cf3cf3033fbefbecc000096596596596594000003afbefbef80ab3cf3cf3cf3;
          6'd14: row = 288'hcf3cf3cf3cf3cc0cfefbefbefbecc0000000000000000fb3fbefbefbefb3033cf3cf3cf3;
          6'd15: row = 288'hcf3cf3cf3cf3cc0fbefbefbefbefbefbecf3cf3cfafbefbefbefbefbefbe000cf3cf3cf3;
          6'd16: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3;
          6'd17: row = 288'hcf3cf3cf3cf303efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80033cf3cf3;
          6'd18: row = 288'hcf3cf3cf3cc097efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefb3033cf3cf3;
          6'd19: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefb3cfefbefbefbefb3cfefbefbefbefbefba033cf3cf3;
          6'd20: row = 288'hcf3cf3cf3cc0cfefbefbefbefbecc0033fbefbefbecc0000fbefbefbefbefbe033cf3cf3;
          6'd21: row = 288'hcf3cf3cf3cc0ebefbefbefbafbe000000ffefbefbecc0000fbeebafbefbefbe02acf3cf3;
          6'd22: row = 288'hcf3cf3cf3cc0ebefbefbaebaebecc0033fbefbefbefa5033ffaebaebefbefbef80cf3cf3;
          6'd23: row = 288'hcf3cf3cf3cc0ebefbecf3cf3eb3fbefbefbefbefbefbefbfcf3cf3eb3fbefbe940cf3cf3;
          6'd24: row = 288'hcf3cf3cf3cc0ebefbece5cfa965fbefbefb3cfecfefbefbece5cfaea5ebefbe000cf3cf3;
          6'd25: row = 288'hcf3cf3cf3cc0cfefbefbaebaebafbefbefb3fbecfefbefbefb3ebaebafbefbe02acf3cf3;
          6'd26: row = 288'hcf3cf3cf3cc0cfefbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefbe02acf3cf3;
          6'd27: row = 288'hcf3cf3cf3cc0fbefbefbefbefbefbefbefbecf3fbefbefbefbefbefbefbefb3033cf3cf3;
          6'd28: row = 288'hcf3cf3cf3cea03efbefbefbefbefbefbefbefbefbefbefbefbefbefbefbefe5033cf3cf3;
          6'd29: row = 288'hcf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbef80cf3cf3cf3;
          6'd30: row = 288'hcf3cf3cf3cf3000fbefbefbefbefbefbefbefbefbefbefbefbefbefbefbf000cf3cf3cf3;
          6'd31: row = 288'hcf3cf3cf3cf3cc0fbffbefbefbefbefbefbefbefbefbefbefbefbefbeff3ab3cf3cf3cf3;
          6'd32: row = 288'hcf3cf3cf3cf3cf3033fbefbefbefbefbefbefbefbefbefbefbefbefbeceaab3cf3cf3cf3;
          6'd33: row = 288'hcf3cf3cf3cf3cf3cc0fbefbefbefbefbefbefbefbefbefbefbefbefbecc0cf3cf3cf3cf3;
          6'd34: row = 288'hcf3cf3cf3cf3cf3033fbafbefbefbefbefbefbefbefbefbefbefbefbeff3ab3cf3cf3cf3;
          6'd35: row = 288'hcf3cf3cf3cf3cf303ffb3fbefbefbefbefbefbefbefbefbefbefbefbecfa033cf3cf3cf3;
          6'd36: row = 288'hcf3cf3cf3cf3ceafbf033fbefbefbefbefbefbefbefbefbefbefbef80cfe033cf3cf3cf3;
          6'd37: row = 288'hcf3cf3cf3cf3cea03fcfefbefbefbefbefbefbefbefbefbefbefbef80fb3033cf3cf3cf3;
          6'd38: row = 288'hcf3cf3cf3cf3cf300003efbefbefbefbefbefbefbefbefbefbefbef80000ab3cf3cf3cf3;
          6'd39: row = 288'hcf3cf3cf3cf3cf3cc0000fbefbefbefbefbefbefbefbefbefbefbecc0ab3cf3cf3cf3cf3;
          6'd40: row = 288'hcf3cf3cf3cf3cf3cf3ceacfefbefbefbefbefbefbefbefbefbefbe000cf3cf3cf3cf3cf3;
          6'd41: row = 288'hcf3cf3cf3cf3cf3cf3cc003eebefbefbefbefbefbefbefbefbafb3033cf3cf3cf3cf3cf3;
          6'd42: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfecc0cfefbefbefbffbefbefbe000cfe02acf3cf3cf3cf3cf3;
          6'd43: row = 288'hcf3cf3cf3cf3cf3cf3cc0cfffbe00000000000000000000003ffb302acf3cf3cf3cf3cf3;
          6'd44: row = 288'hcf3cf3cf3cf3cf3cf3cea000cf3000a80000000000aaaa8003e000033cf3cf3cf3cf3cf3;
          6'd45: row = 288'hcf3cf3cf3cf3cf3cf3cf3cea000ab3cf3cf3cf3cf3cf3cf3a80ab3cf3cf3cf3cf3cf3cf3;
          6'd46: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          6'd47: row = 288'hcf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3cf3;
          default: row = 288'b0;
        endcase
      end
        endcase

        if (x < 6'd48)
            rgb = row >> (x * 6);
        else
            rgb = 6'b110011;
    end
endmodule

`default_nettype wire
