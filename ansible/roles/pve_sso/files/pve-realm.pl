#!/usr/bin/perl
# pve-realm.pl: one Proxmox VE realm as code (role pve_sso).
#
# Usage: pve-realm.pl [--check] < realm.json
#
# realm.json: {"realm": "<name>", "type": "openid", "<option>": <value>, ...}, the options
# of `pveum realm add`. Read on stdin, so a client key never appears on a command line.
# The realm is created when missing and updated when an option differs. Options not in the
# JSON are left as they are. Proxmox's own API code does the work, so its checks and the
# cluster-wide lock apply. --check validates and says what would change, and changes nothing.
# Prints one line: "created", "updated: <options>", "unchanged", or with --check
# "would create" / "would update: <options>". The client key's value is never printed.
use strict;
use warnings;

use JSON;
use PVE::API2::Domains;
use PVE::Auth::Plugin;
use PVE::Cluster qw(cfs_read_file);
use PVE::RPCEnvironment;

my $check = @ARGV && $ARGV[0] eq '--check';
die "usage: pve-realm.pl [--check] < realm.json\n" if @ARGV > ($check ? 1 : 0);

my $want = decode_json(do { local $/; <STDIN> });
my $realm = $want->{realm} // die "pve-realm: no realm in the JSON\n";
my $type = $want->{type} // die "pve-realm: no type in the JSON\n";
# Proxmox takes booleans as 1 or 0.
for my $k (keys %$want) {
    $want->{$k} = $want->{$k} ? 1 : 0 if JSON::is_bool($want->{$k});
}

my $rpcenv = PVE::RPCEnvironment->init('cli');
$rpcenv->init_request();
$rpcenv->set_language('C');
$rpcenv->set_user('root@pam');

my $have = cfs_read_file('domains.cfg')->{ids}->{$realm};
my $plugin = PVE::Auth::Plugin->lookup($type);

if (!$have) {
    my %param = %$want;
    delete $param{realm};
    $plugin->check_config($realm, \%param, 1, 1);
    if ($check) {
        print "would create\n";
    } else {
        PVE::API2::Domains->create({ %$want });
        print "created\n";
    }
    exit 0;
}

die "pve-realm: realm $realm is of type $have->{type}, not $type\n" if $have->{type} ne $type;
my @diff = sort grep {
    $_ ne 'realm' && $_ ne 'type' && (!defined($have->{$_}) || "$have->{$_}" ne "$want->{$_}")
} keys %$want;
if (!@diff) {
    print "unchanged\n";
    exit 0;
}
my $fixed = $plugin->options();
for my $k (@diff) {
    die "pve-realm: $k of realm $realm cannot change once set: remove the realm to change it\n"
        if $fixed->{$k} && $fixed->{$k}->{fixed};
}
my %update = (realm => $realm, map { $_ => $want->{$_} } @diff);
my %param = %update;
delete $param{realm};
$plugin->check_config($realm, \%param, 0, 1);
if ($check) {
    print "would update: @diff\n";
} else {
    PVE::API2::Domains->update(\%update);
    print "updated: @diff\n";
}
