#!/usr/bin/perl

use JSON;
use LWP::UserAgent;
use HTTP::Request;
use MIME::Base64;

# just to give nagios time to build objects.cache
sleep 1;

my $cache = '/var/lib/nagios4/objects.cache';
open(my $fh, $cache) or die "cannot open cache file '$cache': $!\n";

my $config = {};

my $section = '';
my $host = '';
my $notes = '';
my $vars = {};

foreach my $line (<$fh>) {
        if ($line =~ /^\s*define\s+service\s+{/) {
                $section = 'service';
                next;
        }
        elsif($line =~ /^\s*}/) {
                if ($host and $vars && $notes !~ /^["e|e]{0,2}xt-obj[a-zA-Z]+/) {
                        print "$host pushed\n";
                        push @{$config->{$host}}, $vars;
                }
                elsif ($host) {
                        print "$host ($notes) skipped\n";
                }

                $section = '';
                $host = '';
                $notes = '';
                $vars = {};
        }
        next if not $section;

        if ($line =~ /^\s*([^\s]+)\s+(.+)$/) {
                if ($1 ~~ ["service_description", "check_interval", "max_check_attempts"]) {
                        $vars->{$1} = $2;
                }
                elsif ($1 eq 'host_name') {
                        $host = $2
                }
                elsif ($1 eq 'notes') {
                        $notes = $2
                }
        }
}

close($fh);

my $json = encode_json($config);
#print $json;

sub send_req_to_nagios {
        my $uri = shift;
        my $json = shift;
        my $req = HTTP::Request->new('POST', $uri);
        $req->header('Content-Type' => 'application/json');
        $req->header('Authorization' => 'Basic ' . encode_base64('nagios3:dupa.8'));
        $req->content($json);

        my $lwp = LWP::UserAgent->new();
        $lwp->timeout(5);
        $lwp->request($req);
}

send_req_to_nagios('other_nagios', $json);
