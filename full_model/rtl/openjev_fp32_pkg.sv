`timescale 1ns/1ps
package openjev_fp32_pkg;
  // Exact widening, including binary16 subnormals and signed zero.
  function automatic logic [31:0] fp_from_half(input logic [15:0] a);
    integer leading;
    logic [7:0] exponent_bits;
    logic [22:0] fraction_bits;
    begin
      leading=0;exponent_bits=0;fraction_bits=0;
      if(a[14:10]==31) fp_from_half={a[15],8'hff,a[9:0],13'b0};
      else if(a[14:10]!=0) begin
        exponent_bits={3'b0,a[14:10]}+8'd112;
        fp_from_half={a[15],exponent_bits,a[9:0],13'b0};
      end else if(a[9:0]==0) fp_from_half={a[15],31'b0};
      else begin
        for(integer i=0;i<10;i=i+1) if(a[i]) leading=i;
        exponent_bits=8'(leading+103);
        fraction_bits={13'b0,a[9:0]}<<(23-leading);
        fp_from_half={a[15],exponent_bits,fraction_bits};
      end
    end
  endfunction
  // Finite binary32 arithmetic, gradual underflow, round nearest/ties even.
  // No real/shortreal, simulator conversion, or vendor simulation primitives.
  function automatic logic finite(input logic [31:0] a);
    finite = a[30:23] != 255;
  endfunction

  function automatic logic [63:0] shift_jam(input logic [63:0] a, input integer n);
    logic lost;
    begin
      if (n <= 0) shift_jam = a;
      else if (n >= 64) shift_jam = {63'b0,|a};
      else begin
        lost = |(a & ((64'd1 << n)-1));
        shift_jam = (a >> n) | {63'b0,lost};
      end
    end
  endfunction

  function automatic logic [63:0] round_shift(input logic [63:0] a, input integer n);
    logic [63:0] q, remainder_bits, halfway;
    begin
      if (n <= 0) round_shift = a << (-n);
      else if (n > 64) round_shift = 0;
      else begin
        q = n == 64 ? 0 : a >> n;
        remainder_bits = n == 64 ? a : a & ((64'd1 << n)-1);
        halfway = 64'd1 << (n-1);
        round_shift = q + ((remainder_bits > halfway) ||
            (remainder_bits == halfway && q[0]));
      end
    end
  endfunction

  // Packs the exact value (-1)^sign * magnitude * 2^power.
  function automatic logic [31:0] pack_fp32(
      input logic sign_bit, input logic [63:0] magnitude, input integer power);
    integer top, exponent_value;
    logic [63:0] rounded;
    begin
      top = 0;
      for (integer i=0;i<64;i=i+1) if (magnitude[i]) top=i;
      exponent_value = top + power;
      rounded = 0;
      if (magnitude == 0) pack_fp32 = {sign_bit,31'b0};
      else if (exponent_value > 127) pack_fp32 = {sign_bit,8'hff,23'b0};
      else if (exponent_value < -126) begin
        rounded = round_shift(magnitude,-149-power);
        pack_fp32 = {sign_bit,7'b0,rounded[23:0]};
      end else begin
        rounded = round_shift(magnitude,top-23);
        if (rounded[24]) begin
          rounded = rounded >> 1;
          exponent_value = exponent_value + 1;
        end
        if (exponent_value > 127) pack_fp32 = {sign_bit,8'hff,23'b0};
        else pack_fp32 = {sign_bit,8'(exponent_value+127),rounded[22:0]};
      end
    end
  endfunction

  function automatic logic [31:0] fp_add(input logic [31:0] a,b);
    logic [31:0] big, smaller;
    logic [63:0] lhs, rhs, magnitude;
    integer eb, es;
    begin
      big = a[30:0] >= b[30:0] ? a : b;
      smaller = a[30:0] >= b[30:0] ? b : a;
      eb = big[30:23] == 0 ? 1 : int'(big[30:23]);
      es = smaller[30:23] == 0 ? 1 : int'(smaller[30:23]);
      lhs = {8'b0,(big[30:23]!=0),big[22:0],32'b0};
      rhs = shift_jam({8'b0,(smaller[30:23]!=0),smaller[22:0],32'b0},eb-es);
      magnitude = big[31] == smaller[31] ? lhs+rhs : lhs-rhs;
      fp_add = pack_fp32(magnitude == 0 ? (a[31]&b[31]) : big[31],magnitude,eb-182);
      if (!finite(a) || !finite(b)) fp_add = 32'h7fc00000;
    end
  endfunction

  function automatic logic [31:0] fp_mul(input logic [31:0] a,b);
    logic [23:0] ma, mb;
    logic [47:0] product;
    integer ea, eb;
    begin
      ma = {(a[30:23]!=0),a[22:0]};
      mb = {(b[30:23]!=0),b[22:0]};
      ea = a[30:23] == 0 ? 1 : int'(a[30:23]);
      eb = b[30:23] == 0 ? 1 : int'(b[30:23]);
      product = {24'b0,ma} * {24'b0,mb};
      fp_mul = pack_fp32(a[31]^b[31],{16'b0,product},ea+eb-300);
      if (!finite(a) || !finite(b)) fp_mul = 32'h7fc00000;
    end
  endfunction

  function automatic logic [31:0] fp_scale(input logic [31:0] a, input integer power);
    integer exponent_value;
    begin
      exponent_value = a[30:23] == 0 ? 1 : int'(a[30:23]);
      fp_scale = pack_fp32(a[31],{40'b0,(a[30:23]!=0),a[22:0]},exponent_value-150+power);
    end
  endfunction

  function automatic logic [31:0] fp_from_int(input logic signed [31:0] a);
    logic [31:0] magnitude;
    begin
      magnitude = a[31] ? (~a+1) : a;
      fp_from_int = pack_fp32(a[31],{32'b0,magnitude},0);
    end
  endfunction

  // Exact conversion for validated dimensions <= 4096, without general
  // 64-bit normalization and rounding logic on a control path.
  function automatic logic [31:0] fp_from_u13(input logic [12:0] a);
    logic [3:0] top;
    logic [31:0] shifted;
    logic [7:0] biased;
    begin
      top=0;
      for(integer i=0;i<13;i=i+1) if(a[i]) top=4'(i);
      shifted={19'b0,a} << (23-top);
      biased=8'd127+top;
      fp_from_u13=a==0 ? 32'b0 : {1'b0,biased,shifted[22:0]};
    end
  endfunction

  function automatic logic [31:0] fp_from_i10(input logic signed [9:0] a);
    logic [9:0] magnitude;
    logic [31:0] converted;
    begin
      magnitude=a[9] ? (~a+10'd1) : a;
      converted=fp_from_u13({3'b0,magnitude});
      fp_from_i10={a[9],converted[30:0]};
    end
  endfunction

  function automatic logic signed [31:0] fp_nearest_int(input logic [31:0] a);
    logic [63:0] magnitude;
    begin
      magnitude = round_shift({40'b0,(a[30:23]!=0),a[22:0]},150-int'(a[30:23]));
      fp_nearest_int = a[31] ? -32'(magnitude) : 32'(magnitude);
    end
  endfunction

  function automatic logic fp_less(input logic [31:0] a,b);
    begin
      if (a[30:0]==0 && b[30:0]==0) fp_less=0;
      else if (a[31]!=b[31]) fp_less=a[31];
      else fp_less=a[31] ? a[30:0]>b[30:0] : a[30:0]<b[30:0];
    end
  endfunction
endpackage
