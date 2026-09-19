#!/usr/bin/env perl
# Perl port of scripts/gen_gls_vectors.py (2026-09-19): the port-level
# mirror of docs/uarch.md 8.2 / 8.2.1 that turns a stimulus file into the
# per-cycle expected port values for PIPE_ROM=0 (latency 1) and PIPE_ROM=1
# (latency 2). It reimplements lut_index and rshr bit-exactly and reads the
# tracked model/exp_lut.hex (the normative table) instead of recomputing
# exponentials, so every arithmetic step is integer and reproducible.
#
# The Python version stays the reference. Python's Mersenne-Twister
# stimulus stream cannot be reproduced from Perl, so this script CONSUMES a
# stimulus file (`--stim`, default build/gls_stim.hex as written by the
# Python generator) and emits the two expected files; `make perl-crosscheck`
# compares them byte for byte against the Python output for the same
# stimulus. That is the evidence that the two mirrors agree.
#
# Usage: perl scripts/gen_gls_vectors.pl [--stim build/gls_stim.hex]
#            [--out-dir build] [--lut model/exp_lut.hex]
use strict;
use warnings;
use Getopt::Long;

my $stim    = 'build/gls_stim.hex';
my $out_dir = 'build';
my $lut_hex = 'model/exp_lut.hex';
GetOptions('stim=s' => \$stim, 'out-dir=s' => \$out_dir, 'lut=s' => \$lut_hex)
    or die "usage: $0 [--stim FILE] [--out-dir DIR] [--lut FILE]\n";

# ---- normative constants (model/attn.py) -------------------------------
use constant M_INIT         => -32768;
use constant W_FRAC         => 15;
use constant LUT_SIZE       => 1024;
use constant LUT_STEP_SHIFT => 4;
use constant LUT_DOMAIN_RAW => -16384;

# ---- LUT from the tracked normative hex --------------------------------
my @LUT;
{
    open(my $fh, '<', $lut_hex) or die "cannot open $lut_hex: $!";
    while (my $l = <$fh>) {
        $l =~ s/^\s+|\s+$//g;
        push @LUT, hex($l) if $l ne '';
    }
    close $fh;
    die "LUT has " . scalar(@LUT) . " entries, expected 1024\n" if @LUT != LUT_SIZE;
    die "lut[0] must be 0x8000\n" if $LUT[0] != 32768;
}

# ---- bit-exact helpers (Python floor semantics on non-negative operands) --
sub lut_index {
    my ($d_raw) = @_;
    die "lut_index: d_raw must be <= 0, got $d_raw\n" if $d_raw > 0;
    $d_raw = LUT_DOMAIN_RAW if $d_raw < LUT_DOMAIN_RAW;
    my $idx = int((-$d_raw + 8) / (1 << LUT_STEP_SHIFT));   # operand >= 0: int() == floor
    return $idx < LUT_SIZE ? $idx : LUT_SIZE - 1;
}

sub rshr {
    # round-half-up arithmetic right shift; only ever called with x >= 0 here
    # (l * r), so integer division equals the floor shift. Guarded so a
    # negative operand can never silently truncate toward zero.
    my ($x, $k) = @_;
    die "rshr: negative operand $x not supported in this mirror\n" if $x < 0;
    return int(($x + (1 << ($k - 1))) / (1 << $k));
}

sub to_signed16 { my ($x) = @_; return $x >= 32768 ? $x - 65536 : $x; }
sub to_u16      { my ($x) = @_; return $x & 0xFFFF; }

sub step {
    my ($m, $l, $s, $row_start) = @_;
    my $m_base = $row_start ? M_INIT : $m;
    my $l_base = $row_start ? 0 : $l;
    my $m_new  = ($m_base >= $s) ? $m_base : $s;
    my $r      = $LUT[lut_index($m_base - $m_new)];
    my $w      = $LUT[lut_index($s - $m_new)];
    my $l_new  = rshr($l_base * $r, W_FRAC) + $w;
    die "DEN bound violated: $l_new\n" if $l_new < 0 || $l_new >= (1 << 24);
    return ($m_new, $l_new, $w, $r);
}

