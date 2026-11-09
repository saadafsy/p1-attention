#!/usr/bin/env perl
# Perl port of scripts/toggle_count.py (identical output; `make perl-crosscheck` diffs them).
# Counts 0<->1 transitions per net in GLS VCDs (x/z ignored, one per changed vector bit).
# A relative toggle proxy for two netlists on the same stimulus, not a power measurement.
# Usage: perl scripts/toggle_count.pl build/gls_lat1.vcd [build/gls_lat2.vcd ...]
use strict;
use warnings;

sub parse_vcd {
    my ($path) = @_;
    # A net's first value (from $dumpvars) only seeds last{code}, so it is never counted.
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
