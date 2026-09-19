#!/usr/bin/env perl
# Phase 5 switching-activity proxy: count logic transitions in the GLS VCDs.
# Perl port of scripts/toggle_count.py (2026-09-19), kept behaviourally
# identical: same parsing rules, same output format, so the two can be
# diffed byte for byte (`make perl-crosscheck`). The Python version stays
# the reference; this one exists so the Makefile can call either.
#
# Usage: perl scripts/toggle_count.pl build/gls_lat1.vcd [build/gls_lat2.vcd ...]
#
# For each VCD (produced by make -C tb/gls all, which replays the IDENTICAL
# stimulus into both PIPE_ROM netlist configs), counts 0<->1 transitions on
# every dumped net in the DUT scope. x/z edges are ignored (they occur only
# before reset resolves). Vector signals count one toggle per changed bit.
#
# This is a TOGGLE-COUNT PROXY, not a power measurement: it weights every
# net equally (no capacitance, no slew, no clock tree since the sandbox
# clock is ideal). It is honest for RELATIVE comparison of two netlists
# driven by the same stimulus through the same cell library.
use strict;
use warnings;

sub parse_vcd {
    my ($path) = @_;
    # No special handling is needed for the $dumpvars initial-value section:
    # a net's FIRST value line only seeds last{code} (old is undef, nothing
    # counted), so the baseline is established for free and only genuine
    # 0<->1 changes afterwards count as toggles.
    my (%ids, %last, %toggles);
    open(my $fh, '<', $path) or die "cannot open $path: $!";
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        if ($line =~ /^\$var/) {
            # $var wire 16 !"# w [15:0] $end
            my @parts = split /\s+/, $line;
            my ($width, $code) = ($parts[2], $parts[3]);
            $ids{$code} = $width;
            $toggles{$code} //= 0;
        } elsif ($line =~ /^\$/) {
            next;
        } elsif (substr($line, 0, 1) eq '#') {
            next;
        } elsif (substr($line, 0, 1) =~ /[01xz]/) {
            my $code = substr($line, 1);
            my $new  = substr($line, 0, 1);
            my $old  = $last{$code};
            if (defined $old && $old ne $new && $old =~ /^[01]$/ && $new =~ /^[01]$/) {
                $toggles{$code}++;
            }
            $last{$code} = $new;
        } elsif (substr($line, 0, 1) =~ /[bB]/) {
            my ($val, $code) = split /\s+/, substr($line, 1), 2;
            my $old = $last{$code};
            if (defined $old) {
                my $w = length($old) > length($val) ? length($old) : length($val);
                my $o = ('0' x ($w - length($old))) . $old;   # zfill
                my $n = ('0' x ($w - length($val))) . $val;
                for my $i (0 .. $w - 1) {
                    my ($a, $c) = (substr($o, $i, 1), substr($n, $i, 1));
                    if ($a ne $c && $a =~ /^[01]$/ && $c =~ /^[01]$/) {
                        $toggles{$code}++;
                    }
                }
            }
            $last{$code} = $val;
        }
    }
    close $fh;
    return (\%ids, \%toggles);
}

sub main {
    printf "%-28s %6s %10s %9s\n", 'vcd', 'nets', 'toggles', 'togg/net';
    my @results;
    for my $path (@ARGV) {
        my ($ids, $toggles) = parse_vcd($path);
        my $total = 0;
        $total += $_ for values %$toggles;
        my $nets = scalar keys %$ids;
        push @results, [$path, $nets, $total];
        printf "%-28s %6d %10d %9.1f\n", $path, $nets, $total, $total / $nets;
    }
    if (@results == 2) {
        my ($a, $b) = ($results[0][2], $results[1][2]);
        printf "ratio %s/%s: %.3f\n", $ARGV[1], $ARGV[0], $b / $a;
    }
}

main();