# ---- stimulus ----------------------------------------------------------
my @cyc;
{
    open(my $fh, '<', $stim) or die "cannot open $stim: $!";
    while (my $l = <$fh>) {
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '';
        my $v = hex($l);
        push @cyc, [ ($v >> 18) & 1, ($v >> 17) & 1, ($v >> 16) & 1, $v & 0xFFFF ];
    }
    close $fh;
}

sub expected_lat1 {
    my ($m, $l, $w, $r, $ov) = (M_INIT, 0, 0, 0, 0);
    my @out;
    for my $c (@cyc) {
        my ($rst, $iv, $rs, $s) = @$c;
        push @out, [$m, $l, $r, $w, $ov];
        if ($rst) {
            ($m, $l, $w, $r, $ov) = (M_INIT, 0, 0, 0, 0);
        } else {
            $ov = $iv;
            ($m, $l, $w, $r) = step($m, $l, to_signed16($s), $rs) if $iv;
        }
    }
    return \@out;
}

sub expected_lat2 {
    my ($m, $l, $w, $r, $ov) = (M_INIT, 0, 0, 0, 0);
    my ($w_p, $r_p, $v_p, $rs_p) = (0, 0, 0, 0);
    my @out;
    for my $c (@cyc) {
        my ($rst, $iv, $rs, $s) = @$c;
        push @out, [$m, $l, $r, $w, $ov];
        if ($rst) {
            ($m, $l, $w, $r, $ov) = (M_INIT, 0, 0, 0, 0);
            ($w_p, $r_p, $v_p, $rs_p) = (0, 0, 0, 0);
            next;
        }
        my $sv = to_signed16($s);
        my $m_base = $rs ? M_INIT : $m;
        my $m_n    = ($m_base >= $sv) ? $m_base : $sv;
        my $r_e    = $LUT[lut_index($m_base - $m_n)];
        my $w_e    = $LUT[lut_index($sv - $m_n)];
        if ($v_p) {
            my $l_base = $rs_p ? 0 : $l;
            $l = rshr($l_base * $r_p, W_FRAC) + $w_p;
            ($w, $r) = ($w_p, $r_p);
        }
        $ov  = $v_p;
        $v_p = $iv;
        ($w_p, $r_p, $rs_p, $m) = ($w_e, $r_e, $rs, $m_n) if $iv;
    }
    return \@out;
}

# ---- emit (identical formatting to the Python generator) ---------------
# 73-bit word: {m[15:0], l[23:0], r[15:0], w[15:0], out_valid}; Perl's native
# integers are 64-bit, so the word is assembled as two hex halves.
sub emit {
    my ($path, $rows) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    binmode $fh;
    for my $row (@$rows) {
        my ($m, $l, $r, $w, $ov) = @$row;
        # low 33 bits: r(16) | w(16) | ov(1)  ; high 40 bits: m(16) | l(24)
        my $lo = ($r << 17) | ($w << 1) | $ov;            # < 2^33
        my $hi = (to_u16($m) << 24) | $l;                  # < 2^40
        # 19 hex digits total = 76 bits; hi occupies digits above bit 33.
        # value = hi << 33 | lo. Split at a nibble boundary: bits [75:36] and [35:0].
        my $top = ($hi >> 3);                              # bits 75..36 (40 bits)
        my $bot = (($hi & 7) << 33) | $lo;                 # bits 35..0  (36 bits)
        printf $fh "%010x%09x\n", $top, $bot;
    }
    close $fh;
}

emit("$out_dir/gls_expected_lat1.hex", expected_lat1());
emit("$out_dir/gls_expected_lat2.hex", expected_lat2());
printf "cycles=%d\n", scalar @cyc;
