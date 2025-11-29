#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;

# Karol Siedlaczek 2025

my $nagios_ok = 0;
my $nagios_warn = 1;
my $nagios_crit = 2;
my $nagios_unknown = 3;
my $arc_stats_file = "/proc/spl/kstat/zfs/arcstats";
my $message = "";
my $exit_code = $nagios_ok;
my %arc;

# Args
my $miss_ratio_warn;
my $miss_ratio_crit;
my $memory_throttle_warn = 0;
my $memory_throttle_crit = 0;
my $nagios_output = 0;
my $eol_char = "\n";

my $args_ok = GetOptions(
    "miss-ratio-warn|w=i"   => \$miss_ratio_warn,
    "miss-ratio-crit|c=i"   => \$miss_ratio_crit,
    "mem-throttle-warn|W=i" => \$memory_throttle_warn,  
    "mem-throttle-crit|C=i" => \$memory_throttle_crit,  
    "nagios|n"              => \$nagios_output,
);

unless ($args_ok) {
    print "Error in command line arguments\n";
    exit $nagios_crit;
}

unless (defined $miss_ratio_warn && defined $miss_ratio_crit) {
    print "ERROR: You must define both --miss-ratio-warn/-w and --miss-ratio-crit/-c\n";
    exit $nagios_crit;
}

$eol_char = "</br>" if ($nagios_output == 1);
my $status;
my @lines = `arc_summary -s arc`;

foreach my $line (@lines) {
    chomp($line);
    if ($line =~ /ARC status/) {
        my @fields = split(/\s+/, $line);
        $status = $fields[2];
        last;
    }
}

open(my $fh, '<', $arc_stats_file) or die "ERROR: Cannot open $arc_stats_file: $!";
while (<$fh>) {
    chomp;
    my @fields = split;
    my $attr = $fields[0];
    my $value = $fields[2];
    if ($attr =~ /^(memory_throttle_count|(demand|prefetch)_(data|metadata)_(hits|iohits|misses))$/) {
        $arc{$attr} = $value;
    }
}
close($fh);

my $total_hits = $arc{'demand_data_hits'} + $arc{'demand_metadata_hits'} + $arc{'prefetch_data_hits'} + $arc{'prefetch_metadata_hits'};
my $total_misses = $arc{'demand_data_misses'} + $arc{'demand_metadata_misses'} + $arc{'prefetch_data_misses'} + $arc{'prefetch_metadata_misses'};
my $total_accesses = $total_hits + $total_misses;
my $miss_ratio = $total_misses / $total_accesses;
my $total_accesses_mb = $total_accesses / 1000 / 1000;
my $total_misses_mb = $total_misses / 1000 / 1000;

if ($status ne "HEALTHY") {
    $message .= sprintf("CRITICAL: ARC status is '%s'", $status);
    $exit_code = $nagios_crit;
}
else {
    $message .= sprintf("OK: ARC status is '%s'", $status);
}
$message .= $eol_char;

if ($miss_ratio > $miss_ratio_crit / 100) {
    $message .= sprintf(
        "CRITICAL: Cache miss ratio is %.4f%% (%.3f MB / %.3f MB) (> %d%%)", 
        $miss_ratio * 100, 
        $total_misses_mb, 
        $total_accesses_mb, 
        $miss_ratio_crit
    );
    $exit_code = $nagios_crit;
}
elsif ($miss_ratio > $miss_ratio_warn / 100) {
    $message .= sprintf(
        "WARNING: Cache miss ratio is %.4f%% (%.3f MB / %.3f MB) (> %d%%)", 
        $miss_ratio * 100, 
        $total_misses_mb, 
        $total_accesses_mb, 
        $miss_ratio_warn
    );
    $exit_code = $nagios_warn if $exit_code < $nagios_crit;
}
else {
    $message .= sprintf(
        "OK: Cache miss ratio is %.4f%% (%.3f MB / %.3f MB)", 
        $miss_ratio * 100, 
        $total_misses_mb, 
        $total_accesses_mb
    );
}
$message .= $eol_char;

if ($arc{'memory_throttle_count'} > $memory_throttle_crit) {
    $message .= sprintf(
        "CRITICAL: Memory throttle is %d (> %d)", 
        $arc{'memory_throttle_count'}, 
        $memory_throttle_crit
    );
    $exit_code = $nagios_crit;
}
elsif ($arc{'memory_throttle_count'} > $memory_throttle_warn) {
    $message .= sprintf(
        "WARNING: Memory throttle is %d (> %d)", 
        $arc{'memory_throttle_count'}, 
        $memory_throttle_warn
    );
    $exit_code = $nagios_warn if $exit_code < $nagios_crit;
}
else {
    $message .= sprintf(
        "OK: Memory throttle count is %d", 
        $arc{'memory_throttle_count'}
    );
}

print "$message\n";
exit $exit_code;
