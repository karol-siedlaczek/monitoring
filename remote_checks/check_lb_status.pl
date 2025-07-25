#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;

my ($snmp_host, $snmp_port, $snmp_user, $snmp_pass, $ext_name, $expected_status) = @ARGV;
my %nagios = (OK => 0, WARN => 1, CRITICAL => 2, UNKNOWN => 3);

my %expected;
foreach my $exp (split /,/, $expected_status) {
        my($backend, $status) = split /:/, $exp;
        $expected{$backend} = $status;
}

my $lb_status = qx!
        /usr/bin/snmpget -t 10 -OQv -l authPriv -a SHA -x AES -u $snmp_user -A $snmp_pass -X $snmp_pass $snmp_host:$snmp_port 'NET-SNMP-EXTEND-MIB::nsExtendOutputFull."$ext_name"' 2>&1
!;

my(%ok, %error);
my $i = 0;
foreach my $stline (split /;/, $lb_status) {
        chomp $stline;
        if($i == 0) {
                if($stline ne "# pxname,svname,status") {
                        print "CRITICAL: haproxy service is not available</br>Reason: Unexpected header line \'$stline\'\n";
                        exit $nagios{'CRITICAL'};
                }
                $i++;
        }

        next if not $stline;

        my($pxname, $svname, $status) = split /,/, $stline;
        next if not exists $expected{$pxname};
        next if $svname eq 'BACKEND';
        next if $svname eq 'FRONTEND';

        if($expected{$pxname} and $status eq $expected{$pxname}) {
                push @{$ok{$status}}, $pxname . '/' . $svname;
        } else {
                push @{$error{$status}}, $pxname . '/' . $svname;
        }
}

my($msg, $exit_code);
if(%error) {
        $exit_code = $nagios{'CRITICAL'};
        while(my($key, $val) = each %error) {
                $msg .= "$key: " . (join ', ', @$val) . '<br>';
        }
} else {
        $exit_code = $nagios{'OK'};
        while(my($key, $val) = each %ok) {
                $msg .= "$key: " . (join ', ', @$val) . '<br>';
        }
}

print substr($msg, 0, -4);
exit $exit_code;
