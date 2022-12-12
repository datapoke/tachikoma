#!/usr/bin/perl
# ----------------------------------------------------------------------
# topic.cgi
# ----------------------------------------------------------------------
#

use strict;
use warnings;
use Tachikoma::Nodes::ConsumerBroker;
use Tachikoma::Message qw( ID TIMESTAMP );
use CGI;
use JSON -support_by_pp;

my $home   = ( getpwuid $< )[7];
my $config = Tachikoma->configuration;
$config->load_config_file(
    "$home/.tachikoma/etc/tachikoma.conf",
    '/usr/local/etc/tachikoma.conf',
);

my $broker_ids = undef;
if ($Tachikoma::Nodes::CGI::Config) {
    $broker_ids = $Tachikoma::Nodes::CGI::Config->{broker_ids};
}
$broker_ids ||= [ 'localhost:5501', 'localhost:5502' ];
my $cgi  = CGI->new;
my $path = $cgi->path_info;
$path =~ s(^/)();
my ( $topic, $partition, $location, $count ) = split q(/), $path, 4;
my $offset = undef;
if ($location) {
    $location = 'recent' if ( $location eq 'last' );
    $offset   = $location;
}
die "no topic\n" if ( not $topic );
$partition ||= 0;
$offset    ||= 'start';
$count     ||= 1;
my $json = JSON->new;

# $json->escape_slash(1);
$json->canonical(1);
$json->pretty(1);
$json->allow_blessed(1);
$json->convert_blessed(0);
CORE::state %groups;
$groups{$topic} //= Tachikoma::Nodes::ConsumerBroker->new($topic);
$groups{$topic}->broker_ids($broker_ids);
my $group    = $groups{$topic};
my $consumer = $group->consumers->{$partition}
    || $group->make_sync_consumer($partition);
my @messages = ();
my $results  = undef;

if ($consumer) {
    if ( $offset =~ m(^\d+$) ) {
        $consumer->next_offset($offset);
    }
    else {
        $consumer->default_offset($offset);
    }
    if ( $location eq 'recent' ) {
        do { push @messages, @{ $consumer->fetch } }
            while ( not $consumer->eos );
    }
    else {
        do { push @messages, @{ $consumer->fetch } }
            while ( @messages < $count and not $consumer->eos );
    }
}

@messages = sort {
    join( q(:), $a->[TIMESTAMP], $a->[ID] ) cmp
        join( q(:), $b->[TIMESTAMP], $b->[ID] )
} @messages;
if ( $location eq 'recent' ) {
    shift @messages while ( @messages > $count );
}

if ( not $consumer or $consumer->sync_error ) {
    print STDERR $consumer->sync_error if ($consumer);
    my $next_url = $cgi->url( -path_info => 1, -query => 1 );
    $next_url =~ s{^http://}{https://};
    $results = {
        next_url => $next_url,
        error    => 'SERVER_ERROR'
    };
}
else {
    my @output      = ();
    my $i           = 1;
    my $next_offset = $offset =~ m{\D} ? $consumer->offset : $offset;
    for my $message (@messages) {
        $next_offset = ( split q(:), $message->id, 2 )[1];
        push @output, $message->payload;
        last if ( $i++ >= $count );
    }
    my $next_url = join q(/), $cgi->url, $topic, $partition, $next_offset,
        $count;
    $next_url =~ s{^http://}{https://};
    $results = {
        next_url => $next_url,
        payload  => \@output
    };
}

print( $cgi->header( -type => 'application/json', -charset => 'utf-8' ),
    $json->utf8->encode($results) );
